import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart' as pkg_logging;
import 'package:sentry_flutter/sentry_flutter.dart';

import 'logging_service.dart';

/// Abstract crash reporting adapter.
///
/// To integrate a real backend (Sentry, Firebase Crashlytics, etc.):
///   1. Create a subclass that implements [init], [recordError], and [recordLog].
///   2. Pass the DSN via `--dart-define=SENTRY_DSN=...` or secure storage.
///   3. Call [CrashReportingService.init()] at app startup.
///
/// When no DSN is configured, [NoOpCrashReporter] is used — all calls are
/// silently no-ops.
abstract class CrashReporter {
  Future<void> init({String? dsn});
  Future<void> recordError(Object error, StackTrace stackTrace, {String? hint});
  Future<void> recordLog(pkg_logging.Level level, String message);
}

/// No-op crash reporter used when no DSN is configured.
class NoOpCrashReporter extends CrashReporter {
  @override
  Future<void> init({String? dsn}) async {}

  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    String? hint,
  }) async {}

  @override
  Future<void> recordLog(pkg_logging.Level level, String message) async {}
}

class CrashReportingService {
  static CrashReporter? _reporter;
  static bool _initialized = false;

  /// Initializes crash reporting. If [dsn] is null or empty, uses [NoOpCrashReporter].
  static Future<void> init({String? dsn}) async {
    if (_initialized) return;
    _initialized = true;

    final effectiveDsn = dsn ?? const String.fromEnvironment('SENTRY_DSN');

    if (effectiveDsn.isEmpty) {
      _reporter = NoOpCrashReporter();
      LoggingService.logger(
        'CrashReportingService',
      ).info('No DSN configured — crash reporting is disabled.');
      return;
    }

    await SentryFlutter.init((options) {
      options.dsn = effectiveDsn;
      options.tracesSampleRate = 0.1;
    });
    _reporter = SentryCrashReporter();
  }

  /// Returns the current reporter (never null).
  static CrashReporter get reporter => _reporter ?? NoOpCrashReporter();

  /// Records an error [e] with [stackTrace].
  static Future<void> recordError(
    Object e,
    StackTrace stackTrace, {
    String? hint,
  }) async {
    // Never record secrets
    final safeHint = hint != null ? LoggingService.sanitize(hint) : null;
    await reporter.recordError(e, stackTrace, hint: safeHint);
  }

  /// Captures unhandled Flutter errors.
  /// Call this from main.dart before runApp().
  static void captureFlutterErrors() {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      unawaited(
        recordError(
          details.exception,
          details.stack ?? StackTrace.current,
          hint: details.library,
        ).catchError((_) {}),
      );
    };
  }

  /// Wraps [main] in a zone that captures unhandled errors.
  /// Usage: `CrashReportingService.runWithErrorCapture(() => runApp(...))`
  static void runWithErrorCapture(void Function() appRunner) {
    runZonedGuarded(
      () {
        appRunner();
      },
      (Object error, StackTrace stack) {
        unawaited(
          recordError(
            error,
            stack,
            hint: 'Unhandled zone error',
          ).catchError((_) {}),
        );
      },
    );
  }
}

/// Sentry-backed crash reporter.
///
/// Requires `sentry_flutter` and a valid DSN provided at init time.
/// Pass the DSN via `--dart-define=SENTRY_DSN=...` or directly to
/// [CrashReportingService.init].
class SentryCrashReporter extends CrashReporter {
  @override
  Future<void> init({String? dsn}) async {
    // SentryFlutter.init is called by CrashReportingService.init before
    // constructing this reporter.
  }

  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    String? hint,
  }) async {
    await Sentry.captureException(
      error,
      stackTrace: stackTrace,
      hint: hint != null ? Hint.withMap({'hint': hint}) : null,
    );
  }

  @override
  Future<void> recordLog(pkg_logging.Level level, String message) async {
    if (level >= pkg_logging.Level.SEVERE) {
      await Sentry.captureMessage(message, level: _mapLevel(level));
    }
  }

  SentryLevel _mapLevel(pkg_logging.Level level) {
    if (level >= pkg_logging.Level.SEVERE) return SentryLevel.error;
    if (level >= pkg_logging.Level.WARNING) return SentryLevel.warning;
    if (level >= pkg_logging.Level.INFO) return SentryLevel.info;
    return SentryLevel.debug;
  }
}
