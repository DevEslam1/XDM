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
  Future<void> setContext(String key, Map<String, dynamic> value);
  Future<void> addBreadcrumb(String message,
      {String? category, Map<String, dynamic>? data});
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

  @override
  Future<void> setContext(String key, Map<String, dynamic> value) async {}

  @override
  Future<void> addBreadcrumb(String message,
      {String? category, Map<String, dynamic>? data}) async {}
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
      options.environment = kDebugMode ? 'dev' : 'production';
      options.beforeSend = (event, hint) {
        // Redact URLs that carry auth tokens (e.g. signed download URLs).
        // Assign values directly to the event — this is future-proof and
        // avoids copyWith deprecation.
        if (event.request?.url != null && event.request!.url!.contains('?')) {
          final uri = Uri.tryParse(event.request!.url!);
          if (uri != null) {
            final redacted = uri.replace(queryParameters: {
              for (final entry in uri.queryParameters.entries)
                entry.key: entry.key.toLowerCase().contains('token') ||
                        entry.key.toLowerCase().contains('key') ||
                        entry.key.toLowerCase().contains('auth') ||
                        entry.key.toLowerCase().contains('sig') ||
                        entry.key.toLowerCase().contains('secret')
                    ? '***'
                    : entry.value,
            }).toString();
            event.request?.url = redacted;
          }
        }
        // Strip credential-bearing exceptions/messages.
        final message = event.message;
        if (message != null) {
          event.message = SentryMessage(_redactSensitive(message.formatted));
        }
        return event;
      };
    });
    _reporter = SentryCrashReporter();
  }

  static final RegExp _sensitiveUrlPattern = RegExp(
      r'''(https?://[^\s"'<]+)(?<params>[?&][^\s"'<]*)''',
      caseSensitive: false);

  static String _redactSensitive(String input) {
    return input.replaceAllMapped(_sensitiveUrlPattern, (match) {
      final regExpMatch = match as RegExpMatch;
      final String query = regExpMatch.namedGroup('params') ?? '';
      if (query.isEmpty) return match.group(0)!;
      final sanitized = query.split('&').map((String part) {
        final idx = part.indexOf('=');
        if (idx <= 0) return part;
        final name = part.substring(0, idx).toLowerCase();
        return (name.contains('token') ||
                name.contains('key') ||
                name.contains('auth') ||
                name.contains('sig') ||
                name.contains('secret'))
            ? '${part.substring(0, idx)}=***'
            : part;
      }).join('&');
      return '${match.group(1)}$sanitized';
    });
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

  /// Sets contextual metadata under [key].
  static Future<void> setContext(String key, Map<String, dynamic> value) async {
    await reporter.setContext(key, value);
  }

  /// Adds a telemetry/execution breadcrumb.
  static Future<void> addBreadcrumb(
    String message, {
    String? category,
    Map<String, dynamic>? data,
  }) async {
    await reporter.addBreadcrumb(message, category: category, data: data);
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
        ).catchError((e, st) {
          pkg_logging.Logger('crash_reporting_service')
              .warning('[crash_reporting_service] operation failed', e, st);
        }),
      );
    };
  }

  /// Wraps [main] in a zone that captures unhandled errors.
  /// Usage: `CrashReportingService.runWithErrorCapture(() => runApp(...))`
  static void runWithErrorCapture(FutureOr<void> Function() appRunner) {
    runZonedGuarded(
      () async {
        await appRunner();
      },
      (Object error, StackTrace stack) {
        unawaited(
          recordError(
            error,
            stack,
            hint: 'Unhandled zone error',
          ).catchError((e, st) {
            pkg_logging.Logger('crash_reporting_service')
                .warning('[crash_reporting_service] operation failed', e, st);
          }),
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

  @override
  Future<void> setContext(String key, Map<String, dynamic> value) async {
    await Sentry.configureScope((scope) {
      scope.setContexts(key, value);
    });
  }

  @override
  Future<void> addBreadcrumb(
    String message, {
    String? category,
    Map<String, dynamic>? data,
  }) async {
    await Sentry.addBreadcrumb(
      Breadcrumb(
        message: message,
        category: category ?? 'app',
        data: data,
        timestamp: DateTime.now().toUtc(),
      ),
    );
  }

  SentryLevel _mapLevel(pkg_logging.Level level) {
    if (level >= pkg_logging.Level.SEVERE) return SentryLevel.error;
    if (level >= pkg_logging.Level.WARNING) return SentryLevel.warning;
    if (level >= pkg_logging.Level.INFO) return SentryLevel.info;
    return SentryLevel.debug;
  }
}