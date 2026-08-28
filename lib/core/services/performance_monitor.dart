import 'dart:async';
import 'dart:io' show ProcessInfo;
import 'package:flutter/scheduler.dart';
import 'download_engine.dart';
import 'frame_watchdog.dart';
import 'power_monitor.dart';

class FrameMetrics {
  final double fps;
  final double jankRatio;
  final double averageBuildMillis;
  final double averageRasterMillis;

  const FrameMetrics({
    required this.fps,
    required this.jankRatio,
    required this.averageBuildMillis,
    required this.averageRasterMillis,
  });
}

/// Collects lightweight UI-frame statistics (build/raster durations, jank
/// ratio) via [SchedulerBinding.addTimingsCallback]. Used for the performance
/// dashboard and regression checks; keeps only a bounded sample window.
class PerformanceMonitor {
  PerformanceMonitor();

  static final PerformanceMonitor instance = PerformanceMonitor();

  final StreamController<FrameMetrics> _metricsController =
      StreamController<FrameMetrics>.broadcast();

  Stream<FrameMetrics> get metricsStream => _metricsController.stream;

  static void Function()? onAutoDegradeTriggered;

  int _consecutiveJankCount = 0;
  DateTime? _lastAutoDegradeTime;

  /// True when high frame jank or aggressive power saving requires reduced animations.
  static bool get shouldReduceMotion =>
      PowerMonitor.batterySaverMode == BatterySaverMode.aggressive ||
      PowerMonitor.throttleFactor < 0.7 ||
      (instance._totalFrames > 10 && instance.jankRatio > 0.15);

  /// A build/raster time above this counts as a janky frame.
  static Duration get jankThreshold =>
      Duration(microseconds: (FrameWatchdog.frameBudgetMs * 1000).round());

  /// Bounded sample window (4 seconds @ 60fps).
  static const int maxSamples = 240;

  final List<Duration> _buildSamples = [];
  final List<Duration> _rasterSamples = [];
  int _totalFrames = 0;
  int _jankyFrames = 0;
  bool _listening = true;

  bool get isListening => _listening;
  bool get isActive =>
      _listening && !PowerMonitor.screenOff && DownloadEngine.appInForeground;

  int get totalFrames => _totalFrames;
  int get jankyFrameCount => _jankyFrames;
  int get sampleCount => _buildSamples.length;

  double get jankRatio => _totalFrames == 0 ? 0.0 : _jankyFrames / _totalFrames;

  double get currentFps {
    final buildMs = averageBuildMillis ?? 0.0;
    final rasterMs = averageRasterMillis ?? 0.0;
    final totalMs = buildMs + rasterMs;
    // FIX(M-20): Return 0 instead of fabricated 60fps when no data available.
    if (totalMs <= 0) return 0.0;
    return (1000.0 / totalMs).clamp(0.0, 144.0);
  }

  /// Average build duration over the sample window (ms), or null when empty.
  double? get averageBuildMillis {
    if (_buildSamples.isEmpty) return null;
    final sum = _buildSamples.fold<int>(
      0,
      (acc, d) => acc + d.inMicroseconds,
    );
    return (sum / _buildSamples.length) / 1000.0;
  }

  /// Average raster duration over the sample window (ms), or null when empty.
  double? get averageRasterMillis {
    if (_rasterSamples.isEmpty) return null;
    final sum = _rasterSamples.fold<int>(
      0,
      (acc, d) => acc + d.inMicroseconds,
    );
    return (sum / _rasterSamples.length) / 1000.0;
  }

  /// One-line diagnostic health summary string.
  String get healthSummary {
    final jankPct = (jankRatio * 100).toStringAsFixed(1);
    final avgBuild = (averageBuildMillis ?? 0.0).toStringAsFixed(1);
    final fps = currentFps.toStringAsFixed(0);
    return '$fps fps | $jankPct% jank | ${avgBuild}ms avg build';
  }

  /// Current process resident set size (bytes), or null when the platform can't
  /// provide it (e.g. web). Read on demand — cheap, no background polling.
  /// Consumed by the live monitor on its adaptive 2s/4s cadence. (Plan 07 §7.5)
  int? get currentRssBytes {
    try {
      final rss = ProcessInfo.currentRss;
      return rss > 0 ? rss : null;
    } catch (_) {
      return null;
    }
  }

  /// Peak process RSS (bytes) since launch, or null when unavailable.
  int? get maxRssBytes {
    try {
      final rss = ProcessInfo.maxRss;
      return rss > 0 ? rss : null;
    } catch (_) {
      return null;
    }
  }

  /// Starts collecting frame timings. Must be called on the main UI isolate. Idempotent.
  void start() {
    if (_listening) return;
    _listening = true;
    FrameWatchdog.start();
  }

  /// Stops collecting frame timings. Must be called on the main UI isolate.
  void stop() {
    _listening = false;
  }

  // FIX-H10: Pause & resume lifecycle methods
  void pause() {
    _listening = false;
  }

  void resume() {
    if (PowerMonitor.screenOff || !DownloadEngine.appInForeground) return;
    _listening = true;
  }

  static bool sustainedJankDetected = false;
  static void Function(bool)? onSustainedJank;

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _totalFrames++;
      final build = timing.buildDuration;
      final raster = timing.rasterDuration;

      if (build > jankThreshold) {
        _jankyFrames++;
        _consecutiveJankCount++;
        if (_consecutiveJankCount >= 5) {
          final now = DateTime.now();
          if (_lastAutoDegradeTime == null ||
              now.difference(_lastAutoDegradeTime!) >=
                  const Duration(seconds: 30)) {
            _lastAutoDegradeTime = now;
            onAutoDegradeTriggered?.call();
          }
        }
      } else {
        _consecutiveJankCount = 0;
      }
      _buildSamples.add(build);
      _rasterSamples.add(raster);
    }
    if (_totalFrames >= 60 && jankRatio > 0.05) {
      sustainedJankDetected = true;
      onSustainedJank?.call(true);
    }
    _trim();
    if (_metricsController.hasListener) {
      _metricsController.add(FrameMetrics(
        fps: currentFps,
        jankRatio: jankRatio,
        averageBuildMillis: averageBuildMillis ?? 0.0,
        averageRasterMillis: averageRasterMillis ?? 0.0,
      ));
    }
  }

  /// Feeds timings from [FrameWatchdog] or test suites.
  // FIX-H10: Guard ingestFrameTimings with _listening and screenOff
  void ingestFrameTimings(List<FrameTiming> timings) {
    if (!_listening ||
        PowerMonitor.screenOff ||
        !DownloadEngine.appInForeground ||
        DownloadEngine.isInBackground ||
        PowerMonitor.batterySaverMode == BatterySaverMode.aggressive) {
      return;
    }
    final validTimings = timings
        .where((t) =>
            t.buildDuration > Duration.zero || t.rasterDuration > Duration.zero)
        .toList();
    if (validTimings.isEmpty) return;
    _onTimings(validTimings);
  }

  void _trim() {
    if (_buildSamples.length > maxSamples) {
      _buildSamples.removeRange(0, _buildSamples.length - maxSamples);
    }
    if (_rasterSamples.length > maxSamples) {
      _rasterSamples.removeRange(0, _rasterSamples.length - maxSamples);
    }
  }

  void reset() {
    _buildSamples.clear();
    _rasterSamples.clear();
    _totalFrames = 0;
    _jankyFrames = 0;
  }
}
