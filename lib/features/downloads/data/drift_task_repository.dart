import 'dart:async';

import 'package:dmx/core/interfaces/i_task_data_source.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';

import 'task_repository.dart';

class DriftTaskRepository implements TaskRepository, ITaskDataSource {
  final DatabaseService _db;
  DriftTaskRepository([DatabaseService? db])
      : _db = db ?? DatabaseService.instance;

  @override
  Future<List<DownloadTask>> getAll() => _db.loadTasks();

  @override
  Future<List<DownloadTask>> loadAll() => _db.loadTasks();

  @override
  Future<DownloadTask?> getById(String id) => _db.getTask(id);

  @override
  Future<void> save(DownloadTask task) => _db.saveTask(task);

  @override
  Future<void> saveDebounced(DownloadTask task) => _db.saveTaskDebounced(task);

  @override
  Future<void> saveAll(List<DownloadTask> tasks) => _db.saveTasks(tasks);

  @override
  Future<void> delete(String id) => _db.deleteTask(id);

  @override
  Future<void> deleteAll(List<String> ids) async {
    for (final id in ids) {
      await _db.deleteTask(id);
    }
  }

  @override
  Future<void> deleteMany(List<String> ids) => deleteAll(ids);

  @override
  Stream<DownloadTask> watchTask(String id) async* {
    final task = await getById(id);
    if (task != null) yield task;
  }

  @override
  Stream<List<DownloadTask>> watchAll() async* {
    yield await getAll();
  }

  @override
  void dispose() {}
}
