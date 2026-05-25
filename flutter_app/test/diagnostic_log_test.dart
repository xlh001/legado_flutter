import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/diagnostics/diagnostic_debug_print.dart';
import 'package:legado_flutter/core/diagnostics/diagnostic_log.dart';
import 'package:legado_flutter/core/diagnostics/diagnostic_log_event.dart';
import 'package:legado_flutter/core/diagnostics/diagnostic_log_level.dart';
import 'package:legado_flutter/core/diagnostics/diagnostic_log_reader.dart';
import 'package:legado_flutter/core/diagnostics/diagnostic_log_writer.dart';
import 'package:legado_flutter/core/diagnostics/diagnostic_redactor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('diagnostic_log_test_');
  });

  tearDown(() async {
    await DiagnosticLog.resetForTest();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('redacts sensitive keys, URL query values, paths, and long strings', () {
    final redacted = DiagnosticRedactor.sanitizeMetadata({
      'password': 'secret',
      'Authorization': 'Bearer abc',
      'url': 'https://example.com/path?a=1&token=abc',
      'filePath': '/private/user/documents/book.txt',
      'nested': [
        {'access_token': 'abc'},
      ],
      'long': 'x' * 700,
    }) as Map<String, Object?>;

    expect(redacted['password'], kDiagnosticRedactedValue);
    expect(redacted['Authorization'], kDiagnosticRedactedValue);
    expect(redacted['url'], contains('a=%5BREDACTED%5D'));
    expect(redacted['filePath'], 'book.txt');
    expect((redacted['nested'] as List).first['access_token'],
        kDiagnosticRedactedValue);
    expect((redacted['long'] as String).length, lessThanOrEqualTo(512));
    expect(redacted['long'], endsWith('...[truncated]'));
  });

  test('event stack policy stores stacks only for warn and error', () {
    final stack = StackTrace.fromString('frame\n${'x' * 9000}');
    final info = DiagnosticLogEvent.create(
      level: DiagnosticLogLevel.info,
      source: 'flutter',
      category: 'test',
      message: 'info',
      stack: stack,
    );
    final error = DiagnosticLogEvent.create(
      level: DiagnosticLogLevel.error,
      source: 'flutter',
      category: 'test',
      message: 'error',
      error: 'token=abc',
      stack: stack,
    );

    expect(info.toJson().containsKey('stack'), isFalse);
    expect(error.stack, isNotNull);
    expect(error.stack!.length, lessThanOrEqualTo(8 * 1024));
    expect(error.error, contains(kDiagnosticRedactedValue));
  });

  test('writes JSONL events and reads tail', () async {
    final logDir = Directory('${tempDir.path}/logs');
    final writer = DiagnosticLogWriter(
      directory: logDir,
      config: const DiagnosticLogConfig(),
    );
    await writer.init();
    writer.enqueue(DiagnosticLogEvent.create(
      level: DiagnosticLogLevel.info,
      source: 'flutter',
      category: 'test.write',
      message: 'hello',
      metadata: {'count': 1},
    ));
    await writer.flush();

    final lines = await File('${logDir.path}/app.log.jsonl').readAsLines();
    expect(lines, hasLength(1));
    final decoded = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(decoded['category'], 'test.write');
    expect(decoded['metadata']['count'], 1);

    final tail = await DiagnosticLogReader(logDir).tail(maxLines: 1);
    expect(tail.single, lines.single);
  });

  test('rotates files when active file exceeds threshold', () async {
    final logDir = Directory('${tempDir.path}/logs');
    final writer = DiagnosticLogWriter(
      directory: logDir,
      config: const DiagnosticLogConfig(maxFiles: 3, maxBytesPerFile: 120),
    );
    await writer.init();
    for (var i = 0; i < 8; i++) {
      writer.enqueue(DiagnosticLogEvent.create(
        level: DiagnosticLogLevel.info,
        source: 'flutter',
        category: 'test.rotate',
        message: 'message $i ${'x' * 80}',
      ));
    }
    await writer.flush();

    expect(File('${logDir.path}/app.log.jsonl').existsSync(), isTrue);
    expect(File('${logDir.path}/app.1.log.jsonl').existsSync(), isTrue);
    expect(File('${logDir.path}/app.3.log.jsonl').existsSync(), isFalse);
  });

  test('retention cleanup deletes old files', () async {
    final logDir = Directory('${tempDir.path}/logs')
      ..createSync(recursive: true);
    final oldFile = File('${logDir.path}/app.1.log.jsonl')
      ..writeAsStringSync('{}\n');
    final stale = DateTime.now().subtract(const Duration(days: 30));
    oldFile.setLastModifiedSync(stale);

    final writer = DiagnosticLogWriter(
      directory: logDir,
      config: const DiagnosticLogConfig(maxAgeDays: 14),
    );
    await writer.init();

    expect(oldFile.existsSync(), isFalse);
  });

  test('disabled logging and level threshold skip events', () async {
    final logDir = Directory('${tempDir.path}/logs');
    final disabled = DiagnosticLogWriter(
      directory: logDir,
      config: const DiagnosticLogConfig(enabled: false),
    );
    await disabled.init();
    disabled.enqueue(DiagnosticLogEvent.create(
      level: DiagnosticLogLevel.error,
      source: 'flutter',
      category: 'disabled',
      message: 'nope',
    ));
    await disabled.flush();
    expect(File('${logDir.path}/app.log.jsonl').existsSync(), isFalse);

    final threshold = DiagnosticLogWriter(
      directory: logDir,
      config: const DiagnosticLogConfig(minLevel: DiagnosticLogLevel.warn),
    );
    await threshold.init();
    threshold.enqueue(DiagnosticLogEvent.create(
      level: DiagnosticLogLevel.info,
      source: 'flutter',
      category: 'below',
      message: 'skip',
    ));
    threshold.enqueue(DiagnosticLogEvent.create(
      level: DiagnosticLogLevel.warn,
      source: 'flutter',
      category: 'above',
      message: 'write',
    ));
    await threshold.flush();
    final lines = await File('${logDir.path}/app.log.jsonl').readAsLines();
    expect(lines, hasLength(1));
    expect(lines.single, contains('above'));
  });

  test('writer init failure disables writes without hanging flush', () async {
    final blockedPath = '${tempDir.path}/not_a_directory';
    File(blockedPath).writeAsStringSync('blocks directory creation');
    final warnings = <String?>[];
    final writer = DiagnosticLogWriter(
      directory: Directory(blockedPath),
      config: const DiagnosticLogConfig(),
      consoleWarn: (message, {wrapWidth}) => warnings.add(message),
    );

    await writer.init();
    writer.enqueue(DiagnosticLogEvent.create(
      level: DiagnosticLogLevel.error,
      source: 'flutter',
      category: 'test.failure',
      message: 'should not write',
    ));
    await writer.flush().timeout(const Duration(milliseconds: 100));

    expect(warnings.single, contains('diagnostic log init failed'));
  });

  test('debugPrint wrapper forwards to original and captures locally',
      () async {
    final forwarded = <String?>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      forwarded.add(message);
    };
    try {
      DiagnosticDebugPrint.install((message) {
        DiagnosticLog.debug('debug_print', message);
      });
      await DiagnosticLog.init(directory: tempDir.path);

      debugPrint('hello console');
      await DiagnosticLog.flush();

      expect(forwarded, contains('hello console'));
      final file = File('${tempDir.path}/logs/app.log.jsonl');
      expect(file.existsSync(), isTrue);
      expect(await file.readAsString(), contains('hello console'));
    } finally {
      await DiagnosticLog.resetForTest();
      debugPrint = original;
    }
  });
}
