// FIX-H10: PerformanceMonitor — Screen-off lifecycle
import 'package:flutter/scheduler.dart';
import 'download_engine.dart';
import 'frame_watchdog.dart';
import 'power_monitor.dart';

/// Collects lightweight UI-frame statistics (build/raster durations, jank
/// ratio) via [SchedulerBinding.addTimingsCallback]. Used for the performance
/// dashboard and regression checks; keeps only a bounded sample window.
class PerformanceMonitor {
  PerformanceMonitor();

  static final PerformanceMonitor instance = PerformanceMonitor();

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
  bool get isActive => _listening && !PowerMonitor.screenOff && DownloadEngine.appInForeground;

  int get totalFrames => _totalFrames;
  int get jankyFrameCount => _jankyFrames;
  int get sampleCount => _buildSamples.length;

  double get jankRatio => _totalFrames == 0 ? 0.0 : _jankyFrames / _totalFrames;

  double get currentFps {
    final buildMs = averageBuildMillis ?? 0.0;
    final rasterMs = averageRasterMillis ?? 0.0;
    final totalMs = buildMs + rasterMs;
    if (totalMs <= 0) return 60.0;
    return (1000.0 / totalMs).clamp(0.0, 120.0);
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

  /// One-line diagnostic health summary string, e.g. "60fps | 2.3% jank | 8.2ms avg build".
  String get healthSummary {
    final jankPct = (jankRatio * 100).toStringAsFixed(1);
    final avgBuild = (averageBuildMillis ?? 0.0).toStringAsFixed(1);
    return '60fps | $jankPct% jank | ${avgBuild}ms avg build';
  }

  /// Starts collecting frame timings. Idempotent.
  void start() {
    if (_listening) return;
    _listening = true;
    FrameWatchdog.start();
  }

  /// Stops collecting frame timings.
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

      if (build > jankThreshold) _jankyFrames++;
      _buildSamples.add(build);
      _rasterSamples.add(raster);
    }
    if (_totalFrames >= 60 && jankRatio > 0.05) {
      sustainedJankDetected = true;
      onSustainedJank?.call(true);
    }
    _trim();
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
    _onTimings(timings);
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
