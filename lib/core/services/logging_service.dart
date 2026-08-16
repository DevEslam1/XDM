import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:dmx/core/services/background_gate.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart' as pkg_logging;
import 'package:logging/logging.dart' show Level;
import 'package:synchronized/synchronized.dart';

/// Centralized application logger with console and optional rolling file logging.
class LoggingService {
  static bool _initialized = false;
  static File? _logFile;
  static IOSink? _fileSink;
  static final Lock _bufferLock = Lock();

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

      if (kReleaseMode) {
        _bufferReleaseLog(entryStr);
        developer.log(
          safeMsg,
          name: record.loggerName,
          level: record.level.value,
          error:
              record.error == null ? null : sanitize(record.error.toString()),
        );
        return;
      }

      _writeToFile(entryStr);
      debugPrint('${record.level.name}: ${record.loggerName}: $safeMsg');
    });
  }

  static final List<String> _releaseLogBuffer = [];
  static Timer? _releaseFlushTimer;
  static const int _maxReleaseBufferSize = 500;

  static Duration _adaptedInterval() {
    return BackgroundGate.adaptInterval(const Duration(seconds: 30));
  }

  @visibleForTesting
  static Duration adaptedIntervalForTesting() => _adaptedInterval();

  @visibleForTesting
  static void bufferReleaseLogForTesting(String entry) =>
      _bufferReleaseLog(entry);

  static void _onFlush() {
    flushLogBuffer();
    _bufferLock.synchronized(() {
      if (_releaseLogBuffer.isNotEmpty) {
        _releaseFlushTimer = Timer(_adaptedInterval(), _onFlush);
      } else {
        _releaseFlushTimer = null;
      }
    });
  }

  static void _bufferReleaseLog(String entry) {
    _bufferLock.synchronized(() {
      _releaseLogBuffer.add(entry);
      if (_releaseLogBuffer.length >= _maxReleaseBufferSize) {
        flushLogBuffer();
        _releaseFlushTimer?.cancel();
        _releaseFlushTimer = null;
      } else {
        _releaseFlushTimer ??= Timer(_adaptedInterval(), _onFlush);
      }
    });
  }

  static void flushLogBuffer() {
    _bufferLock.synchronized(() {
      if (_releaseLogBuffer.isEmpty) return;
      final toWrite = _releaseLogBuffer.join('');
      _releaseLogBuffer.clear();
      _writeToFile(toWrite);
    });
  }

  static void _initFileLogging(Directory dir) {
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _logFile = File('${dir.path}/app_log.txt');
      _rotateLogsIfNeeded(dir);
      _fileSink = _logFile!.openWrite(mode: FileMode.append);
    } catch (e, st) {
      LoggingService.logger('LoggingService')
          .warning('Operation failed', e, st);
    }
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
    } catch (e, st) {
      LoggingService.logger('LoggingService')
          .warning('Operation failed', e, st);
    }
  }

  static void _writeToFile(String text) {
    try {
      _fileSink?.write(text);
    } catch (e, st) {
      LoggingService.logger('LoggingService')
          .warning('Operation failed', e, st);
    }
  }

  @visibleForTesting
  static bool get hasActiveTimer => _releaseFlushTimer != null;

  @visibleForTesting
  static void setReleaseFlushTimerForTesting(Timer timer) {
    _releaseFlushTimer?.cancel();
    _releaseFlushTimer = timer;
  }

  static void closeFileLogging() => dispose();

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

  // FIX-1.2: Cancel _releaseFlushTimer and flush logs on dispose
  static void dispose() {
    _releaseFlushTimer?.cancel();
    _releaseFlushTimer = null;
    flushLogBuffer();
    try {
      _fileSink?.close();
      _fileSink = null;
    } catch (e, st) {
      LoggingService.logger('LoggingService')
          .warning('Operation failed', e, st);
    }
    _initialized = false;
  }
}

extension LoggingExtension on pkg_logging.Logger {
  void trace(String message) => finest(message);
}
