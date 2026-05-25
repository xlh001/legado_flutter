import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'diagnostic_log_event.dart';
import 'diagnostic_log_level.dart';

class DiagnosticLogConfig {
  final bool enabled;
  final DiagnosticLogLevel minLevel;
  final int maxFiles;
  final int maxBytesPerFile;
  final int maxAgeDays;
  final int maxQueueSize;

  const DiagnosticLogConfig({
    this.enabled = true,
    this.minLevel = DiagnosticLogLevel.debug,
    this.maxFiles = 5,
    this.maxBytesPerFile = 1024 * 1024,
    this.maxAgeDays = 14,
    this.maxQueueSize = 1000,
  });

  Map<String, Object?> toMetadata() => <String, Object?>{
        'enabled': enabled,
        'level': minLevel.key,
        'max_files': maxFiles,
        'max_bytes_per_file': maxBytesPerFile,
        'max_age_days': maxAgeDays,
      };
}

class DiagnosticLogWriter {
  static const String activeFileName = 'app.log.jsonl';

  final Directory directory;
  DiagnosticLogConfig config;
  final void Function(String? message, {int? wrapWidth})? consoleWarn;

  final Queue<DiagnosticLogEvent> _queue = Queue<DiagnosticLogEvent>();
  bool _draining = false;
  bool _fileWritesDisabled = false;
  bool _warnedWriteFailure = false;
  bool _dropWarningQueued = false;

  DiagnosticLogWriter({
    required this.directory,
    required this.config,
    this.consoleWarn,
  });

  File get activeFile => File('${directory.path}/$activeFileName');

  Future<void> init() async {
    try {
      await directory.create(recursive: true);
      await cleanupRetention();
    } catch (e) {
      _disableWrites('diagnostic log init failed: $e');
    }
  }

  void enqueue(DiagnosticLogEvent event) {
    if (!config.enabled || _fileWritesDisabled) return;
    if (event.level.priority < config.minLevel.priority) return;
    try {
      _queue.add(event);
      _enforceQueueLimit();
      if (!_draining) {
        _draining = true;
        scheduleMicrotask(_drain);
      }
    } catch (_) {
      // Logging must never throw into app flows.
    }
  }

  Future<void> flush() async {
    while (_draining || _queue.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> cleanupRetention() async {
    final now = DateTime.now();
    try {
      if (!await directory.exists()) return;
      final maxAge = Duration(days: config.maxAgeDays);
      await for (final entity in directory.list()) {
        if (entity is! File || !_isLogFile(entity)) continue;
        final stat = await entity.stat();
        if (now.difference(stat.modified) > maxAge) {
          await entity.delete();
        }
      }
      final files = await logFiles(directory).toList();
      if (files.length <= config.maxFiles) return;
      for (final file in files.skip(config.maxFiles)) {
        if (await file.exists()) await file.delete();
      }
    } catch (_) {
      // Best-effort retention; never affect app flows.
    }
  }

  static Stream<File> logFiles(Directory directory) async* {
    final files = <File>[];
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File && _isLogFile(entity)) files.add(entity);
    }
    files.sort((a, b) => _fileOrder(a).compareTo(_fileOrder(b)));
    for (final file in files) {
      yield file;
    }
  }

  void _enforceQueueLimit() {
    var dropped = 0;
    while (_queue.length > config.maxQueueSize) {
      final debugEvent = _queue.cast<DiagnosticLogEvent?>().firstWhere(
            (event) => event?.level == DiagnosticLogLevel.debug,
            orElse: () => null,
          );
      if (debugEvent != null) {
        _queue.remove(debugEvent);
      } else {
        _queue.removeFirst();
      }
      dropped++;
    }
    if (dropped > 0 && !_dropWarningQueued) {
      _dropWarningQueued = true;
      _queue.add(DiagnosticLogEvent.create(
        level: DiagnosticLogLevel.warn,
        source: 'flutter',
        category: 'diagnostics.queue',
        message: 'Diagnostic log queue dropped events',
        metadata: {'dropped_count': dropped},
      ));
    }
  }

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty && !_fileWritesDisabled) {
        final event = _queue.removeFirst();
        await _writeEvent(event);
      }
    } catch (e) {
      _disableWrites('diagnostic log write failed: $e');
    } finally {
      _draining = false;
      if (_queue.isNotEmpty && !_fileWritesDisabled) {
        _draining = true;
        scheduleMicrotask(_drain);
      }
    }
  }

  Future<void> _writeEvent(DiagnosticLogEvent event) async {
    await directory.create(recursive: true);
    await _rotateIfNeeded();
    await activeFile.writeAsString(
      '${jsonEncode(event.toJson())}\n',
      mode: FileMode.append,
      flush: false,
    );
  }

  Future<void> _rotateIfNeeded() async {
    final file = activeFile;
    if (!await file.exists()) return;
    final size = await file.length();
    if (size < config.maxBytesPerFile) return;
    await _rotate();
    await cleanupRetention();
  }

  Future<void> _rotate() async {
    final oldest =
        File('${directory.path}/app.${config.maxFiles - 1}.log.jsonl');
    if (await oldest.exists()) await oldest.delete();
    for (var i = config.maxFiles - 2; i >= 1; i--) {
      final from = File('${directory.path}/app.$i.log.jsonl');
      if (await from.exists()) {
        await from.rename('${directory.path}/app.${i + 1}.log.jsonl');
      }
    }
    final active = activeFile;
    if (await active.exists()) {
      await active.rename('${directory.path}/app.1.log.jsonl');
    }
  }

  void _disableWrites(String message) {
    _fileWritesDisabled = true;
    _queue.clear();
    if (!_warnedWriteFailure) {
      _warnedWriteFailure = true;
      (consoleWarn ?? debugPrint)('[Diagnostics] $message');
    }
  }

  static bool _isLogFile(File file) {
    final name = file.uri.pathSegments.last;
    return name == activeFileName ||
        RegExp(r'^app\.\d+\.log\.jsonl$').hasMatch(name);
  }

  static int _fileOrder(File file) {
    final name = file.uri.pathSegments.last;
    if (name == activeFileName) return 0;
    final match = RegExp(r'^app\.(\d+)\.log\.jsonl$').firstMatch(name);
    return match == null ? 9999 : int.parse(match.group(1)!);
  }
}
