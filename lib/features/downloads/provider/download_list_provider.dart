import 'package:flutter/foundation.dart';
import '../data/task_repository.dart';
import '../models/download_task.dart';

/// Single-responsibility provider for task collection storage and CRUD.
class DownloadListProvider extends ChangeNotifier {
  final TaskRepository _repository;
  final List<DownloadTask> _tasks = [];

  DownloadListProvider(this._repository);

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  int get count => _tasks.length;

  Future<void> load() async {
    _tasks.clear();
    _tasks.addAll(await _repository.getAll());
    notifyListeners();
  }

  void setTasks(List<DownloadTask> tasks) {
    _tasks.clear();
    _tasks.addAll(tasks);
    notifyListeners();
  }

  Future<void> addTask(DownloadTask task) async {
    _tasks.insert(0, task);
    await _repository.save(task);
    notifyListeners();
  }

  Future<void> updateTask(DownloadTask task) async {
    final index = _tasks.indexWhere((t) => t.id == task.id);
    if (index == -1) return;
    _tasks[index] = task;
    await _repository.save(task);
    notifyListeners();
  }

  Future<void> deleteTask(String id) async {
    _tasks.removeWhere((t) => t.id == id);
    await _repository.delete(id);
    notifyListeners();
  }

  void removeTask(String id) {
    _tasks.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  Future<void> deleteMultipleTasks(List<String> ids) async {
    _tasks.removeWhere((t) => ids.contains(t.id));
    await _repository.deleteAll(ids);
    notifyListeners();
  }

  DownloadTask? findTask(String id) {
    try {
      return _tasks.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  DownloadTask? getTask(String id) => findTask(id);
}
