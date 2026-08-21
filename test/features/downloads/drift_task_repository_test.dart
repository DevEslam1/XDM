import 'package:dmx/features/downloads/data/task_repository.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TaskRepository and InMemoryTaskRepository tests', () {
    late TaskRepository repository;

    setUp(() {
      repository = InMemoryTaskRepository();
    });

    DownloadTask createTask(String id) {
      final now = DateTime.now();
      return DownloadTask(
        id: id,
        url: 'https://example.com/$id.zip',
        fileName: '$id.zip',
        fileSize: 1024 * 1024,
        downloadedBytes: 0,
        category: 'other',
        status: DownloadStatus.queued,
        savePath: '/downloads/$id.zip',
        localFilePath: '/downloads/$id.zip',
        tempFilePath: '/downloads/$id.zip.tmp',
        threadCount: 2,
        chunks: const [0.0, 0.0],
        createdAt: now,
        updatedAt: now,
      );
    }

    test('save, loadAll, getById, and delete operations work correctly', () async {
      final task1 = createTask('1');
      final task2 = createTask('2');

      await repository.save(task1);
      await repository.save(task2);

      final all = await repository.loadAll();
      expect(all.length, 2);

      final fetched = await repository.getById('1');
      expect(fetched?.id, '1');

      await repository.delete('1');
      final remaining = await repository.getAll();
      expect(remaining.length, 1);
      expect(remaining.first.id, '2');
    });

    test('saveAll and deleteMany work correctly', () async {
      final tasks = [createTask('a'), createTask('b'), createTask('c')];
      await repository.saveAll(tasks);

      expect((await repository.getAll()).length, 3);

      await repository.deleteMany(['a', 'c']);
      final remaining = await repository.getAll();
      expect(remaining.length, 1);
      expect(remaining.first.id, 'b');
    });

    test('watchTask yields updated task', () async {
      final task = createTask('watch_me');
      await repository.save(task);

      final stream = repository.watchTask('watch_me');
      final emitted = await stream.first;
      expect(emitted.id, 'watch_me');
    });
  });
}
