import 'package:dmx/core/services/diagnostic_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DiagnosticService diagnosticService;

  setUp(() {
    diagnosticService = DiagnosticService();
    diagnosticService.clear();
    diagnosticService.resetTelemetryMetrics();
  });

  group('Phase 8 — Telemetry Alerts Contract Tests', () {
    test('Records resume_range_ignored alert and updates counter', () {
      diagnosticService.recordTelemetryAlert(
        'resume_range_ignored',
        taskId: 'task-range-1',
        details: 'Server returned HTTP 200 instead of 206',
      );

      expect(diagnosticService.resumeRangeIgnoredCount, equals(1));
      final snapshot = diagnosticService.telemetryMetricsSnapshot();
      expect(snapshot['resumeRangeIgnored'], equals(1));

      final entries = diagnosticService.entries;
      expect(entries.any((e) => e.message == 'resume_range_ignored'), isTrue);
    });

    test('Records journal_reconciled alert and updates counter', () {
      diagnosticService.recordTelemetryAlert(
        'journal_reconciled',
        taskId: 'task-journal-1',
        details: 'Reconciled 10485760 bytes from disk journal',
      );

      expect(diagnosticService.journalReconciledCount, equals(1));
      final snapshot = diagnosticService.telemetryMetricsSnapshot();
      expect(snapshot['journalReconciled'], equals(1));
    });

    test('Records resume_data_missing alert and updates counter', () {
      diagnosticService.recordTelemetryAlert(
        'resume_data_missing',
        taskId: 'task-state-missing-1',
        details: 'State file corrupt; fallback to fresh download',
      );

      expect(diagnosticService.resumeDataMissingCount, equals(1));
      final snapshot = diagnosticService.telemetryMetricsSnapshot();
      expect(snapshot['resumeDataMissing'], equals(1));
    });

    test('Records watchdog_skip_paused alert and updates counter', () {
      diagnosticService.recordTelemetryAlert(
        'watchdog_skip_paused',
        taskId: 'task-paused-1',
        details: 'Watchdog skipped paused task',
      );

      expect(diagnosticService.watchdogSkipPausedCount, equals(1));
      final snapshot = diagnosticService.telemetryMetricsSnapshot();
      expect(snapshot['watchdogSkipPaused'], equals(1));
    });

    test('resetTelemetryMetrics resets all alert counters', () {
      diagnosticService.recordTelemetryAlert('resume_range_ignored', taskId: 't1');
      diagnosticService.recordTelemetryAlert('journal_reconciled', taskId: 't2');
      diagnosticService.recordTelemetryAlert('resume_data_missing', taskId: 't3');
      diagnosticService.recordTelemetryAlert('watchdog_skip_paused', taskId: 't4');

      expect(diagnosticService.resumeRangeIgnoredCount, equals(1));
      expect(diagnosticService.journalReconciledCount, equals(1));
      expect(diagnosticService.resumeDataMissingCount, equals(1));
      expect(diagnosticService.watchdogSkipPausedCount, equals(1));

      diagnosticService.resetTelemetryMetrics();

      expect(diagnosticService.resumeRangeIgnoredCount, equals(0));
      expect(diagnosticService.journalReconciledCount, equals(0));
      expect(diagnosticService.resumeDataMissingCount, equals(0));
      expect(diagnosticService.watchdogSkipPausedCount, equals(0));

      final snapshot = diagnosticService.telemetryMetricsSnapshot();
      expect(snapshot['resumeRangeIgnored'], equals(0));
      expect(snapshot['journalReconciled'], equals(0));
      expect(snapshot['resumeDataMissing'], equals(0));
      expect(snapshot['watchdogSkipPaused'], equals(0));
    });
  });
}
