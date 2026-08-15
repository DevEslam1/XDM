import 'dart:async';
import 'package:flutter/foundation.dart';
import 'download_engine.dart';
import 'power_monitor.dart';

/// Centralized manager for timers that should be throttled or paused
/// when the app is in background or the screen is off.
class BackgroundTimerManager {
  BackgroundTimerManager._() {
    _initListeners();
  }
  static final instance = BackgroundTimerManager._();

  final Map<String, Timer> _timers = {};
  final Map<String, Duration> _baseIntervals = {};
  final Map<String, void Function()> _callbacks = {};

  VoidCallback? _throttleListener;
  VoidCallback? _foregroundListener;
  StreamSubscription<bool>? _screenSub;

  void _initListeners() {
    _throttleListener = _onStateChanged;
    _foregroundListener = _onStateChanged;
    PowerMonitor.throttleFactorNotifier.addListener(_throttleListener!);
    DownloadEngine.appInForegroundNotifier.addListener(_foregroundListener!);
    _screenSub = PowerMonitor.screenStateStream.listen((_) => _onStateChanged());
  }

  void _onStateChanged() {
    _readaptAllTimers();
  }

  void _readaptAllTimers() {
    final ids = List<String>.from(_baseIntervals.keys);
    for (final id in ids) {
      final base = _baseIntervals[id];
      final cb = _callbacks[id];
      if (base != null && cb != null) {
        _timers[id]?.cancel();
        final effective = _adaptInterval(base);
        _timers[id] = Timer.periodic(effective, (_) {
          if (DownloadEngine.appInForeground || !PowerMonitor.screenOff) {
            _callbacks[id]?.call();
          }
        });
      }
    }
  }

  /// Registers a periodic timer with adaptive intervals.
  Timer? register({
    required String id,
    required Duration baseInterval,
    required void Function() callback,
  }) {
    cancel(id);
    _baseIntervals[id] = baseInterval;
    _callbacks[id] = callback;
    final effective = _adaptInterval(baseInterval);
    _timers[id] = Timer.periodic(effective, (_) {
      if (DownloadEngine.appInForeground || !PowerMonitor.screenOff) {
        _callbacks[id]?.call();
      }
    });
    return _timers[id];
  }

  /// Cancels a specific timer.
  void cancel(String id) {
    _timers[id]?.cancel();
    _timers.remove(id);
    _baseIntervals.remove(id);
    _callbacks.remove(id);
  }

  /// Cancels all managed timers.
  void cancelAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _baseIntervals.clear();
    _callbacks.clear();
  }

  @visibleForTesting
  Duration adaptIntervalForTesting(Duration base) => _adaptInterval(base);

  @visibleForTesting
  Duration? getEffectiveInterval(String id) {
    final base = _baseIntervals[id];
    return base == null ? null : _adaptInterval(base);
  }

  Duration _adaptInterval(Duration base) {
    if (PowerMonitor.screenOff) return base * 20;
    if (DownloadEngine.isInBackground) return base * 5;
    if (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive) {
      return base * 8;
    }
    if (PowerMonitor.batterySaverMode == BatterySaverMode.moderate) {
      return base * 3;
    }
    return base;
  }

  void dispose() {
    cancelAll();
    if (_throttleListener != null) {
      PowerMonitor.throttleFactorNotifier.removeListener(_throttleListener!);
      _throttleListener = null;
    }
    if (_foregroundListener != null) {
      DownloadEngine.appInForegroundNotifier.removeListener(_foregroundListener!);
      _foregroundListener = null;
    }
    _screenSub?.cancel();
    _screenSub = null;
  }
}
