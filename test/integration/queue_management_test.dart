import 'package:dmx/features/downloads/data/task_repository.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemoryTaskRepository repo;

  setUp(() {
    repo = InMemoryTaskRepository();
  });

  tearDown(() {
    repo.dispose();
  });

  DownloadTask createTask(String id, int order) {
    final now = DateTime.now();
    return DownloadTask(
      id: id,
      fileName: '$id.zip',
      url: 'https://example.com/$id.zip',
      fileSize: 1000,
      downloadedBytes: 0,
      category: 'General',
      status: DownloadStatus.queued,
      savePath: '/downloads',
      localFilePath: '/downloads/$id.zip',
      tempFilePath: '/downloads/$id.zip.tmp',
      threadCount: 2,
      chunks: const [0.0],
      createdAt: now,
      updatedAt: now,
      queueOrder: order,
    );
  }

  group('Queue Management Integration', () {
    test('1. Add 5 tasks with maxDownloads=3 → repository holds 5 queued tasks',
        () async {
      for (int i = 1; i <= 5; i++) {
        await repo.save(createTask('q$i', i));
      }

      final all = await repo.loadAll();
      expect(all.length, equals(5));
      expect(all.where((t) => t.status == DownloadStatus.queued).length,
          equals(5));
    });

    test('2. Complete 1 task → task status updated to completed', () async {
      final task = createTask('q1', 1);
      await repo.save(task);

      final completed = task.copyWith(status: DownloadStatus.completed);
      await repo.save(completed);

      final fetched = await repo.getById('q1');
      expect(fetched!.status, equals(DownloadStatus.completed));
    });

    test('3. Reorder queue → order reflects new queueOrder', () async {
      final t1 = createTask('q1', 1);
      final t2 = createTask('q2', 2);
      await repo.saveAll([t1, t2]);

      final reorderedT1 = t1.copyWith(queueOrder: 2);
      final reorderedT2 = t2.copyWith(queueOrder: 1);
      await repo.saveAll([reorderedT1, reorderedT2]);

      final all = await repo.loadAll();
      final sorted = List.of(all)
        ..sort((a, b) => a.queueOrder.compareTo(b.queueOrder));
      expect(sorted.first.id, equals('q2'));
      expect(sorted.last.id, equals('q1'));
    });

    test('4. Priority boost moves task forward', () async {
      final t1 = createTask('q1', 1);
      final t2 = createTask('q2', 2);
      await repo.saveAll([t1, t2]);

      // Boost t2
      final boosted = t2.copyWith(queueOrder: 0);
      await repo.save(boosted);

      final fetched = await repo.getById('q2');
      expect(fetched!.queueOrder, equals(0));
    });
  });
}
