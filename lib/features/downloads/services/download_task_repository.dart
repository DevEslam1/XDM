import 'dart:async';
import '../../../core/services/database_service.dart';
import '../models/download_task.dart';

/// Repository interface and implementation for persisting and retrieving
/// [DownloadTask] records using the underlying Drift/SQLite database.
abstract class IDownloadTaskRepository {
  Future<List<DownloadTask>> loadAll();
  Future<DownloadTask?> getById(String id);
  Future<void> save(DownloadTask task);
  Future<void> saveDebounced(DownloadTask task);
  Future<void> saveAll(List<DownloadTask> tasks);
  Future<void> delete(String id);
  Future<void> deleteMany(List<String> ids);
  Stream<DownloadTask> watchTask(String id);
  Stream<List<DownloadTask>> watchAll();
}

class DownloadTaskRepository implements IDownloadTaskRepository {
  final DatabaseService _db;

  DownloadTaskRepository({DatabaseService? databaseService})
      : _db = databaseService ?? DatabaseService.instance;

  @override
  Future<List<DownloadTask>> loadAll() async {
    return await _db.loadTasks();
  }

  @override
  Future<DownloadTask?> getById(String id) async {
    return await _db.getTask(id);
  }

  @override
  Future<void> save(DownloadTask task) async {
    await _db.saveTask(task);
  }

  @override
  Future<void> saveDebounced(DownloadTask task) async {
    await _db.saveTaskDebounced(task);
  }

  @override
  Future<void> saveAll(List<DownloadTask> tasks) async {
    await _db.saveTasks(tasks);
  }

  @override
  Future<void> delete(String id) async {
    await _db.deleteTask(id);
  }

  @override
  Future<void> deleteMany(List<String> ids) async {
    await _db.deleteTasks(ids);
  }

  @override
  Stream<DownloadTask> watchTask(String id) async* {
    final task = await getById(id);
    if (task != null) yield task;
  }

  @override
  Stream<List<DownloadTask>> watchAll() async* {
    yield await loadAll();
  }
}
