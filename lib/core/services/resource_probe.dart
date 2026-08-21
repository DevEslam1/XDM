import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import '../domain/repositories/diagnostic_repository.dart';
import 'logging_service.dart';

/// Single point-in-time sample captured by [ResourceProbe].
class ResourceProbeSample {
  final DateTime timestamp;
  final int rssBytes;
  final int isolateBytesTransferred;
  final double p95ProgressLatencyMs;
  final int dbWriteQueueDepth;
  final int widgetBridgePushes;

  const ResourceProbeSample({
    required this.timestamp,
    required this.rssBytes,
    required this.isolateBytesTransferred,
    required this.p95ProgressLatencyMs,
    required this.dbWriteQueueDepth,
    required this.widgetBridgePushes,
  });

  String toCsvRow() {
    return '${timestamp.toIso8601String()},$rssBytes,$isolateBytesTransferred,${p95ProgressLatencyMs.toStringAsFixed(2)},$dbWriteQueueDepth,$widgetBridgePushes';
  }

  static String csvHeader() {
    return 'timestamp,rss_bytes,isolate_bytes_transferred,p95_progress_latency_ms,db_write_queue_depth,widget_bridge_pushes';
  }
}

/// Debug-only diagnostic probe sampling system resource metrics every 5 seconds.
///
/// Samples are retained in an in-memory ring buffer (up to 720 entries = 1 hour)
/// and can be exported as a CSV report for benchmark/soak analysis.
class ResourceProbe {
  ResourceProbe._();

  static final ResourceProbe instance = ResourceProbe._();

  static const int maxCapacity = 720; // 1 hour at 5s intervals
  static const Duration defaultSamplingInterval = Duration(seconds: 5);

  final ListQueue<ResourceProbeSample> _samples = ListQueue(maxCapacity);
  Timer? _timer;
  int _widgetPushCount = 0;
  bool _isRunning = false;

  bool get isRunning => _isRunning;
  int get sampleCount => _samples.length;

  /// Records a widget bridge push event for rate telemetry.
  void recordWidgetPush() {
    if (!kDebugMode && !kProfileMode) return;
    _widgetPushCount++;
  }

  /// Starts the 5-second sampling loop (guarded by debug/profile mode).
  void start({Duration interval = defaultSamplingInterval}) {
    if (!kDebugMode && !kProfileMode) return;
    if (_isRunning) return;
    _isRunning = true;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => sampleNow());
    LoggingService.logger('ResourceProbe').info('ResourceProbe started (interval: ${interval.inSeconds}s)');
  }

  /// Halts the sampling loop.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _isRunning = false;
    LoggingService.logger('ResourceProbe').info('ResourceProbe stopped');
  }

  /// Clears stored samples and metrics.
  void clear() {
    _samples.clear();
    _widgetPushCount = 0;
  }

  /// Takes an immediate sample and appends it to the circular buffer.
  ResourceProbeSample sampleNow() {
    var currentRss = 0;
    try {
      currentRss = ProcessInfo.currentRss;
    } catch (_) {
      currentRss = 0;
    }

    var isolateBytes = 0;
    var p95Latency = 0.0;
    var dbQueueDepth = 0;

    if (GetIt.instance.isRegistered<DiagnosticRepository>()) {
      try {
        final diag = GetIt.instance<DiagnosticRepository>();
        isolateBytes = diag.isolateBytesTransferred;
        p95Latency = diag.p95ProgressLatencyMs;
        dbQueueDepth = diag.currentDbWriteQueueDepth;
      } catch (_) {}
    }

    final sample = ResourceProbeSample(
      timestamp: DateTime.now(),
      rssBytes: currentRss,
      isolateBytesTransferred: isolateBytes,
      p95ProgressLatencyMs: p95Latency,
      dbWriteQueueDepth: dbQueueDepth,
      widgetBridgePushes: _widgetPushCount,
    );

    if (_samples.length >= maxCapacity) {
      _samples.removeFirst();
    }
    _samples.add(sample);

    return sample;
  }

  /// Exports all ring-buffer samples as standard CSV text.
  String exportCsv() {
    final buffer = StringBuffer();
    buffer.writeln(ResourceProbeSample.csvHeader());
    for (final sample in _samples) {
      buffer.writeln(sample.toCsvRow());
    }
    return buffer.toString();
  }

  /// 60-Minute Soak Scenario Definition Protocol:
  /// - Minute 0-10: 3 concurrent HTTP transfers (1 large multi-thread, 1 small, 1 retrying) + 1 torrent in foreground.
  /// - Minute 10-30: App backgrounded (screen active).
  /// - Minute 30-60: Screen off / low power state.
  /// Acceptance criteria:
  /// - Background CPU average < 5%
  /// - Timer wakeups <= 1/sec
  /// - Journal writes < 2MB/min aggregate
  /// - Memory RSS stable within +/-20MB over 60 mins.
  static const String soakScenarioProtocol = '''
60-Minute Soak Benchmark Protocol:
1. Minute 00-10: Active foreground downloads (3 HTTP + 1 Torrent).
2. Minute 10-30: App lifecycle transitioning to background (screen ON).
3. Minute 30-60: Screen OFF state.
Acceptance Thresholds:
- Background CPU avg < 5%
- Idle wakeups <= 1/sec
- Aggregated journal write < 2MB/min
- RSS delta <= 20MB over 60 mins
''';
}
