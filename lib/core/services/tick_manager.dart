import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'download_engine.dart';
import 'power_monitor.dart';

enum TickPriority {
  /// Always runs (e.g. critical state flush, shutdown handlers).
  critical,

  /// Runs when screen is on OR there are active downloads.
  normal,

  /// Runs only when the screen is ON and the app is in foreground.
  ambient,
}

typedef TickCallback = void Function(DateTime timestamp);

class _TickSubscriber {
  final String id;
  final Duration interval;
  final TickPriority priority;
  final TickCallback callback;
  DateTime lastRun;

  _TickSubscriber({
    required this.id,
    required this.interval,
    required this.priority,
    required this.callback,
  }) : lastRun = DateTime.fromMillisecondsSinceEpoch(0);
}

/// Global centralized timer manager that consolidates periodic timers across
/// the app to reduce CPU context switches and conserve battery.
class TickManager {
  static final _log = Logger('TickManager');
  static final TickManager instance = TickManager._();
  TickManager._() {
    _startHeartbeat();
    PowerMonitor.screenStateStream.listen((screenOn) {
      _onPowerStateChanged();
    });
  }

  final Map<String, _TickSubscriber> _subscribers = {};
  Timer? _heartbeatTimer;
  static const Duration _baseTickResolution = Duration(milliseconds: 500);

  bool _isPaused = false;

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_baseTickResolution, _onHeartbeat);
  }

  void registerTick({
    required String id,
    required Duration interval,
    required TickPriority priority,
    required TickCallback callback,
  }) {
    _subscribers[id] = _TickSubscriber(
      id: id,
      interval: interval,
      priority: priority,
      callback: callback,
    );
  }

  void unregisterTick(String id) {
    _subscribers.remove(id);
  }

  void _onPowerStateChanged() {
    // Force evaluate ticks on wake
    _onHeartbeat(_heartbeatTimer!);
  }

  void _onHeartbeat(Timer timer) {
    if (_isPaused) return;

    final now = DateTime.now();
    final screenOff = PowerMonitor.screenOff;
    final hasActive = DownloadEngine.hasActiveDownloads;
    final isForeground = DownloadEngine.appInForeground;

    for (final sub in _subscribers.values) {
      // Check priority eligibility
      switch (sub.priority) {
        case TickPriority.critical:
          break; // Always eligible
        case TickPriority.normal:
          if (screenOff && !hasActive) {
            continue; // Skip normal ticks when screen is off and no active downloads
          }
          break;
        case TickPriority.ambient:
          if (screenOff || !isForeground || !hasActive && DownloadEngine.activeDownloadsCount > 0) {
            continue; // Skip ambient UI updates
          }
          break;
      }

      if (now.difference(sub.lastRun) >= sub.interval) {
        sub.lastRun = now;
        try {
          sub.callback(now);
        } catch (e, st) {
          _log.warning('Tick callback error for ${sub.id}', e, st);
        }
      }
    }
  }

  @visibleForTesting
  void pause() {
    _isPaused = true;
  }

  @visibleForTesting
  void resume() {
    _isPaused = false;
  }

  void dispose() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _subscribers.clear();
  }
}
