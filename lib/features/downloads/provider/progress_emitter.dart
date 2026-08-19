// FIX-P1-01: Extracted progress and speed notifier management from DownloadProvider
import 'package:flutter/foundation.dart';
import '../../../core/services/download_engine.dart';
import '../../../core/services/power_monitor.dart';

/// Manages per-task progress and speed ValueNotifiers with UI throttling and lifecycle awareness.
class ProgressEmitter {
  final Duration throttleDuration;
  ProgressEmitter({this.throttleDuration = const Duration(milliseconds: 250)});

  final Map<String, ValueNotifier<double>> _progressNotifiers = {};
  final Map<String, ValueNotifier<double>> _speedNotifiers = {};
  final Map<String, DateTime> _lastPushAt = {};
  final Map<String, double> _lastKnownProgress = {};
  final Map<String, double> _lastKnownSpeed = {};
  final ValueNotifier<int> progressRevision = ValueNotifier<int>(0);

  ValueNotifier<double> progressNotifier(String taskId) {
    return _progressNotifiers.putIfAbsent(
      taskId,
      () => ValueNotifier<double>(_lastKnownProgress[taskId] ?? 0.0),
    );
  }

  ValueNotifier<double> speedNotifier(String taskId) {
    return _speedNotifiers.putIfAbsent(
      taskId,
      () => ValueNotifier<double>(_lastKnownSpeed[taskId] ?? 0.0),
    );
  }

  void pushTick(String taskId, double progress, double speed) {
    _lastKnownProgress[taskId] = progress;
    _lastKnownSpeed[taskId] = speed;

    // Skip UI updates when app is in background or screen is off
    if (!DownloadEngine.appInForeground || PowerMonitor.screenOff) {
      return;
    }

    final now = DateTime.now();
    final last = _lastPushAt[taskId];
    final isTerminal = progress >= 1.0 || progress <= 0.0;

    // Time-based throttle: at most 1 update per throttleDuration per task unless reaching terminal state
    if (last != null &&
        !isTerminal &&
        throttleDuration > Duration.zero &&
        now.difference(last) < throttleDuration) {
      return;
    }
    _lastPushAt[taskId] = now;

    var changed = false;
    final progressNotif = progressNotifier(taskId);
    final speedNotif = speedNotifier(taskId);

    if ((progressNotif.value - progress).abs() > 0.005 || isTerminal) {
      if (progressNotif.value != progress) {
        progressNotif.value = progress;
        changed = true;
      }
    }

    if ((speedNotif.value - speed).abs() > 1024 || speed == 0.0) {
      if (speedNotif.value != speed) {
        speedNotif.value = speed;
        changed = true;
      }
    }

    // Only increment revision when a value actually changed
    if (changed) {
      progressRevision.value++;
    }
  }

  /// Forces an immediate re-emission of last known states upon app foregrounding.
  void refreshOnResume() {
    if (!DownloadEngine.appInForeground || PowerMonitor.screenOff) return;
    for (final entry in _progressNotifiers.entries) {
      final taskId = entry.key;
      final p = _lastKnownProgress[taskId];
      final s = _lastKnownSpeed[taskId];
      if (p != null) entry.value.value = p;
      if (s != null && _speedNotifiers.containsKey(taskId)) {
        _speedNotifiers[taskId]!.value = s;
      }
    }
    progressRevision.value++;
  }

  void disposeTaskNotifier(String taskId) {
    _progressNotifiers.remove(taskId)?.dispose();
    _speedNotifiers.remove(taskId)?.dispose();
    _lastPushAt.remove(taskId);
    _lastKnownProgress.remove(taskId);
    _lastKnownSpeed.remove(taskId);
  }

  void dispose() {
    for (final notifier in _progressNotifiers.values) {
      notifier.dispose();
    }
    _progressNotifiers.clear();

    for (final notifier in _speedNotifiers.values) {
      notifier.dispose();
    }
    _speedNotifiers.clear();

    _lastPushAt.clear();
    _lastKnownProgress.clear();
    _lastKnownSpeed.clear();
    progressRevision.dispose();
  }
}
