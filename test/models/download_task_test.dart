import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DownloadTask createTestTask({
    required String id,
    int fileSize = 1000,
    int downloadedBytes = 0,
    DownloadStatus status = DownloadStatus.downloading,
  }) {
    return DownloadTask(
      id: id,
      url: 'https://example.com/file.zip',
      fileName: 'file.zip',
      fileSize: fileSize,
      downloadedBytes: downloadedBytes,
      category: 'Other',
      status: status,
      savePath: '/downloads',
      localFilePath: '/downloads/file.zip',
      tempFilePath: '/downloads/file.zip.tmp',
      threadCount: 4,
      chunks: const [],
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
  }

  group('DownloadTask Model', () {
    test('== and hashCode are id-based', () {
      final taskA = createTestTask(id: 'id-123', fileSize: 1000, downloadedBytes: 200);
      final taskB = createTestTask(id: 'id-123', fileSize: 5000, downloadedBytes: 800);

      expect(taskA == taskB, isTrue);
      expect(taskA.hashCode, equals(taskB.hashCode));
    });

    test('progress is clamped to range 0.0 - 1.0 or -1.0 for unknown size', () {
      final knownSizeTask = createTestTask(id: 'task-1', fileSize: 1000, downloadedBytes: 500);
      expect(knownSizeTask.progress, equals(0.5));

      final unknownSizeTask = createTestTask(id: 'task-2', fileSize: 0, downloadedBytes: 500);
      expect(unknownSizeTask.progress, equals(-1.0));

      final completedTask = createTestTask(
        id: 'task-3',
        fileSize: 1000,
        downloadedBytes: 1000,
        status: DownloadStatus.completed,
      );
      expect(completedTask.progress, equals(1.0));
    });

    test('progressPercentString returns formatted percentage or byte string', () {
      final taskHalf = createTestTask(id: 'task-1', fileSize: 1000, downloadedBytes: 500);
      expect(taskHalf.progressPercentString, equals('50.0%'));

      final taskDone = createTestTask(
        id: 'task-2',
        fileSize: 1000,
        downloadedBytes: 1000,
        status: DownloadStatus.completed,
      );
      expect(taskDone.progressPercentString, equals('100.0%'));
    });
  });
}
