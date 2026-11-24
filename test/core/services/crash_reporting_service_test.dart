import 'package:dmx/core/services/crash_reporting_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CrashReportingService.redactSensitive', () {
    test('redacts bearer tokens', () {
      expect(
        CrashReportingService.redactSensitive('Authorization: Bearer abc.def'),
        contains('Bearer ***'),
      );
    });

    test('redacts sensitive key/value pairs', () {
      expect(
        CrashReportingService.redactSensitive('token=supersecret&x=1'),
        'token=***&x=1',
      );
      expect(
        CrashReportingService.redactSensitive('apikey: 12345'),
        'apikey: ***',
      );
      expect(
        CrashReportingService.redactSensitive('password=p@ssw0rd'),
        'password=***',
      );
    });

    test('redacts sensitive query params inside URLs', () {
      final redacted = CrashReportingService.redactSensitive(
        'fetching https://cdn.example.com/file?token=abc&name=video',
      );
      expect(redacted, isNot(contains('abc')));
      expect(redacted, contains('token=***'));
      expect(redacted, contains('name=video'));
    });

    test('leaves harmless strings unchanged', () {
      expect(
        CrashReportingService.redactSensitive('nothing sensitive here'),
        'nothing sensitive here',
      );
    });
  });

  group('CrashReportingService lifecycle', () {
    test('default reporter is the no-op reporter', () {
      expect(CrashReportingService.reporter, isA<NoOpCrashReporter>());
    });

    test('init without DSN selects the no-op reporter', () async {
      await CrashReportingService.init();
      expect(CrashReportingService.reporter, isA<NoOpCrashReporter>());
      // Second init short-circuits.
      await CrashReportingService.init();
      expect(CrashReportingService.reporter, isA<NoOpCrashReporter>());
    });

    test('recordError, setContext and addBreadcrumb are safe', () async {
      await CrashReportingService.recordError(
        StateError('boom'),
        StackTrace.current,
        hint: 'token=secret',
      );
      await CrashReportingService.setContext('ctx', {'a': 1});
      await CrashReportingService.addBreadcrumb(
        'token=secret breadcrumb',
        category: 'engine',
        data: {'url': 'https://x.com/?token=abc', 'ok': true},
      );
    });

    test('captureFlutterErrors records through the Flutter error hook', () {
      final original = FlutterError.onError;
      try {
        CrashReportingService.captureFlutterErrors();
        FlutterError.onError?.call(
          FlutterErrorDetails(exception: StateError('flutter-boom')),
        );
      } finally {
        FlutterError.onError = original;
      }
    });

    test('runWithErrorCapture swallows unhandled zone errors', () async {
      var ran = false;
      CrashReportingService.runWithErrorCapture(() async {
        ran = true;
        throw StateError('zone-boom');
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ran, isTrue);
    });
  });

  group('NoOpCrashReporter', () {
    test('every method completes without error', () async {
      final reporter = NoOpCrashReporter();
      await reporter.init(dsn: 'x');
      await reporter.recordError(
        Exception('e'),
        StackTrace.current,
        hint: 'h',
      );
      await reporter.recordLog(Level.INFO, 'message');
      await reporter.setContext('k', {'v': 1});
      await reporter.addBreadcrumb('m', category: 'c', data: {'d': 1});
    });
  });
}
