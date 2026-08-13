import 'package:flutter/foundation.dart';
import 'package:dmx/features/downloads/models/download_task.dart';

class DownloadListProvider extends ChangeNotifier {
  DownloadListProvider();

  final Map<String, DownloadTask> _tasks = {};

  List<DownloadTask> get tasks => _tasks.values.toList();
  int get count => _tasks.length;

  DownloadTask? getTask(String taskId) => _tasks[taskId];

  void setTasks(List<DownloadTask> newTasks) {
    _tasks.clear();
    for (final task in newTasks) {
      _tasks[task.id] = task;
    }
    notifyListeners();
  }

  void addTask(DownloadTask task) {
    _tasks[task.id] = task;
    notifyListeners();
  }

  void updateTask(DownloadTask task) {
    _tasks[task.id] = task;
    notifyListeners();
  }

  void removeTask(String taskId) {
    _tasks.remove(taskId);
    notifyListeners();
  }

  void clearAll() {
    _tasks.clear();
    notifyListeners();
  }
}
