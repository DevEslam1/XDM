import '../../../core/services/database_service.dart';
import '../models/download_task.dart';

class TaskRepository {
  final DatabaseService _db;

  TaskRepository({DatabaseService? databaseService})
      : _db = databaseService ?? DatabaseService.instance;

  Future<List<DownloadTask>> loadAll() async {
    return await _db.loadTasks();
  }

  Future<DownloadTask?> getById(String id) async {
    return await _db.getTask(id);
  }

  Future<void> save(DownloadTask task) async {
    await _db.saveTask(task);
  }

  Future<void> saveDebounced(DownloadTask task) async {
    await _db.saveTaskDebounced(task);
  }

  Future<void> saveAll(List<DownloadTask> tasks) async {
    await _db.saveTasks(tasks);
  }

  Future<void> delete(String id) async {
    await _db.deleteTask(id);
  }

  Future<void> deleteMany(List<String> ids) async {
    await _db.deleteTasks(ids);
  }
}
