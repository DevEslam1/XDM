import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import '../data/task_repository.dart';
import '../models/download_task.dart';

/// Single-responsibility provider for task collection storage and CRUD.
class DownloadListProvider extends ChangeNotifier {
  final TaskRepository _repository;
  final List<DownloadTask> _tasks = [];
  final Map<String, ValueNotifier<double>> _progressNotifiers = {};
  final Map<String, ValueNotifier<double>> _speedNotifiers = {};

  DownloadListProvider(this._repository);

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  int get count => _tasks.length;

  ValueListenable<double> progressRatioFor(String taskId) {
    return _progressNotifiers.putIfAbsent(taskId, () {
      final task = findTask(taskId);
      return ValueNotifier<double>(task?.progressRatio ?? 0.0);
    });
  }

  ValueListenable<double> speedFor(String taskId) {
    return _speedNotifiers.putIfAbsent(taskId, () {
      final task = findTask(taskId);
      return ValueNotifier<double>(task?.speed ?? 0.0);
    });
  }

  Future<void> load() async {
    _tasks.clear();
    _tasks.addAll(await _repository.getAll());
    for (final task in _tasks) {
      _progressNotifiers[task.id]?.value = task.progressRatio;
      _speedNotifiers[task.id]?.value = task.speed;
    }
    notifyListeners();
  }

  void setTasks(List<DownloadTask> tasks) {
    _tasks.clear();
    _tasks.addAll(tasks);
    for (final task in _tasks) {
      _progressNotifiers[task.id]?.value = task.progressRatio;
      _speedNotifiers[task.id]?.value = task.speed;
    }
    notifyListeners();
  }

  Future<void> addTask(DownloadTask task) async {
    _tasks.insert(0, task);
    _progressNotifiers[task.id]?.value = task.progressRatio;
    _speedNotifiers[task.id]?.value = task.speed;
    await _repository.save(task);
    notifyListeners();
  }

  Future<void> updateTask(DownloadTask task) async {
    final index = _tasks.indexWhere((t) => t.id == task.id);
    if (index == -1) return;
    _tasks[index] = task;
    _progressNotifiers[task.id]?.value = task.progressRatio;
    _speedNotifiers[task.id]?.value = task.speed;
    await _repository.save(task);
    notifyListeners();
  }

  Future<void> deleteTask(String id) async {
    _tasks.removeWhere((t) => t.id == id);
    _progressNotifiers.remove(id)?.dispose();
    _speedNotifiers.remove(id)?.dispose();
    await _repository.delete(id);
    notifyListeners();
  }

  void removeTask(String id) {
    _tasks.removeWhere((t) => t.id == id);
    _progressNotifiers.remove(id)?.dispose();
    _speedNotifiers.remove(id)?.dispose();
    notifyListeners();
  }

  Future<void> deleteMultipleTasks(List<String> ids) async {
    _tasks.removeWhere((t) => ids.contains(t.id));
    for (final id in ids) {
      _progressNotifiers.remove(id)?.dispose();
      _speedNotifiers.remove(id)?.dispose();
    }
    await _repository.deleteAll(ids);
    notifyListeners();
  }

  DownloadTask? findTask(String id) {
    try {
      return _tasks.firstWhere((t) => t.id == id);
    } catch (e, st) {
      LoggingService.logger('DownloadListProvider')
          .warning('Operation failed with fallback', e, st);
      return null;
    }
  }

  DownloadTask? getTask(String id) => findTask(id);

  double getTaskProgress(String id) {
    final task = findTask(id);
    return task?.progressRatio ?? 0.0;
  }

  DownloadStatus? getTaskStatus(String id) {
    final task = findTask(id);
    return task?.status;
  }

  /// Granular telemetry snapshot for UI selectors to minimize widget rebuild churn.
  ({
    DownloadStatus? status,
    double progress,
    double speed,
    int downloadedBytes,
    int fileSize
  })? getTaskMetrics(String id) {
    final task = findTask(id);
    if (task == null) return null;
    return (
      status: task.status,
      progress: task.progressRatio,
      speed: task.speed,
      downloadedBytes: task.downloadedBytes,
      fileSize: task.fileSize,
    );
  }

  @override
  void dispose() {
    for (final notifier in _progressNotifiers.values) {
      notifier.dispose();
    }
    for (final notifier in _speedNotifiers.values) {
      notifier.dispose();
    }
    _progressNotifiers.clear();
    _speedNotifiers.clear();
    super.dispose();
  }
}
