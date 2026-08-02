import 'package:flutter/scheduler.dart';
import 'package:logging/logging.dart';

/// Silent jank monitor. Logs when >5% of frames miss the 16ms budget.
class FrameWatchdog {
  static final _log = Logger('FrameWatchdog');
  static int _dropped = 0;
  static int _total = 0;
  static DateTime _windowStart = DateTime.now();
  static const _window = Duration(seconds: 30);
  static const _budgetMs = 16;
  static const _alertThreshold = 0.05;
  static bool _isRunning = false;

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
        final rate = _dropped / _total;
        if (rate > _alertThreshold) {
          _log.warning(
            '[Jank] ${(rate * 100).toStringAsFixed(1)}% frames dropped '
            '($_dropped/$_total) in ${elapsed.inSeconds}s',
          );
        }
      }
      _dropped = 0;
      _total = 0;
      _windowStart = DateTime.now();
    }
  }

  static void stop() {
    if (!_isRunning) return;
    _isRunning = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }
}
