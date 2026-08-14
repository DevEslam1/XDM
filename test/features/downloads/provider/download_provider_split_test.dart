import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/data/task_repository.dart';
import 'package:dmx/features/downloads/provider/download_list_provider.dart';
import 'package:dmx/features/downloads/provider/download_queue_provider.dart';
import 'package:dmx/features/downloads/provider/download_filter_provider.dart';
import 'package:dmx/features/downloads/provider/torrent_provider.dart';
import 'package:dmx/features/downloads/provider/download_coordinator.dart';
import 'package:dmx/features/downloads/usecases/pause_download_usecase.dart';
import 'package:dmx/features/downloads/usecases/resume_download_usecase.dart';
import 'package:dmx/features/downloads/usecases/delete_download_usecase.dart';

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
      final provider = DownloadListProvider(InMemoryTaskRepository());
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
      final list = DownloadListProvider(InMemoryTaskRepository());
      final filter = DownloadFilterProvider(list);
      final tasks = [
        createTestTask(id: '1', fileName: 'alpha.mp4', url: 'http://a.com'),
        createTestTask(id: '2', fileName: 'beta.zip', url: 'http://b.com'),
      ];

      for (final t in tasks) {
        list.addTask(t);
      }

      filter.setSearchQuery('alpha');
      final result = filter.filteredTasks;
      expect(result.length, equals(1));
      expect(result.first.fileName, equals('alpha.mp4'));
    });
  });

  group('DownloadCoordinator', () {
    test('Coordinating updates exposes filtered tasks', () {
      final list = DownloadListProvider(InMemoryTaskRepository());
      final filter = DownloadFilterProvider(list);
      final queue = DownloadQueueProvider(listProvider: list);
      final torrent = TorrentProvider();
      final pauseUseCase = PauseDownloadUseCase(queue);
      final resumeUseCase = ResumeDownloadUseCase(queue);
      final deleteUseCase = DeleteDownloadUseCase(list);
      final coordinator = DownloadCoordinator(
        listProvider: list,
        filterProvider: filter,
        queueProvider: queue,
        torrentProvider: torrent,
        pauseUseCase: pauseUseCase,
        resumeUseCase: resumeUseCase,
        deleteUseCase: deleteUseCase,
      );

      final task =
          createTestTask(id: '1', fileName: 'doc.pdf', url: 'http://a.com');

      list.addTask(task);
      expect(coordinator.filteredTasks.length, equals(1));

      filter.setSearchQuery('nonexistent');
      expect(coordinator.filteredTasks.length, equals(0));
    });
  });
}
