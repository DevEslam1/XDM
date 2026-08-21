import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';

abstract class TaskRepository {
  Future<List<DownloadTask>> getAll();
  Future<List<DownloadTask>> loadAll();
  Future<DownloadTask?> getById(String id);
  Future<void> save(DownloadTask task);
  Future<void> saveDebounced(DownloadTask task);
  Future<void> saveAll(List<DownloadTask> tasks);
  Future<void> delete(String id);
  Future<void> deleteAll(List<String> ids);
  Future<void> deleteMany(List<String> ids);
  Stream<DownloadTask> watchTask(String id);
  Stream<List<DownloadTask>> watchAll();
  void dispose();
}

class InMemoryTaskRepository implements TaskRepository {
  final List<DownloadTask> _storage = [];

  @override
  Future<List<DownloadTask>> getAll() async => List.unmodifiable(_storage);

  @override
  Future<List<DownloadTask>> loadAll() async => getAll();

  @override
  Future<DownloadTask?> getById(String id) async {
    try {
      return _storage.firstWhere((t) => t.id == id);
    } catch (e, st) {
      LoggingService.logger('TaskRepository')
          .warning('Operation failed with fallback', e, st);
      return null;
    }
  }

  @override
  Future<void> save(DownloadTask task) async {
    _storage.removeWhere((t) => t.id == task.id);
    _storage.add(task);
  }

  @override
  Future<void> saveDebounced(DownloadTask task) async => save(task);

  @override
  Future<void> saveAll(List<DownloadTask> tasks) async {
    for (final t in tasks) {
      await save(t);
    }
  }

  @override
  Future<void> delete(String id) async {
    _storage.removeWhere((t) => t.id == id);
  }

  @override
  Future<void> deleteAll(List<String> ids) async {
    _storage.removeWhere((t) => ids.contains(t.id));
  }

  @override
  Future<void> deleteMany(List<String> ids) async => deleteAll(ids);

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
