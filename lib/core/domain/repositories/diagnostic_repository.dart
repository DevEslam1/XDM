import '../models/error_family.dart';

/// One recorded diagnostic entry (pure domain value).
class DiagnosticEntry {
  final DateTime timestamp;
  final String area;
  final String message;
  final ErrorFamily? family;
  final String? details;

  const DiagnosticEntry({
    required this.timestamp,
    required this.area,
    required this.message,
    this.family,
    this.details,
  });

  String get formatted {
    final time = '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
    final family = this.family == null ? '' : '[${this.family!.name}] ';
    final details = this.details == null || this.details!.isEmpty
        ? ''
        : ' — ${this.details}';
    return '$time $area: $family$message$details';
  }
}

/// Clean Architecture interface for diagnostic & telemetry operations.
abstract class DiagnosticRepository {
  List<DiagnosticEntry> get entries;
  void record(String area, String message, {Object? error, String? details});
  void clear();
  String snapshot();
  Future<Map<String, String>> systemInfo();

  // Telemetry metrics
  int get isolateBytesTransferred;
  int get isolateMessageCount;
  int get currentDbWriteQueueDepth;
  int get maxDbWriteQueueDepth;
  int get mirrorHealthHits;
  int get mirrorHealthMisses;
  double get mirrorHealthCacheHitRate;
  double get p95ProgressLatencyMs;

  // Phase 8 Telemetry alerts
  int get resumeRangeIgnoredCount;
  int get journalReconciledCount;
  int get resumeDataMissingCount;
  int get watchdogSkipPausedCount;

  void recordIsolatePayloadSize(int bytes);
  void recordProgressLatency(Duration latency);
  void recordDbWriteQueueDepth(int depth);
  void recordMirrorHealthAccess({required bool isHit});
  void recordTelemetryAlert(String alertName, {String? taskId, String? details});
  void resetTelemetryMetrics();
  Map<String, dynamic> telemetryMetricsSnapshot();
}
