import '../../services/diagnostic_service.dart';

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

  void recordIsolatePayloadSize(int bytes);
  void recordProgressLatency(Duration latency);
  void recordDbWriteQueueDepth(int depth);
  void recordMirrorHealthAccess({required bool isHit});
  void resetTelemetryMetrics();
  Map<String, dynamic> telemetryMetricsSnapshot();
}
