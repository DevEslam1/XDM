import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:logging/logging.dart';
import 'download_engine.dart';
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
  static const normalWindow = Duration(seconds: 30);
  static const heavyWindow = Duration(seconds: 60);
  static double _refreshRate = 60.0;
  static double get refreshRate => _refreshRate;

  static double get frameBudgetMs => 1000.0 / _refreshRate;
  static double get _budgetMs => frameBudgetMs;
  static const _alertThreshold = PerformanceBudget.maxJankRatio;
  static bool _isRunning = false;
  static void Function(double jankRatio)? onJankDetected;
  static double? _cachedRefreshRate;
  static bool _metricsListenerRegistered = false;

  @visibleForTesting
  static bool enableInReleaseForTesting = false;

  static Future<void> detectRefreshRate({bool force = false}) async {
    if (_cachedRefreshRate != null && !force) {
      return;
    }
    if (!_metricsListenerRegistered) {
      _metricsListenerRegistered = true;
      // Task 3.5: Chain onto any existing handler rather than overwriting it.
      final previousHandler = PlatformDispatcher.instance.onMetricsChanged;
      PlatformDispatcher.instance.onMetricsChanged = () {
        previousHandler?.call();
        detectRefreshRate(force: false);
      };
    }
    try {
      final display = await getDisplayRefreshRate();
      if (display > 0) {
        final rateChanged =
            (_refreshRate - display).abs() > 0.05 || _cachedRefreshRate == null;
        _refreshRate = display;
        _cachedRefreshRate = display;
        if (rateChanged) {
          _log.info('[FrameWatchdog] Detected refresh rate: ${display}Hz '
              '(frame budget: ${frameBudgetMs.toStringAsFixed(2)}ms)');
        }
      }
    } catch (e) {
      // Always fall back to 60Hz if detection fails
      _refreshRate = 60.0;
      _cachedRefreshRate = 60.0;
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
      _log.fine('[FrameWatchdog] getDisplayRefreshRate error: $e', st);
    }
    return 60.0;
  }

  static void start() {
    // Plan 07 §7.1: frame monitoring runs in release too (low overhead — only
    // per-frame integer counters; the verbose jank logs below are debug-level).
    // This is what makes release-mode jank auto-degrade work. The screen-off /
    // background guards below still keep it idle when there is nothing to watch.
    if (_isRunning ||
        PowerMonitor.screenOff ||
        !DownloadEngine.appInForeground ||
        DownloadEngine.isInBackground) {
      return;
    }
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
    if (_isRunning ||
        PowerMonitor.screenOff ||
        !DownloadEngine.appInForeground ||
        DownloadEngine.isInBackground) {
      return;
    }
    start();
  }

  static int downloadingTasksCount = 0;
  static bool alwaysObserveHeavyDownloads = false;
  static DateTime? _lastHeavyWarning;

  static void setDownloadingTasksCount(int count) {
    downloadingTasksCount = count;
  }

  static void _onTimings(List<FrameTiming> timings) {
    if (PowerMonitor.screenOff ||
        !DownloadEngine.appInForeground ||
        DownloadEngine.isInBackground) {
      return;
    }

    final isHeavyDownloads = downloadingTasksCount > 2;
    final currentWindow = isHeavyDownloads ? heavyWindow : normalWindow;
    final currentThreshold = isHeavyDownloads ? 0.15 : _alertThreshold;

    if (PerformanceMonitor.instance.isActive) {
      PerformanceMonitor.instance.ingestFrameTimings(timings);
    }
    for (final t in timings) {
      _total++;
      if (t.totalSpan.inMilliseconds > _budgetMs) _dropped++;
    }

    final elapsed = DateTime.now().difference(_windowStart);
    if (elapsed >= currentWindow) {
      if (_total > 0) {
        final throttled = PowerMonitor.throttleFactor < 0.5;
        if (!throttled) {
          final rate = _dropped / _total;
          if (rate > currentThreshold) {
            final now = DateTime.now();
            if (isHeavyDownloads) {
              if (_lastHeavyWarning == null ||
                  now.difference(_lastHeavyWarning!) >=
                      const Duration(minutes: 1)) {
                _lastHeavyWarning = now;
                _log.warning(
                  '[Jank] ${(rate * 100).toStringAsFixed(1)}% frames dropped '
                  '($_dropped/$_total) in ${elapsed.inSeconds}s (during heavy downloads)',
                );
                onJankDetected?.call(rate);
              }
            } else {
              _log.warning(
                '[Jank] ${(rate * 100).toStringAsFixed(1)}% frames dropped '
                '($_dropped/$_total) in ${elapsed.inSeconds}s',
              );
              onJankDetected?.call(rate);
            }
          }
        }
      }
      _dropped = 0;
      _total = 0;
      _windowStart = DateTime.now();
    }
  }

  static void simulateWindowForTesting(
    int dropped,
    int total, {
    bool isHeavy = false,
  }) {
    _dropped = dropped;
    _total = total;
    if (total > 0) {
      final rate = dropped / total;
      final threshold =
          (isHeavy && !alwaysObserveHeavyDownloads) ? 0.15 : _alertThreshold;
      if (rate > threshold) {
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
