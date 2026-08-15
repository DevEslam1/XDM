import 'package:flutter/foundation.dart';
import '../models/download_task.dart';

/// Handles download task list CRUD operations and basic state management.
class DownloadStateNotifier extends ChangeNotifier {
  final List<DownloadTask> _tasks = [];
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  void setTasks(List<DownloadTask> newTasks) {
    _tasks.clear();
    _tasks.addAll(newTasks);
    notifyListeners();
  }

  void addTask(DownloadTask task) {
    _tasks.insert(0, task);
    notifyListeners();
  }

  void removeTask(String id) {
    _tasks.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  void updateTask(DownloadTask updated) {
    final index = _tasks.indexWhere((t) => t.id == updated.id);
    if (index != -1) {
      _tasks[index] = updated;
      notifyListeners();
    }
  }
}
