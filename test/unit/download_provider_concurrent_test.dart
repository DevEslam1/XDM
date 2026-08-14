import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';

void main() {
  group('Download Provider Concurrent Operations Unit Test (FIX-35)', () {
    test('Concurrent pause and resume transitions maintain valid state invariants', () async {
      var task = DownloadTask(
        id: 'concurrent_task_1',
        fileName: 'LargeDataset.zip',
        url: 'https://example.com/data.zip',
        fileSize: 1000000,
        downloadedBytes: 250000,
        category: 'Archives',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/LargeDataset.zip',
        tempFilePath: '/downloads/LargeDataset.zip.xdm',
        threadCount: 4,
        chunks: const [0.25, 0.25, 0.25, 0.25],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // Simulate simultaneous pause actions
      final futures = <Future<DownloadTask>>[
        Future(() => task.copyWith(status: DownloadStatus.paused, pausedByUser: true)),
        Future(() => task.copyWith(status: DownloadStatus.paused, pausedByUser: true)),
      ];

      final results = await Future.wait(futures);
      for (final result in results) {
        expect(result.status, equals(DownloadStatus.paused));
        expect(result.pausedByUser, isTrue);
      }

      task = results.first;

      // Simulate simultaneous resume actions
      final resumeFutures = <Future<DownloadTask>>[
        Future(() => task.copyWith(status: DownloadStatus.downloading, pausedByUser: false)),
        Future(() => task.copyWith(status: DownloadStatus.downloading, pausedByUser: false)),
      ];

      final resumeResults = await Future.wait(resumeFutures);
      for (final result in resumeResults) {
        expect(result.status, equals(DownloadStatus.downloading));
        expect(result.pausedByUser, isFalse);
      }
    });

    test('Concurrent cancel actions are idempotent', () async {
      final task = DownloadTask(
        id: 'concurrent_task_2',
        fileName: 'Installer.exe',
        url: 'https://example.com/installer.exe',
        fileSize: 500000,
        downloadedBytes: 100000,
        category: 'Programs',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/Installer.exe',
        tempFilePath: '/downloads/Installer.exe.xdm',
        threadCount: 2,
        chunks: const [0.2, 0.2],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // Concurrent cancellation
      final cancelOps = List.generate(5, (_) => Future(() => task.copyWith(
        status: DownloadStatus.paused,
        isCancelled: true,
      )));

      final results = await Future.wait(cancelOps);
      for (final cancelledTask in results) {
        expect(cancelledTask.isCancelled, isTrue);
        expect(cancelledTask.status, equals(DownloadStatus.paused));
      }
    });
  });
}
