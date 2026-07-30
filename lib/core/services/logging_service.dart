import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart' as pkg_logging;
import 'package:logging/logging.dart' show Level;

/// Centralized application logger.
///
/// Usage:
/// ```dart
/// final log = LoggingService.logger('MyService');
/// log.info('Something happened');
/// log.warning('Something concerning');
/// log.severe('Something fatal');
/// ```
///
/// In production, only warnings and above are printed to the console
/// (via [pkg_logging]). In debug mode, all levels are shown.
/// To integrate with Sentry/Crashlytics, add a custom [pkg_logging.LogRecord]
/// handler to [pkg_logging.rootLogger].
///
/// NEVER use `print()` or `debugPrint()` for production logging.
class LoggingService {
  static bool _initialized = false;

  /// Call once at app startup before any other logging.
  static void init({Level? overrideLevel}) {
    if (_initialized) return;
    _initialized = true;

    // hierarchicalLoggingEnabled is a top-level setter. Access via Logger.root level.
    pkg_logging.Logger.root.level = Level.ALL; // Enable all levels, filter in listener

    final level = overrideLevel ??
        (kReleaseMode ? Level.WARNING : Level.ALL);

    pkg_logging.Logger.root.level = level;

    pkg_logging.Logger.root.onRecord.listen((pkg_logging.LogRecord record) {
      if (kReleaseMode && record.level < Level.WARNING) return;

      final safeMsg = sanitize(record.message);
      final buffer = StringBuffer()
        ..write('${record.level.name}: ${record.loggerName}: $safeMsg');
      if (record.error != null) {
        buffer.write(' | error: ${sanitize(record.error.toString())}');
      }
      debugPrint(buffer.toString());
    });
  }

  /// Returns a named [pkg_logging.Logger] for use throughout the app.
  static pkg_logging.Logger logger(String name) {
    if (!_initialized) init();
    return pkg_logging.Logger(name);
  }

  /// Attempts to redact sensitive patterns from log messages.
  /// Extend this list as new patterns are identified.
  static String sanitize(String message) {
    // Redact Bearer tokens
    var result = message.replaceAllMapped(
      RegExp(r'Bearer\s+\S+', caseSensitive: false),
      (_) => 'Bearer [REDACTED]',
    );
    // Redact API keys in query params
    result = result.replaceAllMapped(
      RegExp(r'[?&](api[_-]?key|token|secret|password|signature)=\S+',
          caseSensitive: false),
      (m) => '${m.group(0)!.split('=').first}=[REDACTED]',
    );
    // Redact passwords in URLs
    result = result.replaceAllMapped(
      RegExp(r'://[^:]+:[^@]+@'),
      (m) => '://[REDACTED]:[REDACTED]@',
    );
    return result;
  }

  /// Convenience alias — returns a named [pkg_logging.Logger].
  static pkg_logging.Logger log(String name) => logger(name);
}

/// Convenience extension on [pkg_logging.Logger] for structured logging.
extension LoggingExtension on pkg_logging.Logger {
  void trace(String message) => finest(message);
}
