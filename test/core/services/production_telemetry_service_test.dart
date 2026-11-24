import 'package:dmx/core/services/production_telemetry_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProductionTelemetryService', () {
    final service = ProductionTelemetryService.instance;

    setUp(service.resetForTesting);

    test('records are ignored while opt-in is disabled', () {
      ProductionTelemetryService.optInEnabled = false;
      service.recordTaskCreated();
      service.recordTaskFailure();
      service.recordResumeAttempt(isMismatch: true);
      service.recordMergeAttempt(isSuccess: false);
      service.recordJournalRecovery();
      service.recordWakelockFailure();
      service.recordDbWriteFailure();
      service.recordFrameMetrics(total: 100, jank: 5);

      final report = service.generateReport();
      expect(report['totalTasks'], 0);
      expect(report['jankRatio'], 0.0);
      expect(report['resumeMismatchRate'], 0.0);
      expect(report['mergeFailureRate'], 0.0);
      expect(report['journalRecoveryCount'], 0);
      expect(report['wakelockFailures'], 0);
      expect(report['dbWriteFailures'], 0);
    });

    test('records aggregate correctly while opt-in is enabled', () {
      ProductionTelemetryService.optInEnabled = true;
      service.recordTaskCreated();
      service.recordTaskCreated();
      service.recordTaskFailure();
      service.recordResumeAttempt(isMismatch: false);
      service.recordResumeAttempt(isMismatch: true);
      service.recordMergeAttempt(isSuccess: true);
      service.recordMergeAttempt(isSuccess: false);
      service.recordJournalRecovery();
      service.recordWakelockFailure();
      service.recordDbWriteFailure();
      service.recordFrameMetrics(total: 1000, jank: 100);

      final report = service.generateReport();
      expect(report['optIn'], isTrue);
      expect(report['totalTasks'], 2);
      expect(report['jankRatio'], 0.1);
      expect(report['failedDownloadRate'], 0.5);
      expect(report['resumeMismatchRate'], 0.5);
      expect(report['mergeFailureRate'], 0.5);
      expect(report['journalRecoveryCount'], 1);
      expect(report['wakelockFailures'], 1);
      expect(report['dbWriteFailures'], 1);
    });

    test('session and clean exit counters increment unconditionally', () {
      service.recordSessionStart();
      service.recordSessionStart();
      service.recordCleanExit();
      final report = service.generateReport();
      expect(report['sessions'], 3);
      expect(report['cleanExits'], 1);
    });

    test('resetForTesting restores initial state', () {
      ProductionTelemetryService.optInEnabled = true;
      service.recordTaskCreated();
      service.resetForTesting();
      final report = service.generateReport();
      expect(report['sessions'], 1);
      expect(report['totalTasks'], 0);
      expect(report['optIn'], isFalse);
    });

    test('failure timestamp queue stays bounded', () {
      ProductionTelemetryService.optInEnabled = true;
      for (var i = 0; i < 150; i++) {
        service.recordTaskCreated();
        service.recordTaskFailure();
      }
      expect(service.generateReport()['failedDownloadRate'], 1.0);
    });
  });
}
