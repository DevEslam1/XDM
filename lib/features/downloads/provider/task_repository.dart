import 'dart:async';
import '../../../core/services/database_service.dart';
import '../models/download_task.dart';

/// Repository abstracting persistence operations for DownloadTask entities.
class TaskRepository {
  final DatabaseService _db;

  TaskRepository({DatabaseService? databaseService})
      : _db = databaseService ?? DatabaseService.instance;

  /// Loads all tasks from local persistent database.
  Future<List<DownloadTask>> loadAll() async {
    return _db.loadTasks();
  }

  /// Persists a single task immediately to the database.
  Future<void> save(DownloadTask task) async {
    await _db.saveTask(task);
  }

  /// Debounces rapid progress updates before committing to database.
  Future<void> saveDebounced(DownloadTask task) async {
    await _db.saveTaskDebounced(task);
  }

  /// Deletes a task by ID.
  Future<void> delete(String taskId) async {
    await _db.deleteTask(taskId);
  }

  /// Deletes multiple tasks by ID in a batch.
  Future<void> deleteTasks(List<String> taskIds) async {
    await _db.deleteTasks(taskIds);
  }

  /// Forces all pending debounced saves to be committed to disk immediately.
  Future<void> flushPending() async {
    await _db.flushPendingSaves();
  }
}
