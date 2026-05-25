import 'dart:math' as math;

const String kDiagnosticRedactedValue = '[REDACTED]';

class DiagnosticRedactor {
  static const int metadataStringLimit = 512;
  static const int stackStringLimit = 8 * 1024;
  static const String _truncatedSuffix = '...[truncated]';

  static final RegExp _sensitiveKeyPattern = RegExp(
    r'(password|passwd|token|secret|authorization|cookie|set-cookie|key|credential|refresh_token|access_token)',
    caseSensitive: false,
  );

  static final RegExp _obviousSecretPattern = RegExp(
    r'((authorization|cookie|set-cookie|access_token|refresh_token|token|password|passwd|secret)\s*[:=]\s*)([^\s,;]+)',
    caseSensitive: false,
  );

  const DiagnosticRedactor._();

  static String sanitizeMessage(String message) {
    return _truncate(
      message.replaceAllMapped(
        _obviousSecretPattern,
        (m) => '${m.group(1)}$kDiagnosticRedactedValue',
      ),
      metadataStringLimit,
    );
  }

  static String? sanitizeError(Object? error) {
    if (error == null) return null;
    return sanitizeMessage(error.toString());
  }

  static String? sanitizeStack(StackTrace? stack) {
    if (stack == null) return null;
    final sanitized = stack.toString().replaceAllMapped(
          _obviousSecretPattern,
          (m) => '${m.group(1)}$kDiagnosticRedactedValue',
        );
    return _truncate(sanitized, stackStringLimit);
  }

  static Object? sanitizeMetadata(Object? value, {String? key}) {
    if (key != null && _isSensitiveKey(key)) {
      return kDiagnosticRedactedValue;
    }
    if (value == null || value is num || value is bool) return value;
    if (value is Uri) return _sanitizeUrl(value.toString());
    if (value is String) return _sanitizeStringValue(value, key: key);
    if (value is Map) {
      final result = <String, Object?>{};
      value.forEach((rawKey, rawValue) {
        final childKey = rawKey.toString();
        result[childKey] = sanitizeMetadata(rawValue, key: childKey);
      });
      return result;
    }
    if (value is Iterable) {
      return value
          .map((item) => sanitizeMetadata(item))
          .toList(growable: false);
    }
    return _truncate(value.toString(), metadataStringLimit);
  }

  static bool _isSensitiveKey(String key) => _sensitiveKeyPattern.hasMatch(key);

  static String _sanitizeStringValue(String value, {String? key}) {
    var sanitized = value.replaceAllMapped(
      _obviousSecretPattern,
      (m) => '${m.group(1)}$kDiagnosticRedactedValue',
    );
    final uri = Uri.tryParse(sanitized);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty && uri.hasQuery) {
      sanitized = _sanitizeUrl(sanitized);
    }
    if (key != null && key.toLowerCase().contains('path')) {
      sanitized = sanitized.split(RegExp(r'[/\\]')).last;
    }
    return _truncate(sanitized, metadataStringLimit);
  }

  static String _sanitizeUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return _truncate(value, metadataStringLimit);
    }
    if (!uri.hasQuery) return _truncate(value, metadataStringLimit);
    final redactedQuery = <String, String>{
      for (final key in uri.queryParameters.keys) key: kDiagnosticRedactedValue,
    };
    return _truncate(
      uri.replace(queryParameters: redactedQuery).toString(),
      metadataStringLimit,
    );
  }

  static String _truncate(String value, int limit) {
    if (value.length <= limit) return value;
    final keep = math.max(0, limit - _truncatedSuffix.length);
    return value.substring(0, keep) + _truncatedSuffix;
  }
}
