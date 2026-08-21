import 'dart:async';
import 'package:flutter/foundation.dart';
import 'download_engine.dart';
import 'logging_service.dart';
import 'power_monitor.dart';

/// Classification categories for managed timers across the application.
enum TimerCategory {
  criticalEngine,
  persistence,
  ui,
  widget,
  telemetry,
  updateChecks,
}

/// Centralized manager for timers that should be throttled or paused
/// when the app is in background or the screen is off.
class BackgroundTimerManager {
  BackgroundTimerManager() {
    _initListeners();
  }
  static final instance = BackgroundTimerManager();
  static final _log = LoggingService.logger('BackgroundTimerManager');

  final Map<String, Timer> _timers = {};
  final Map<String, Duration> _baseIntervals = {};
  final Map<String, void Function()> _callbacks = {};
  final Map<String, TimerCategory> _categories = {};

  VoidCallback? _throttleListener;
  VoidCallback? _foregroundListener;
  StreamSubscription<bool>? _screenSub;
  Timer? _debounceTimer;
  Timer? _suppressionTimer;
  bool _listenersSuppressed = false;
  final List<DateTime> _stateChangeTimestamps = [];

  @visibleForTesting
  Timer? get debounceTimerForTesting => _debounceTimer;

  @visibleForTesting
  bool get isSuppressedForTesting => _listenersSuppressed;

  @visibleForTesting
  int get stateChangeHistoryCount => _stateChangeTimestamps.length;

  /// Returns the count of active timers grouped by category for telemetry and observability.
  Map<TimerCategory, int> get activeTimerCountByCategory {
    final counts = <TimerCategory, int>{
      for (final c in TimerCategory.values) c: 0,
    };
    for (final id in _timers.keys) {
      final cat = _categories[id] ?? TimerCategory.persistence;
      counts[cat] = (counts[cat] ?? 0) + 1;
    }
    return counts;
  }

  int get totalActiveTimers => _timers.length;

  void _initListeners() {
    _throttleListener = _onStateChanged;
    _foregroundListener = _onStateChanged;
    PowerMonitor.throttleFactorNotifier.addListener(_throttleListener!);
    DownloadEngine.appInForegroundNotifier.addListener(_foregroundListener!);
    _screenSub =
        PowerMonitor.screenStateStream.listen((_) => _onStateChanged());
  }

  void _onStateChanged() {
    if (_listenersSuppressed) return;

    final now = DateTime.now();
    _stateChangeTimestamps.add(now);
    _stateChangeTimestamps.removeWhere(
      (t) => now.difference(t) > const Duration(seconds: 2),
    );

    if (_stateChangeTimestamps.length > 4) {
      _listenersSuppressed = true;
      _log.warning(
          '[BackgroundTimerManager] High state-change flapping detected: ${_stateChangeTimestamps.length} changes within 2s.');

      _suppressionTimer?.cancel();
      _suppressionTimer = Timer(const Duration(seconds: 2), () {
        _listenersSuppressed = false;
        _readaptAllTimers();
      });
      return;
    }

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _readaptAllTimers();
    });
  }

  void _readaptAllTimers() {
    final ids = List<String>.from(_baseIntervals.keys);
    for (final id in ids) {
      final base = _baseIntervals[id];
      final cb = _callbacks[id];
      final cat = _categories[id] ?? TimerCategory.persistence;
      if (base != null && cb != null) {
        _timers[id]?.cancel();
        // If UI or widget timer and app is backgrounded or screen off, do not schedule active timer
        if ((cat == TimerCategory.ui || cat == TimerCategory.widget) &&
            (DownloadEngine.isInBackground || PowerMonitor.screenOff)) {
          continue;
        }
        final effective = _adaptInterval(base, category: cat);
        _timers[id] = Timer.periodic(effective, (_) {
          // Task 4: Ensure UI and widget timers never fire when backgrounded or screen is off
          if ((cat == TimerCategory.ui || cat == TimerCategory.widget) &&
              (DownloadEngine.isInBackground || PowerMonitor.screenOff)) {
            return;
          }
          _callbacks[id]?.call();
        });
      }
    }
  }

  /// Registers a periodic timer with adaptive intervals and category classification.
  Timer? register({
    required String id,
    required Duration baseInterval,
    required void Function() callback,
    TimerCategory category = TimerCategory.persistence,
  }) {
    cancel(id);
    _baseIntervals[id] = baseInterval;
    _callbacks[id] = callback;
    _categories[id] = category;

    if ((category == TimerCategory.ui || category == TimerCategory.widget) &&
        (DownloadEngine.isInBackground || PowerMonitor.screenOff)) {
      return null;
    }

    final effective = _adaptInterval(baseInterval, category: category);
    _timers[id] = Timer.periodic(effective, (_) {
      if ((category == TimerCategory.ui || category == TimerCategory.widget) &&
          (DownloadEngine.isInBackground || PowerMonitor.screenOff)) {
        return;
      }
      _callbacks[id]?.call();
    });
    return _timers[id];
  }

  /// Pauses all active timers while keeping registrations intact.
  void pauseAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  /// Resumes all paused timers using the current adapted intervals.
  void resumeAll() {
    _readaptAllTimers();
  }

  /// Cancels a specific timer.
  void cancel(String id) {
    _timers[id]?.cancel();
    _timers.remove(id);
    _baseIntervals.remove(id);
    _callbacks.remove(id);
    _categories.remove(id);
  }

  /// Cancels all managed timers.
  void cancelAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _baseIntervals.clear();
    _callbacks.clear();
    _categories.clear();
  }

  @visibleForTesting
  Duration adaptIntervalForTesting(Duration base,
          {TimerCategory category = TimerCategory.persistence}) =>
      _adaptInterval(base, category: category);

  @visibleForTesting
  Duration? getEffectiveInterval(String id) {
    final base = _baseIntervals[id];
    final cat = _categories[id] ?? TimerCategory.persistence;
    return base == null ? null : _adaptInterval(base, category: cat);
  }

  Duration _adaptInterval(Duration base,
      {TimerCategory category = TimerCategory.persistence}) {
    if (category == TimerCategory.criticalEngine) {
      return base;
    }
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
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _suppressionTimer?.cancel();
    _suppressionTimer = null;
    _stateChangeTimestamps.clear();
    if (_throttleListener != null) {
      PowerMonitor.throttleFactorNotifier.removeListener(_throttleListener!);
      _throttleListener = null;
    }
    if (_foregroundListener != null) {
      DownloadEngine.appInForegroundNotifier
          .removeListener(_foregroundListener!);
      _foregroundListener = null;
    }
    _screenSub?.cancel();
    _screenSub = null;
  }
}
