import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../persistence/json_store.dart';
import 'diagnostic_debug_print.dart';
import 'diagnostic_log_event.dart';
import 'diagnostic_log_level.dart';
import 'diagnostic_log_reader.dart';
import 'diagnostic_log_writer.dart';

abstract final class DiagnosticLog {
  static DiagnosticLogWriter? _writer;
  static Directory? _directory;
  static FlutterExceptionHandler? _previousFlutterError;
  static ErrorCallback? _previousPlatformError;
  static bool _handlersInstalled = false;

  static Directory? get directory => _directory;
  static DiagnosticLogConfig get config =>
      _writer?.config ?? const DiagnosticLogConfig();

  static Future<void> init({
    String? directory,
    bool enabled = true,
    DiagnosticLogLevel minLevel = DiagnosticLogLevel.debug,
    int maxFiles = 5,
    int maxBytesPerFile = 1024 * 1024,
    int maxAgeDays = 14,
  }) async {
    try {
      final persistenceDir = await resolvePersistenceDir(directory: directory);
      final logDir = Directory('$persistenceDir/logs');
      final originalConsole = DiagnosticDebugPrint.original;
      final writer = DiagnosticLogWriter(
        directory: logDir,
        config: DiagnosticLogConfig(
          enabled: enabled,
          minLevel: minLevel,
          maxFiles: maxFiles,
          maxBytesPerFile: maxBytesPerFile,
          maxAgeDays: maxAgeDays,
        ),
        consoleWarn: originalConsole,
      );
      await writer.init();
      _writer = writer;
      _directory = logDir;
      DiagnosticDebugPrint.install(
        (message) => debug('debug_print', message, source: 'flutter'),
      );
      installGlobalErrorHandlers();
      info(
        'app.environment',
        'App diagnostics initialized',
        metadata: <String, Object?>{
          'build_mode': kReleaseMode
              ? 'release'
              : kProfileMode
                  ? 'profile'
                  : 'debug',
          'platform': _platformName(),
          'os_version': kIsWeb ? 'web' : Platform.operatingSystemVersion,
          'diagnostics': writer.config.toMetadata(),
        },
      );
    } catch (e) {
      debugPrint('[Diagnostics] init failed: $e');
    }
  }

  static void installGlobalErrorHandlers() {
    if (_handlersInstalled) return;
    _previousFlutterError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      try {
        final previous = _previousFlutterError;
        FlutterError.presentError(details);
        if (previous != null && previous != FlutterError.presentError) {
          previous(details);
        }
        error(
          'flutter.framework_error',
          'Flutter framework error',
          error: details.exceptionAsString(),
          stack: details.stack,
          metadata: {
            'library': details.library,
            'context': details.context?.toString()
          },
        );
      } catch (_) {
        FlutterError.presentError(details);
      }
    };
    _previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      DiagnosticLog.error(
        'flutter.platform_error',
        'Uncaught root isolate error',
        error: error,
        stack: stack,
      );
      final previous = _previousPlatformError;
      if (previous != null) previous(error, stack);
      return true;
    };
    _handlersInstalled = true;
  }

  static void debug(
    String category,
    String message, {
    Map<String, Object?>? metadata,
    String source = 'flutter',
  }) {
    _log(DiagnosticLogLevel.debug, source, category, message,
        metadata: metadata);
  }

  static void info(
    String category,
    String message, {
    Map<String, Object?>? metadata,
    String source = 'flutter',
  }) {
    _log(DiagnosticLogLevel.info, source, category, message,
        metadata: metadata);
  }

  static void warn(
    String category,
    String message, {
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? metadata,
    String source = 'flutter',
  }) {
    _log(
      DiagnosticLogLevel.warn,
      source,
      category,
      message,
      error: error,
      stack: stack,
      metadata: metadata,
    );
  }

  static void error(
    String category,
    String message, {
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? metadata,
    String source = 'flutter',
  }) {
    _log(
      DiagnosticLogLevel.error,
      source,
      category,
      message,
      error: error,
      stack: stack,
      metadata: metadata,
    );
  }

  static void breadcrumb(
    String category,
    String message, {
    Map<String, Object?>? metadata,
  }) {
    info(category, message, metadata: metadata, source: 'user');
  }

  static DiagnosticLogReader? reader() {
    final dir = _directory;
    return dir == null ? null : DiagnosticLogReader(dir);
  }

  static Future<void> flush() async => _writer?.flush();

  static Future<void> resetForTest() async {
    FlutterError.onError = _previousFlutterError;
    PlatformDispatcher.instance.onError = _previousPlatformError;
    _previousFlutterError = null;
    _previousPlatformError = null;
    _handlersInstalled = false;
    await _writer?.flush();
    _writer = null;
    _directory = null;
    DiagnosticDebugPrint.uninstallForTest();
  }

  static void _log(
    DiagnosticLogLevel level,
    String source,
    String category,
    String message, {
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? metadata,
  }) {
    try {
      _writer?.enqueue(DiagnosticLogEvent.create(
        level: level,
        source: source,
        category: category,
        message: message,
        error: error,
        stack: stack,
        metadata: metadata,
      ));
    } catch (_) {
      // Logging must never throw into app flows.
    }
  }

  static String _platformName() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isFuchsia) return 'fuchsia';
    return Platform.operatingSystem;
  }
}

void runAppWithDiagnosticZone(FutureOr<void> Function() body) {
  runZonedGuarded(
    body,
    (error, stack) {
      DiagnosticLog.error(
        'flutter.zone_error',
        'Uncaught async error',
        error: error,
        stack: stack,
      );
    },
  );
}
