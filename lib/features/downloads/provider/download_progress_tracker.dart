import 'package:flutter/foundation.dart';
import '../../../core/services/engine/engine_models.dart';

/// Handles real-time progress updates and deduplication for UI.
class DownloadProgressTracker extends ChangeNotifier {
  final Map<String, DownloadProgress> _progressMap = {};
  final Map<String, ValueNotifier<double>> _progressNotifiers = {};
  final Map<String, ValueNotifier<double>> _speedNotifiers = {};

  DownloadProgress? getProgressData(String taskId) => _progressMap[taskId];
  Map<String, DownloadProgress> get progressMap =>
      Map.unmodifiable(_progressMap);

  ValueNotifier<double> getProgress(String taskId) =>
      _progressNotifiers.putIfAbsent(taskId, () => ValueNotifier(0.0));

  ValueNotifier<double> getSpeed(String taskId) =>
      _speedNotifiers.putIfAbsent(taskId, () => ValueNotifier(0.0));

  void updateProgress(String taskId, DownloadProgress newProgress) {
    final oldProgress = _progressMap[taskId];
    if (oldProgress == newProgress) return; // Dedup identical updates
    _progressMap[taskId] = newProgress;
    getProgress(taskId).value = newProgress.progressRatio;
    getSpeed(taskId).value = newProgress.speed;
    notifyListeners();
  }

  void update(String taskId, double progress, double speed) {
    getProgress(taskId).value = progress;
    getSpeed(taskId).value = speed;
  }

  /// Disposes and removes notifiers for a specific task.
  void disposeTask(String taskId) {
    _progressMap.remove(taskId);
    _progressNotifiers.remove(taskId)?.dispose();
    _speedNotifiers.remove(taskId)?.dispose();
  }

  /// Cleans up and disposes all notifiers across all tasks.
  void clearAll() {
    _progressMap.clear();
    for (final notifier in _progressNotifiers.values) {
      notifier.dispose();
    }
    _progressNotifiers.clear();
    for (final notifier in _speedNotifiers.values) {
      notifier.dispose();
    }
    _speedNotifiers.clear();
  }

  @visibleForTesting
  int get notifierCount => _progressNotifiers.length + _speedNotifiers.length;

  @override
  void dispose() {
    clearAll();
    super.dispose();
  }
}
