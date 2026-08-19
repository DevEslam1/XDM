import 'dart:async';
import 'package:flutter/foundation.dart';
import 'download_engine.dart';
import 'logging_service.dart';
import 'power_monitor.dart';

/// Single master scheduler consolidating periodic tasks with background-aware interval scaling.
class BackgroundScheduler {
  static final BackgroundScheduler instance = BackgroundScheduler._();
  BackgroundScheduler._();

  static final _log = LoggingService.logger('BackgroundScheduler');

  Timer? _masterTimer;
  final Map<String, _ScheduledTask> _tasks = {};
  bool _isActive = false;

  bool get isActive => _isActive;
  int get taskCount => _tasks.length;

  /// Registers a task with foreground interval and optional background interval.
  void registerTask(
    String id,
    Duration interval,
    VoidCallback callback, {
    Duration? backgroundInterval,
  }) {
    _tasks[id] = _ScheduledTask(
      interval: interval,
      backgroundInterval: backgroundInterval ?? (interval * 5),
      callback: callback,
      lastRun: DateTime.fromMillisecondsSinceEpoch(0),
    );
    _scheduleNextTick();
  }

  /// Unregisters a task and stops the master timer if no tasks remain.
  void unregisterTask(String id) {
    _tasks.remove(id);
    _scheduleNextTick();
  }

  /// Schedules a deferred background synchronization job.
  void scheduleBackgroundSync({Duration delay = const Duration(minutes: 15)}) {
    _log.info('Scheduling background sync in ${delay.inMinutes} minutes');
    Timer(delay, () {
      DownloadEngine.markBackground();
    });
  }

  void _scheduleNextTick() {
    _masterTimer?.cancel();
    if (_tasks.isEmpty) {
      _masterTimer = null;
      _isActive = false;
      return;
    }
    _isActive = true;
    final now = DateTime.now();
    final isBackground =
        DownloadEngine.isInBackground || PowerMonitor.screenOff;

    Duration minDelay = const Duration(seconds: 60);

    for (final task in _tasks.values) {
      final effectiveInterval =
          isBackground ? task.backgroundInterval : task.interval;
      final elapsed = now.difference(task.lastRun);
      final remaining = effectiveInterval - elapsed;
      if (remaining <= Duration.zero) {
        minDelay = const Duration(seconds: 1);
        break;
      }
      if (remaining < minDelay) {
        minDelay = remaining;
      }
    }

    final delaySeconds = minDelay.inSeconds.clamp(1, 60);
    _masterTimer = Timer(Duration(seconds: delaySeconds), () => _tick());
  }

  /// Stops the master tick timer.
  void stopTimer() {
    _masterTimer?.cancel();
    _masterTimer = null;
    _isActive = false;
  }

  void _tick() {
    if (_tasks.isEmpty) {
      stopTimer();
      return;
    }

    final now = DateTime.now();
    final isBackground = DownloadEngine.isInBackground || PowerMonitor.screenOff;

    final entries = List<MapEntry<String, _ScheduledTask>>.from(_tasks.entries);
    for (final entry in entries) {
      final task = entry.value;
      final effectiveInterval =
          isBackground ? task.backgroundInterval : task.interval;

      if (now.difference(task.lastRun) >= effectiveInterval) {
        task.lastRun = now;
        try {
          task.callback();
        } catch (e, st) {
          _log.warning('Task [${entry.key}] execution failed', e, st);
        }
      }
    }

    _scheduleNextTick();
  }

  /// Cleans up and clears all scheduled tasks.
  void dispose() {
    stopTimer();
    _tasks.clear();
  }
}

class _ScheduledTask {
  final Duration interval;
  final Duration backgroundInterval;
  final VoidCallback callback;
  DateTime lastRun;

  _ScheduledTask({
    required this.interval,
    required this.backgroundInterval,
    required this.callback,
    required this.lastRun,
  });
}
