// FIX-P1-01: Extracted progress and speed notifier management from DownloadProvider
import 'package:flutter/foundation.dart';
import '../../../core/services/download_engine.dart';
import '../../../core/services/power_monitor.dart';

/// Manages per-task progress and speed ValueNotifiers with UI throttling.
class ProgressEmitter {
  final Map<String, ValueNotifier<double>> _progressNotifiers = {};
  final Map<String, ValueNotifier<double>> _speedNotifiers = {};
  final ValueNotifier<int> progressRevision = ValueNotifier<int>(0);

  ValueNotifier<double> progressNotifier(String taskId) {
    return _progressNotifiers.putIfAbsent(
      taskId,
      () => ValueNotifier<double>(0.0),
    );
  }

  ValueNotifier<double> speedNotifier(String taskId) {
    return _speedNotifiers.putIfAbsent(
      taskId,
      () => ValueNotifier<double>(0.0),
    );
  }

  void pushTick(String taskId, double progress, double speed) {
    // FIX-P0-03: Skip UI updates when app is in background
    if (!DownloadEngine.appInForeground || PowerMonitor.screenOff) {
      return;
    }
    progressRevision.value++;
    final progressNotif = progressNotifier(taskId);
    final speedNotif = speedNotifier(taskId);

    if ((progressNotif.value - progress).abs() > 0.005 ||
        progress >= 1.0 ||
        progress <= 0.0) {
      progressNotif.value = progress;
    }
    if ((speedNotif.value - speed).abs() > 1024 || speed == 0.0) {
      speedNotif.value = speed;
    }
  }

  void disposeTaskNotifier(String taskId) {
    _progressNotifiers.remove(taskId)?.dispose();
    _speedNotifiers.remove(taskId)?.dispose();
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

    progressRevision.dispose();
  }
}
