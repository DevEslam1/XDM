import 'package:dmx/features/downloads/data/task_repository.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_list_provider.dart';
import 'package:dmx/features/downloads/provider/download_queue_provider.dart';
import 'package:dmx/features/downloads/usecases/start_download_usecase.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadTask createTestTask({
  required String id,
  required String url,
  required String fileName,
  DownloadStatus status = DownloadStatus.queued,
  int fileSize = 1024 * 1024,
}) {
  final now = DateTime.now();
  return DownloadTask(
    id: id,
    fileName: fileName,
    url: url,
    fileSize: fileSize,
    downloadedBytes: 0,
    category: 'Other',
    status: status,
    savePath: '/tmp/$fileName',
    localFilePath: '/tmp/$fileName',
    tempFilePath: '/tmp/$fileName.tmp',
    threadCount: 4,
    chunks: const [],
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('StartDownloadUseCase Tests', () {
    late InMemoryTaskRepository repository;
    late DownloadListProvider listProvider;
    late DownloadQueueProvider queueProvider;
    late StartDownloadUseCase startDownloadUseCase;

    setUp(() {
      repository = InMemoryTaskRepository();
      listProvider = DownloadListProvider(repository);
      queueProvider = DownloadQueueProvider(
        listProvider: listProvider,
        maxConcurrentDownloads: 2,
      );
      startDownloadUseCase = StartDownloadUseCase(listProvider, queueProvider);
    });

    test('successfully adds task to repository and queue', () async {
      final task = createTestTask(
        id: 'test-1',
        url: 'https://example.com/file.zip',
        fileName: 'file.zip',
        status: DownloadStatus.queued,
      );

      await startDownloadUseCase(task);

      expect(listProvider.tasks.length, 1);
      expect(queueProvider.queueTaskIds, contains('test-1'));
      final all = await repository.getAll();
      expect(all.any((t) => t.id == 'test-1'), isTrue);
    });

    test('pumps queue and transitions queued task to downloading when concurrency allows', () async {
      final task = createTestTask(
        id: 'test-2',
        url: 'https://example.com/video.mp4',
        fileName: 'video.mp4',
        status: DownloadStatus.queued,
      );

      await startDownloadUseCase(task);

      final current = listProvider.tasks.firstWhere((t) => t.id == 'test-2');
      expect(current.status, DownloadStatus.downloading);
    });

    test('handles multiple task additions respecting concurrency limits', () async {
      final task1 = createTestTask(
        id: 't-1',
        url: 'https://example.com/1.iso',
        fileName: '1.iso',
        status: DownloadStatus.queued,
      );
      final task2 = createTestTask(
        id: 't-2',
        url: 'https://example.com/2.iso',
        fileName: '2.iso',
        status: DownloadStatus.queued,
      );
      final task3 = createTestTask(
        id: 't-3',
        url: 'https://example.com/3.iso',
        fileName: '3.iso',
        status: DownloadStatus.queued,
      );

      await startDownloadUseCase(task1);
      await startDownloadUseCase(task2);
      await startDownloadUseCase(task3);

      final downloadingCount = listProvider.tasks.where((t) => t.status == DownloadStatus.downloading).length;
      final queuedCount = listProvider.tasks.where((t) => t.status == DownloadStatus.queued).length;

      expect(downloadingCount, 2);
      expect(queuedCount, 1);
    });
  });
}
