import 'package:flutter/foundation.dart';

class DownloadQueueProvider extends ChangeNotifier {
  DownloadQueueProvider({int maxConcurrentDownloads = 3})
      : _maxConcurrentDownloads = maxConcurrentDownloads;

  int _maxConcurrentDownloads;
  int get maxConcurrentDownloads => _maxConcurrentDownloads;

  final List<String> _queueTaskIds = [];
  List<String> get queueTaskIds => List.unmodifiable(_queueTaskIds);

  void setMaxConcurrent(int max) {
    _maxConcurrentDownloads = max;
    notifyListeners();
  }

  void addToQueue(String taskId) {
    if (!_queueTaskIds.contains(taskId)) {
      _queueTaskIds.add(taskId);
      notifyListeners();
    }
  }

  void removeFromQueue(String taskId) {
    if (_queueTaskIds.remove(taskId)) {
      notifyListeners();
    }
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _queueTaskIds.length) return;
    if (newIndex < 0 || newIndex >= _queueTaskIds.length) return;

    final id = _queueTaskIds.removeAt(oldIndex);
    _queueTaskIds.insert(newIndex, id);
    notifyListeners();
  }

  void clearQueue() {
    _queueTaskIds.clear();
    notifyListeners();
  }
}
