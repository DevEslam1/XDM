import 'dart:async';
import 'download_engine.dart';
import 'power_monitor.dart';

/// Centralized manager for timers that should be throttled or paused
/// when the app is in background or the screen is off.
class BackgroundTimerManager {
  BackgroundTimerManager._();
  static final instance = BackgroundTimerManager._();

  final Map<String, Timer> _timers = {};
  final Map<String, Duration> _baseIntervals = {};

  /// Registers a periodic timer with adaptive intervals.
  Timer? register({
    required String id,
    required Duration baseInterval,
    required void Function() callback,
  }) {
    cancel(id);
    _baseIntervals[id] = baseInterval;
    final effective = _adaptInterval(baseInterval);
    _timers[id] = Timer.periodic(effective, (_) {
      if (DownloadEngine.appInForeground || !PowerMonitor.screenOff) {
        callback();
      }
    });
    return _timers[id];
  }

  /// Cancels a specific timer.
  void cancel(String id) {
    _timers[id]?.cancel();
    _timers.remove(id);
    _baseIntervals.remove(id);
  }

  /// Cancels all managed timers.
  void cancelAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _baseIntervals.clear();
  }

  Duration _adaptInterval(Duration base) {
    if (PowerMonitor.screenOff) return base * 20;
    if (DownloadEngine.isInBackground) return base * 5;
    if (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive) return base * 8;
    if (PowerMonitor.batterySaverMode == BatterySaverMode.moderate) return base * 3;
    return base;
  }
}
