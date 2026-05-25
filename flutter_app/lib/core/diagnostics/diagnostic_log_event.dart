import 'diagnostic_log_level.dart';
import 'diagnostic_redactor.dart';

class DiagnosticLogEvent {
  final DateTime timestamp;
  final DiagnosticLogLevel level;
  final String source;
  final String category;
  final String message;
  final String? error;
  final String? stack;
  final Map<String, Object?>? metadata;

  DiagnosticLogEvent({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.category,
    required this.message,
    this.error,
    this.stack,
    this.metadata,
  });

  factory DiagnosticLogEvent.create({
    required DiagnosticLogLevel level,
    required String source,
    required String category,
    required String message,
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? metadata,
  }) {
    return DiagnosticLogEvent(
      timestamp: DateTime.now().toUtc(),
      level: level,
      source: source,
      category: category,
      message: DiagnosticRedactor.sanitizeMessage(message),
      error: level.priority >= DiagnosticLogLevel.warn.priority
          ? DiagnosticRedactor.sanitizeError(error)
          : null,
      stack: level.priority >= DiagnosticLogLevel.warn.priority
          ? DiagnosticRedactor.sanitizeStack(stack)
          : null,
      metadata: metadata == null
          ? null
          : DiagnosticRedactor.sanitizeMetadata(metadata)
              as Map<String, Object?>,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'ts': timestamp.toIso8601String(),
      'level': level.key,
      'source': source,
      'category': category,
      'message': message,
      if (error != null) 'error': error,
      if (stack != null) 'stack': stack,
      if (metadata != null) 'metadata': metadata,
    };
  }
}
