// FIX-H9: FrameWatchdog — Screen-off lifecycle
import 'dart:ui';
import 'package:flutter/scheduler.dart';
import 'package:logging/logging.dart';
import 'performance_monitor.dart';
import 'power_monitor.dart';

class PerformanceBudget {
  static const double maxJankRatio = 0.05;
  static double get maxBuildTimeMs => FrameWatchdog.frameBudgetMs;
  static double get maxRasterTimeMs => FrameWatchdog.frameBudgetMs;
}

class FrameWatchdog {
  static final _log = Logger('FrameWatchdog');

  static int _dropped = 0;
  static int _total = 0;
  static DateTime _windowStart = DateTime.now();
  static const _window = Duration(seconds: 30);
  static double _refreshRate = 60.0;

  static double get frameBudgetMs => 1000.0 / _refreshRate;
  static double get _budgetMs => frameBudgetMs;
  static const _alertThreshold = PerformanceBudget.maxJankRatio;
  static bool _isRunning = false;
  static void Function(double jankRatio)? onJankDetected;

  static Future<void> detectRefreshRate() async {
    try {
      final display = await getDisplayRefreshRate();
      if (display > 0) {
        _refreshRate = display;
        _log.info('[FrameWatchdog] Detected refresh rate: ${display}Hz '
            '(frame budget: ${frameBudgetMs.toStringAsFixed(2)}ms)');
      }
    } catch (e) {
      // FIX: Always fall back to 60Hz if detection fails
      _refreshRate = 60.0;
      _log.fine(
          '[FrameWatchdog] Refresh rate detection failed, using 60Hz: $e');
    }
  }

  static Future<double> getDisplayRefreshRate() async {
    try {
      final displays = PlatformDispatcher.instance.displays;
      if (displays.isNotEmpty) {
        final rate = displays.first.refreshRate;
        if (rate > 0) return rate;
      }
    } catch (e, st) {
      // FIX-S6: Log caught exceptions
      _log.fine('[FrameWatchdog] getDisplayRefreshRate error: $e', st);
    }
    // FIX: Safe fallback
    return 60.0;
  }

  static void start() {
    // FIX-H9: Guard start() with screen-off check
    if (_isRunning || PowerMonitor.screenOff) return;
    _isRunning = true;
    _windowStart = DateTime.now();
    _dropped = 0;
    _total = 0;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  // FIX-H9: Pause when backgrounded/screen-off
  static void pause() {
    if (!_isRunning) return;
    _isRunning = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  // FIX-H9: Resume when active and screen is on
  static void resume() {
    if (_isRunning || PowerMonitor.screenOff) return;
    start();
  }

  static void _onTimings(List<FrameTiming> timings) {
    if (PowerMonitor.screenOff) return;
    if (PerformanceMonitor.instance.isListening) {
      PerformanceMonitor.instance.ingestFrameTimings(timings);
    }
    for (final t in timings) {
      _total++;
      if (t.totalSpan.inMilliseconds > _budgetMs) _dropped++;
    }

    final elapsed = DateTime.now().difference(_windowStart);
    if (elapsed >= _window) {
      if (_total > 0) {
        final throttled = PowerMonitor.throttleFactor < 0.5;
        if (!throttled) {
          final rate = _dropped / _total;
          if (rate > _alertThreshold) {
            _log.warning(
              '[Jank] ${(rate * 100).toStringAsFixed(1)}% frames dropped '
              '($_dropped/$_total) in ${elapsed.inSeconds}s',
            );
            onJankDetected?.call(rate);
          }
        }
      }
      _dropped = 0;
      _total = 0;
      _windowStart = DateTime.now();
    }
  }

  static void simulateWindowForTesting(int dropped, int total) {
    _dropped = dropped;
    _total = total;
    if (total > 0) {
      final rate = dropped / total;
      if (rate > _alertThreshold) {
        onJankDetected?.call(rate);
      }
    }
    _dropped = 0;
    _total = 0;
    _windowStart = DateTime.now();
  }

  static void stop() {
    if (!_isRunning) return;
    _isRunning = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }
}
