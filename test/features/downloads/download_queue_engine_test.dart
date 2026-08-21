import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_queue_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadQueueEngine unit tests', () {
    late DownloadQueueEngine engine;

    setUp(() {
      engine = DownloadQueueEngine(maxConcurrent: 2);
    });

    DownloadTask createTask({
      required String id,
      DownloadStatus status = DownloadStatus.queued,
      int priority = 0,
      int queueOrder = 0,
      bool isAppUpdate = false,
    }) {
      final now = DateTime.now();
      return DownloadTask(
        id: id,
        url: 'https://example.com/$id.zip',
        fileName: '$id.zip',
        fileSize: 1024 * 1024,
        downloadedBytes: 0,
        category: 'other',
        savePath: '/downloads/$id.zip',
        localFilePath: '/downloads/$id.zip',
        tempFilePath: '/downloads/$id.zip.tmp',
        threadCount: 2,
        chunks: const [0.0, 0.0],
        status: status,
        priority: priority,
        queueOrder: queueOrder,
        isAppUpdate: isAppUpdate,
        createdAt: now,
        updatedAt: now,
      );
    }

    test('getQueuedTasks filters only queued items', () {
      final tasks = [
        createTask(id: '1', status: DownloadStatus.downloading),
        createTask(id: '2', status: DownloadStatus.queued),
        createTask(id: '3', status: DownloadStatus.completed),
        createTask(id: '4', status: DownloadStatus.queued),
      ];

      final queued = engine.getQueuedTasks(tasks);
      expect(queued.length, 2);
      expect(queued.map((t) => t.id), containsAll(['2', '4']));
    });

    test('reorder updates queueOrder sequentially', () {
      final tasks = [
        createTask(id: '1', queueOrder: 0),
        createTask(id: '2', queueOrder: 1),
        createTask(id: '3', queueOrder: 2),
      ];

      final reordered = engine.reorder(tasks, 2, 0);
      expect(reordered.first.id, '3');
      expect(reordered[0].queueOrder, 0);
      expect(reordered[1].queueOrder, 1);
      expect(reordered[2].queueOrder, 2);
    });

    test('boostPriority moves task to index 0', () {
      final tasks = [
        createTask(id: '1', queueOrder: 0),
        createTask(id: '2', queueOrder: 1),
        createTask(id: '3', queueOrder: 2),
      ];

      final boosted = engine.boostPriority(tasks, '2');
      expect(boosted.first.id, '2');
      expect(boosted[0].queueOrder, 0);
    });

    test('pumpQueue prioritizes app updates and priority before admission', () async {
      final started = <String>[];

      final tasks = [
        createTask(id: 'low', status: DownloadStatus.queued, priority: 0),
        createTask(id: 'high', status: DownloadStatus.queued, priority: 10),
        createTask(id: 'update', status: DownloadStatus.queued, isAppUpdate: true),
      ];

      engine.pumpQueue(tasks, (task) async {
        started.add(task.id);
      });

      // Max concurrent = 2 -> should start update and high
      expect(started.length, 2);
      expect(started, equals(['update', 'high']));
    });
  });
}
