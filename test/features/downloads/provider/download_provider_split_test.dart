import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_list_provider.dart';
import 'package:dmx/features/downloads/provider/download_queue_provider.dart';
import 'package:dmx/features/downloads/provider/download_filter_provider.dart';
import 'package:dmx/features/downloads/provider/download_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DownloadTask createTestTask({
    required String id,
    required String fileName,
    required String url,
    int fileSize = 1000,
  }) {
    final now = DateTime.now();
    return DownloadTask(
      id: id,
      fileName: fileName,
      url: url,
      fileSize: fileSize,
      downloadedBytes: 0,
      category: 'General',
      status: DownloadStatus.queued,
      savePath: '/downloads/$fileName',
      localFilePath: '/downloads/$fileName',
      tempFilePath: '/downloads/$fileName.tmp',
      threadCount: 2,
      chunks: const [],
      createdAt: now,
      updatedAt: now,
    );
  }

  group('DownloadListProvider', () {
    test('Adds and removes task correctly', () {
      final provider = DownloadListProvider();
      final task = createTestTask(
        id: 'task_1',
        fileName: 'file.zip',
        url: 'https://example.com/file.zip',
      );

      provider.addTask(task);
      expect(provider.count, equals(1));
      expect(provider.getTask('task_1'), equals(task));

      provider.removeTask('task_1');
      expect(provider.count, equals(0));
    });
  });

  group('DownloadQueueProvider', () {
    test('Reorders queue correctly', () {
      final queue = DownloadQueueProvider();
      queue.addToQueue('t1');
      queue.addToQueue('t2');
      queue.addToQueue('t3');

      queue.reorderQueue(0, 2);
      expect(queue.queueTaskIds, equals(['t2', 't3', 't1']));
    });
  });

  group('DownloadFilterProvider', () {
    test('Filters tasks by search query', () {
      final filter = DownloadFilterProvider();
      final tasks = [
        createTestTask(id: '1', fileName: 'alpha.mp4', url: 'http://a.com'),
        createTestTask(id: '2', fileName: 'beta.zip', url: 'http://b.com'),
      ];

      filter.setSearchQuery('alpha');
      final result = filter.applyFilter(tasks);
      expect(result.length, equals(1));
      expect(result.first.fileName, equals('alpha.mp4'));
    });
  });

  group('DownloadCoordinator', () {
    test('Coordinating updates exposes filtered tasks', () {
      final list = DownloadListProvider();
      final filter = DownloadFilterProvider();
      final coordinator = DownloadCoordinator(
        listProvider: list,
        filterProvider: filter,
      );

      final task = createTestTask(id: '1', fileName: 'doc.pdf', url: 'http://a.com');

      list.addTask(task);
      expect(coordinator.filteredTasks.length, equals(1));

      filter.setSearchQuery('nonexistent');
      expect(coordinator.filteredTasks.length, equals(0));
    });
  });
}
