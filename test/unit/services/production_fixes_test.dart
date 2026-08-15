import 'package:dmx/core/services/background_gate.dart';
import 'package:dmx/core/services/network/cookie_cache.dart';
import 'package:dmx/features/downloads/data/task_repository.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_list_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class MockTaskRepository implements TaskRepository {
  final List<DownloadTask> _storage = [];

  @override
  Future<List<DownloadTask>> getAll() async => List.from(_storage);

  @override
  Future<DownloadTask?> getById(String id) async {
    try {
      return _storage.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(DownloadTask task) async {
    _storage.removeWhere((t) => t.id == task.id);
    _storage.add(task);
  }

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
  Stream<DownloadTask> watchTask(String id) async* {
    final task = await getById(id);
    if (task != null) yield task;
  }
}

void main() {
  group('Phase 1: BackgroundGate Tests', () {
    test('BackgroundGate adaptInterval scales base duration correctly', () {
      const base = Duration(seconds: 5);
      final adapted = BackgroundGate.adaptInterval(base);
      expect(adapted.inSeconds, greaterThanOrEqualTo(5));
    });
  });

  group('Phase 2: CookieCache Tests', () {
    test('CookieCache stores, retrieves, and clears entries', () {
      final cache = CookieCache();
      cache.put('https://example.com', 'session_id=12345');
      expect(cache.get('https://example.com'), equals('session_id=12345'));

      cache.clear();
      expect(cache.get('https://example.com'), isNull);
    });
  });

  group('Phase 5: Provider Decomposition Tests', () {
    test('DownloadListProvider CRUD operations with TaskRepository', () async {
      final repo = MockTaskRepository();
      final provider = DownloadListProvider(repo);

      final task = DownloadTask(
        id: 'test_task_1',
        fileName: 'test.mp4',
        url: 'https://example.com/test.mp4',
        fileSize: 1024,
        downloadedBytes: 0,
        category: 'Videos',
        status: DownloadStatus.queued,
        savePath: '/downloads',
        tempFilePath: '/tmp/test.mp4',
        localFilePath: '/downloads/test.mp4',
        threadCount: 4,
        chunks: const [0.0, 0.0, 0.0, 0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await provider.addTask(task);
      expect(provider.tasks.length, equals(1));
      expect(provider.findTask('test_task_1')?.fileName, equals('test.mp4'));

      await provider.deleteTask('test_task_1');
      expect(provider.tasks.isEmpty, isTrue);
    });
  });
}
