enum DiagnosticLogLevel {
  debug,
  info,
  warn,
  error;

  String get key => name;

  int get priority {
    switch (this) {
      case DiagnosticLogLevel.debug:
        return 0;
      case DiagnosticLogLevel.info:
        return 1;
      case DiagnosticLogLevel.warn:
        return 2;
      case DiagnosticLogLevel.error:
        return 3;
    }
  }

  static DiagnosticLogLevel fromKey(String value) {
    for (final level in DiagnosticLogLevel.values) {
      if (level.key == value.toLowerCase()) return level;
    }
    return DiagnosticLogLevel.debug;
  }
}
