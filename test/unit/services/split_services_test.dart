import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/services/download_queue_service.dart';
import 'package:dmx/features/downloads/services/download_execution_service.dart';
import 'package:dmx/features/downloads/services/torrent_session_manager.dart';

class MockQueueHost implements DownloadQueueHost {
  List<DownloadTask> taskList = [];
  int maxConcurrent = 3;
  int downloadingCount = 0;
  final Set<String> executed = {};

  @override
  List<DownloadTask> get tasks => taskList;

  @override
  int get maxConcurrentDownloads => maxConcurrent;

  @override
  int get downloadingTasksCount => downloadingCount;

  @override
  bool isTaskStarting(String taskId) => false;

  @override
  Future<void> executeTask(String taskId) async {
    executed.add(taskId);
  }

  @override
  Future<void> updateTaskOrder(List<DownloadTask> orderedTasks) async {
    taskList = List.from(orderedTasks);
  }
}

class MockExecutionHost implements DownloadExecutionHost {
  final List<String> started = [];
  final List<String> paused = [];
  final List<String> resumed = [];
  final List<String> retried = [];
  final List<String> cancelled = [];

  @override
  Future<void> executeDownload(String taskId,
      {bool isAutoRetry = false}) async {
    started.add(taskId);
  }

  @override
  Future<void> pauseDownload(String taskId) async {
    paused.add(taskId);
  }

  @override
  Future<void> resumeDownload(String taskId) async {
    resumed.add(taskId);
  }

  @override
  Future<void> retryDownload(String taskId) async {
    retried.add(taskId);
  }

  @override
  Future<void> cancelDownload(String taskId) async {
    cancelled.add(taskId);
  }
}

void main() {
  group('DownloadQueueService Tests', () {
    test('pumpQueue starts queued tasks up to available slots', () async {
      final host = MockQueueHost();
      final now = DateTime.now();
      host.taskList = [
        DownloadTask(
          id: '1',
          fileName: 'f1',
          url: 'http://example.com/1',
          fileSize: 1000,
          downloadedBytes: 0,
          category: 'Other',
          status: DownloadStatus.queued,
          savePath: '/tmp',
          localFilePath: '/tmp/f1',
          tempFilePath: '/tmp/1',
          threadCount: 1,
          chunks: [0.0],
          createdAt: now,
          updatedAt: now,
          queueOrder: 0,
        ),
        DownloadTask(
          id: '2',
          fileName: 'f2',
          url: 'http://example.com/2',
          fileSize: 2000,
          downloadedBytes: 0,
          category: 'Other',
          status: DownloadStatus.queued,
          savePath: '/tmp',
          localFilePath: '/tmp/f2',
          tempFilePath: '/tmp/2',
          threadCount: 1,
          chunks: [0.0],
          createdAt: now,
          updatedAt: now,
          queueOrder: 1,
        ),
      ];
      final queueService = DownloadQueueService(host: host);

      await queueService.pumpQueue();
      expect(host.executed, containsAll(['1', '2']));
    });

    test('reorderTasks updates task queueOrder correctly', () async {
      final host = MockQueueHost();
      final now = DateTime.now();
      host.taskList = [
        DownloadTask(
          id: '1',
          fileName: 'f1',
          url: 'http://example.com/1',
          fileSize: 1000,
          downloadedBytes: 0,
          category: 'Other',
          status: DownloadStatus.queued,
          savePath: '/tmp',
          localFilePath: '/tmp/f1',
          tempFilePath: '/tmp/1',
          threadCount: 1,
          chunks: [0.0],
          createdAt: now,
          updatedAt: now,
          queueOrder: 0,
        ),
        DownloadTask(
          id: '2',
          fileName: 'f2',
          url: 'http://example.com/2',
          fileSize: 2000,
          downloadedBytes: 0,
          category: 'Other',
          status: DownloadStatus.queued,
          savePath: '/tmp',
          localFilePath: '/tmp/f2',
          tempFilePath: '/tmp/2',
          threadCount: 1,
          chunks: [0.0],
          createdAt: now,
          updatedAt: now,
          queueOrder: 1,
        ),
      ];
      final queueService = DownloadQueueService(host: host);

      await queueService.reorderTasks(1, 0);
      expect(host.taskList.first.id, '2');
      expect(host.taskList.first.queueOrder, 0);
      expect(host.taskList.last.id, '1');
      expect(host.taskList.last.queueOrder, 1);
    });
  });

  group('DownloadExecutionService Tests', () {
    test('delegates lifecycle operations to host', () async {
      final host = MockExecutionHost();
      final execService = DownloadExecutionService(host: host);

      await execService.startTask('task-1');
      await execService.pauseTask('task-1');
      await execService.resumeTask('task-1');
      await execService.retryTask('task-1');
      await execService.cancelTask('task-1');

      expect(host.started, contains('task-1'));
      expect(host.paused, contains('task-1'));
      expect(host.resumed, contains('task-1'));
      expect(host.retried, contains('task-1'));
      expect(host.cancelled, contains('task-1'));
    });

    test('getOrCreateCancelToken manages tokens per task', () {
      final host = MockExecutionHost();
      final execService = DownloadExecutionService(host: host);

      final token1 = execService.getOrCreateCancelToken('task-1');
      expect(token1.isCancelled, isFalse);

      execService.cancelToken('task-1');
      expect(token1.isCancelled, isTrue);

      final token2 = execService.getOrCreateCancelToken('task-1');
      expect(token2.isCancelled, isFalse);
    });
  });

  group('TorrentSessionManager Tests', () {
    test('registers and queries torrent IDs', () {
      final manager = TorrentSessionManager();
      manager.registerTorrentId('t-1', 42);

      expect(manager.getTorrentId('t-1'), 42);
      manager.unregisterTorrent('t-1');
      expect(manager.getTorrentId('t-1'), isNull);
    });
  });
}
