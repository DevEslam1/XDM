import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadTask Split (Sprint 3)', () {
    test('DownloadTask exposes DownloadTaskCore and DownloadTaskProgress', () {
      final task = DownloadTask(
        id: 'test-task-1',
        fileName: 'sample.zip',
        url: 'https://example.com/sample.zip',
        fileSize: 1000,
        downloadedBytes: 250,
        speed: 100.0,
        category: 'Archive',
        status: DownloadStatus.downloading,
        savePath: '/downloads/sample.zip',
        localFilePath: '/downloads/sample.zip',
        tempFilePath: '/downloads/sample.zip.tmp',
        threadCount: 4,
        chunks: [0.25],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final core = task.core;
      expect(core.id, equals('test-task-1'));
      expect(core.fileName, equals('sample.zip'));
      expect(core.fileSize, equals(1000));

      final progress = task.progressSnapshot;
      expect(progress.downloadedBytes, equals(250));
      expect(progress.speed, equals(100.0));
      expect(progress.status, equals(DownloadStatus.downloading));
      expect(progress.progressRatio, equals(0.25));
    });
  });
}
