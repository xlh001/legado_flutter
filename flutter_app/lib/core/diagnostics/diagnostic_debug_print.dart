import 'package:flutter/foundation.dart';

typedef DiagnosticDebugPrintSink = void Function(String message);

class DiagnosticDebugPrint {
  static DebugPrintCallback? _original;
  static bool _installed = false;

  const DiagnosticDebugPrint._();

  static DebugPrintCallback get original => _original ?? debugPrint;

  static void install(DiagnosticDebugPrintSink sink) {
    if (_installed) return;
    _original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      _original?.call(message, wrapWidth: wrapWidth);
      if (message == null) return;
      try {
        sink(message);
      } catch (_) {
        // Logging must never interfere with console output.
      }
    };
    _installed = true;
  }

  static void uninstallForTest() {
    if (_installed && _original != null) {
      debugPrint = _original!;
    }
    _original = null;
    _installed = false;
  }
}
