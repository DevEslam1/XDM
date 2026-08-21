import 'package:dmx/core/services/production_telemetry_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final telemetry = ProductionTelemetryService.instance;

  setUp(() {
    telemetry.resetForTesting();
  });

  tearDown(() {
    telemetry.resetForTesting();
  });

  group('Task 7: Production Telemetry Suite', () {
    test('Opt-in requirement: ignores metric recording when optInEnabled is false', () {
      ProductionTelemetryService.optInEnabled = false;

      telemetry.recordTaskCreated();
      telemetry.recordTaskFailure();
      telemetry.recordResumeAttempt(isMismatch: true);
      telemetry.recordJournalRecovery();

      final report = telemetry.generateReport();
      expect(report['optIn'], isFalse);
      expect(report['totalTasks'], equals(0));
      expect(report['journalRecoveryCount'], equals(0));
    });

    test('Aggregates failure and mismatch rates accurately when optInEnabled is true', () {
      ProductionTelemetryService.optInEnabled = true;

      // 10 tasks created, 2 failed
      for (int i = 0; i < 10; i++) {
        telemetry.recordTaskCreated();
      }
      telemetry.recordTaskFailure();
      telemetry.recordTaskFailure();

      // 4 resume attempts, 1 mismatch
      telemetry.recordResumeAttempt(isMismatch: false);
      telemetry.recordResumeAttempt(isMismatch: false);
      telemetry.recordResumeAttempt(isMismatch: false);
      telemetry.recordResumeAttempt(isMismatch: true);

      // 2 merge attempts, 1 failure
      telemetry.recordMergeAttempt(isSuccess: true);
      telemetry.recordMergeAttempt(isSuccess: false);

      // Frame metrics
      telemetry.recordFrameMetrics(total: 1000, jank: 15);

      final report = telemetry.generateReport();
      expect(report['optIn'], isTrue);
      expect(report['totalTasks'], equals(10));
      expect(report['failedDownloadRate'], equals(0.2));
      expect(report['resumeMismatchRate'], equals(0.25));
      expect(report['mergeFailureRate'], equals(0.5));
      expect(report['jankRatio'], equals(0.015));
    });

    test('Guarantees 100% PII-free reports (no URLs, filepaths, secrets, or tokens)', () {
      ProductionTelemetryService.optInEnabled = true;

      telemetry.recordTaskCreated();
      telemetry.recordTaskFailure();

      final report = telemetry.generateReport();
      final reportStr = report.toString().toLowerCase();

      expect(reportStr, isNot(contains('http:')));
      expect(reportStr, isNot(contains('https:')));
      expect(reportStr, isNot(contains('token')));
      expect(reportStr, isNot(contains('cookie')));
      expect(reportStr, isNot(contains('/')));
      expect(reportStr, isNot(contains('\\')));
    });
  });
}
