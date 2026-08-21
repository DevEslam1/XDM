// FIX-P1-01: Extracted task state management from DownloadProvider
import 'dart:collection';
import '../models/download_task.dart';

/// Thread-safe service for managing DownloadTask collection in memory.
class TaskStateService {
  final List<DownloadTask> _tasks = [];
  final Map<String, Object> _locks = {};
  final Map<String, int> _indexMap = {};

  Object lockFor(String id) => _locks.putIfAbsent(id, () => Object());

  UnmodifiableListView<DownloadTask> get allTasks =>
      UnmodifiableListView(_tasks);

  int get count => _tasks.length;

  bool get isEmpty => _tasks.isEmpty;
  bool get isNotEmpty => _tasks.isNotEmpty;

  void _rebuildIndex() {
    _indexMap.clear();
    for (var i = 0; i < _tasks.length; i++) {
      _indexMap[_tasks[i].id] = i;
    }
  }

  DownloadTask? getById(String id) {
    final idx = _indexMap[id];
    if (idx != null && idx < _tasks.length && _tasks[idx].id == id) {
      return _tasks[idx];
    }
    final directIdx = _tasks.indexWhere((t) => t.id == id);
    if (directIdx != -1) {
      _indexMap[id] = directIdx;
      return _tasks[directIdx];
    }
    return null;
  }

  void add(DownloadTask task) {
    final existingIdx = _tasks.indexWhere((t) => t.id == task.id);
    if (existingIdx != -1) {
      _tasks[existingIdx] = task;
    } else {
      _tasks.add(task);
    }
    _rebuildIndex();
  }

  void addAll(Iterable<DownloadTask> tasks) {
    for (final task in tasks) {
      final existingIdx = _tasks.indexWhere((t) => t.id == task.id);
      if (existingIdx != -1) {
        _tasks[existingIdx] = task;
      } else {
        _tasks.add(task);
      }
    }
    _rebuildIndex();
  }

  bool update(DownloadTask updated) {
    final idx =
        _indexMap[updated.id] ?? _tasks.indexWhere((t) => t.id == updated.id);
    if (idx != -1 && idx < _tasks.length) {
      _tasks[idx] = updated;
      _indexMap[updated.id] = idx;
      return true;
    }
    return false;
  }

  bool remove(String id) {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      _tasks.removeAt(idx);
      _locks.remove(id);
      _rebuildIndex();
      return true;
    }
    return false;
  }

  List<DownloadTask> findByStatus(DownloadStatus status) {
    return _tasks.where((t) => t.status == status).toList();
  }

  List<DownloadTask> where(bool Function(DownloadTask) test) {
    return _tasks.where(test).toList();
  }

  void clear() {
    _tasks.clear();
    _locks.clear();
    _indexMap.clear();
  }

  void dispose() {
    clear();
  }
}
