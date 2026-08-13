import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart' as pkg_logging;
import 'package:logging/logging.dart' show Level;

/// Centralized application logger with console and optional rolling file logging.
class LoggingService {
  static bool _initialized = false;
  static File? _logFile;
  static IOSink? _fileSink;

  /// Call once at app startup before any other logging.
  static void init({Level? overrideLevel, Directory? logDir}) {
    if (_initialized) return;
    _initialized = true;

    final level = overrideLevel ?? (kReleaseMode ? Level.WARNING : Level.ALL);
    pkg_logging.Logger.root.level = level;

    if (logDir != null) {
      _initFileLogging(logDir);
    }

    pkg_logging.Logger.root.onRecord.listen((pkg_logging.LogRecord record) {
      if (kReleaseMode && record.level < Level.WARNING) return;

      final safeMsg = sanitize(record.message);
      final entryStr =
          '${record.time.toIso8601String()} [${record.level.name}] ${record.loggerName}: $safeMsg${record.error != null ? ' | error: ${sanitize(record.error.toString())}' : ''}\n';

      _writeToFile(entryStr);

      if (kReleaseMode) {
        developer.log(
          safeMsg,
          name: record.loggerName,
          level: record.level.value,
          error:
              record.error == null ? null : sanitize(record.error.toString()),
        );
        return;
      }

      debugPrint('${record.level.name}: ${record.loggerName}: $safeMsg');
    });
  }

  static void _initFileLogging(Directory dir) {
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _logFile = File('${dir.path}/app_log.txt');
      _rotateLogsIfNeeded(dir);
      _fileSink = _logFile!.openWrite(mode: FileMode.append);
    } catch (_) {}
  }

  static void _rotateLogsIfNeeded(Directory dir) {
    try {
      if (_logFile != null && _logFile!.existsSync()) {
        if (_logFile!.lengthSync() > 5 * 1024 * 1024) {
          final log2 = File('${dir.path}/app_log.2.txt');
          final log1 = File('${dir.path}/app_log.1.txt');
          if (log2.existsSync()) log2.deleteSync();
          if (log1.existsSync()) log1.renameSync(log2.path);
          _logFile!.renameSync(log1.path);
          _logFile = File('${dir.path}/app_log.txt');
        }
      }
    } catch (_) {}
  }

  static void _writeToFile(String text) {
    try {
      _fileSink?.write(text);
    } catch (_) {}
  }

  static void closeFileLogging() {
    _fileSink?.close();
    _fileSink = null;
  }

  /// Returns a named [pkg_logging.Logger] for use throughout the app.
  static pkg_logging.Logger logger(String name) {
    if (!_initialized) init();
    return pkg_logging.Logger(name);
  }

  /// Attempts to redact sensitive patterns from log messages.
  static String sanitize(String message) {
    var result = message.replaceAllMapped(
      RegExp(r'Bearer\s+\S+', caseSensitive: false),
      (_) => 'Bearer [REDACTED]',
    );
    result = result.replaceAllMapped(
      RegExp(r'Basic\s+\S+', caseSensitive: false),
      (_) => 'Basic [REDACTED]',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'[?&](api[_-]?key|apikey|token|access[_-]?token|secret|password|'
        r'signature|sig|auth|api_key|access_key|secret_key|x-amz-signature|x-amz-credential|'
        r'x-amz-security-token|awsaccesskeyid|googleaccessid|credential|'
        r'hdnts|hdnea|st|exp|auth_code|verify_code|session_token)='
        r'[^&\s]+',
        caseSensitive: false,
      ),
      (m) => '${m.group(0)!.split('=').first}=[REDACTED]',
    );
    result = result.replaceAll(
      RegExp(r'[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'),
      '[JWT REDACTED]',
    );
    result = result.replaceAllMapped(
      RegExp(r'://[^:]+:[^@]+@'),
      (m) => '://[REDACTED]:[REDACTED]@',
    );
    return result;
  }

  static pkg_logging.Logger log(String name) => logger(name);
}

extension LoggingExtension on pkg_logging.Logger {
  void trace(String message) => finest(message);
}
