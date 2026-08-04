import 'dart:ui';
import 'package:flutter/scheduler.dart';
import 'package:logging/logging.dart';
import 'power_monitor.dart';

/// Target performance budget constants for UI rendering.
class PerformanceBudget {
  static const double maxJankRatio = 0.05;
  static const double maxBuildTimeMs = 16.6;
  static const double maxRasterTimeMs = 16.6;
}

/// Silent jank monitor. Logs when >5% of frames miss the adaptive frame budget.
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

  /// Callback triggered when jank ratio exceeds the alert threshold.
  static void Function(double jankRatio)? onJankDetected;

  /// Call once at app startup to detect the display refresh rate.
  static Future<void> detectRefreshRate() async {
    try {
      final display = await getDisplayRefreshRate();
      if (display > 0) {
        _refreshRate = display;
        _log.info('[FrameWatchdog] Detected refresh rate: ${display}Hz '
            '(frame budget: ${frameBudgetMs.toStringAsFixed(2)}ms)');
      }
    } catch (e) {
      _refreshRate = 60.0; // Fallback
    }
  }

  static Future<double> getDisplayRefreshRate() async {
    try {
      final displays = PlatformDispatcher.instance.displays;
      if (displays.isNotEmpty) {
        final rate = displays.first.refreshRate;
        if (rate > 0) return rate;
      }
    } catch (_) {}
    return 60.0;
  }

  static void start() {
    if (_isRunning) return;
    _isRunning = true;
    _windowStart = DateTime.now();
    _dropped = 0;
    _total = 0;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _total++;
      if (t.totalSpan.inMilliseconds > _budgetMs) _dropped++;
    }
    final elapsed = DateTime.now().difference(_windowStart);
    if (elapsed >= _window) {
      if (_total > 0) {
        // FIX-L3: Skip jank reporting when aggressive battery saver is active.
        // Under battery saver the frame budget is intentionally relaxed, so
        // jank alerts would be false positives.
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

  /// Test hook to simulate window evaluation with explicit dropped/total frames.
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

