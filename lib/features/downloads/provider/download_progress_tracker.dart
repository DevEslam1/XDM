import 'package:flutter/foundation.dart';

/// Handles real-time progress updates and throttling for UI.
class DownloadProgressTracker {
  final Map<String, ValueNotifier<double>> _progressNotifiers = {};
  final Map<String, ValueNotifier<double>> _speedNotifiers = {};

  ValueNotifier<double> getProgress(String taskId) =>
      _progressNotifiers.putIfAbsent(taskId, () => ValueNotifier(0.0));

  ValueNotifier<double> getSpeed(String taskId) =>
      _speedNotifiers.putIfAbsent(taskId, () => ValueNotifier(0.0));

  void update(String taskId, double progress, double speed) {
    getProgress(taskId).value = progress;
    getSpeed(taskId).value = speed;
  }
}
