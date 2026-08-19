import 'dart:async';
import '../../../core/services/database_service.dart';
import '../data/drift_task_repository.dart';
import '../data/task_repository.dart';
import '../models/download_task.dart';

/// Legacy facade implementing [TaskRepository] that delegates to [DriftTaskRepository].
abstract class IDownloadTaskRepository implements TaskRepository {
  Future<List<DownloadTask>> loadAll();
  Future<void> saveDebounced(DownloadTask task);
  Future<void> deleteMany(List<String> ids);
  Stream<List<DownloadTask>> watchAll();
}

class DownloadTaskRepository implements IDownloadTaskRepository {
  final DriftTaskRepository _delegate;
  final DatabaseService _db;

  DownloadTaskRepository({DatabaseService? databaseService})
      : _db = databaseService ?? DatabaseService.instance,
        _delegate =
            DriftTaskRepository(databaseService ?? DatabaseService.instance);

  @override
  Future<List<DownloadTask>> getAll() => _delegate.getAll();

  @override
  Future<List<DownloadTask>> loadAll() => _delegate.getAll();

  @override
  Future<DownloadTask?> getById(String id) => _delegate.getById(id);

  @override
  Future<void> save(DownloadTask task) => _delegate.save(task);

  @override
  Future<void> saveDebounced(DownloadTask task) => _db.saveTaskDebounced(task);

  @override
  Future<void> saveAll(List<DownloadTask> tasks) => _delegate.saveAll(tasks);

  @override
  Future<void> delete(String id) => _delegate.delete(id);

  @override
  Future<void> deleteMany(List<String> ids) => _delegate.deleteAll(ids);

  @override
  Future<void> deleteAll(List<String> ids) => _delegate.deleteAll(ids);

  @override
  Stream<DownloadTask> watchTask(String id) => _delegate.watchTask(id);

  @override
  Stream<List<DownloadTask>> watchAll() async* {
    yield await loadAll();
  }
}
