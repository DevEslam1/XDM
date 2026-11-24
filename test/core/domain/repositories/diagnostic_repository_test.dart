import 'package:dmx/core/domain/models/error_family.dart';
import 'package:dmx/core/domain/repositories/diagnostic_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDiagnosticRepository implements DiagnosticRepository {
  @override
  List<DiagnosticEntry> get entries => const [];

  @override
  void record(String area, String message, {Object? error, String? details}) {}

  @override
  void clear() {}

  @override
  String snapshot() => '';

  @override
  Future<Map<String, String>> systemInfo() async => const {};

  @override
  int get isolateBytesTransferred => 0;

  @override
  int get isolateMessageCount => 0;

  @override
  int get currentDbWriteQueueDepth => 0;

  @override
  int get maxDbWriteQueueDepth => 0;

  @override
  int get mirrorHealthHits => 0;

  @override
  int get mirrorHealthMisses => 0;

  @override
  double get mirrorHealthCacheHitRate => 0;

  @override
  double get p95ProgressLatencyMs => 0;

  @override
  int get resumeRangeIgnoredCount => 0;

  @override
  int get journalReconciledCount => 0;

  @override
  int get resumeDataMissingCount => 0;

  @override
  int get watchdogSkipPausedCount => 0;

  @override
  void recordIsolatePayloadSize(int bytes) {}

  @override
  void recordProgressLatency(Duration latency) {}

  @override
  void recordDbWriteQueueDepth(int depth) {}

  @override
  void recordMirrorHealthAccess({required bool isHit}) {}

  @override
  void recordTelemetryAlert(String alertName,
      {String? taskId, String? details}) {}

  @override
  void resetTelemetryMetrics() {}

  @override
  Map<String, dynamic> telemetryMetricsSnapshot() => const {};
}

void main() {
  group('DiagnosticEntry', () {
    test('formatted with family and details', () {
      final entry = DiagnosticEntry(
        timestamp: DateTime(2025, 1, 2, 3, 4, 5),
        area: 'Engine',
        message: 'boom',
        family: ErrorFamily.network,
        details: 'extra',
      );
      expect(entry.formatted, '03:04:05 Engine: [network] boom — extra');
    });

    test('formatted without family and empty details', () {
      final entry = DiagnosticEntry(
        timestamp: DateTime(2025, 1, 2, 3, 4, 5),
        area: 'UI',
        message: 'ok',
        details: '',
      );
      expect(entry.formatted, '03:04:05 UI: ok');

      final noDetails = DiagnosticEntry(
        timestamp: DateTime(2025, 1, 2, 0, 0, 9),
        area: 'UI',
        message: 'ok',
      );
      expect(noDetails.formatted, '00:00:09 UI: ok');
    });
  });

  group('DiagnosticRepository contract', () {
    test('can be implemented and exercised', () async {
      final repo = _FakeDiagnosticRepository();
      repo.record('a', 'b');
      repo.clear();
      expect(repo.snapshot(), '');
      expect(await repo.systemInfo(), isEmpty);
      repo.recordIsolatePayloadSize(1);
      repo.recordProgressLatency(Duration.zero);
      repo.recordDbWriteQueueDepth(1);
      repo.recordMirrorHealthAccess(isHit: true);
      repo.recordTelemetryAlert('x', taskId: 't', details: 'd');
      repo.resetTelemetryMetrics();
      expect(repo.telemetryMetricsSnapshot(), isEmpty);
      expect(repo.entries, isEmpty);
      expect(repo.isolateBytesTransferred, 0);
      expect(repo.isolateMessageCount, 0);
      expect(repo.currentDbWriteQueueDepth, 0);
      expect(repo.maxDbWriteQueueDepth, 0);
      expect(repo.mirrorHealthHits, 0);
      expect(repo.mirrorHealthMisses, 0);
      expect(repo.mirrorHealthCacheHitRate, 0);
      expect(repo.p95ProgressLatencyMs, 0);
      expect(repo.resumeRangeIgnoredCount, 0);
      expect(repo.journalReconciledCount, 0);
      expect(repo.resumeDataMissingCount, 0);
      expect(repo.watchdogSkipPausedCount, 0);
    });
  });
}
