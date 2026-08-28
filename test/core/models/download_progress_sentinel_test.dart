import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('DownloadTask Progress & Indeterminate Tests', () {
    test(
        'unknown size returns progress 0.0 and isIndeterminate = true when downloading',
        () {
      final task = createTestTask(
        id: 'task-1',
        url: 'https://example.com/stream',
        fileName: 'stream.bin',
        status: DownloadStatus.downloading,
        fileSize: 0,
        downloadedBytes: 5000,
      );

      expect(task.hasUnknownSize, isTrue);
      expect(task.progress, equals(0.0));
      expect(task.isIndeterminate, isTrue);
      expect(task.progressRatio, equals(0.0));
    });

    test(
        'known size computes accurate progress ratio and isIndeterminate = false',
        () {
      final task = createTestTask(
        id: 'task-2',
        url: 'https://example.com/file.zip',
        fileName: 'file.zip',
        status: DownloadStatus.downloading,
        fileSize: 1000,
        downloadedBytes: 500,
      );

      expect(task.hasUnknownSize, isFalse);
      expect(task.progress, equals(0.5));
      expect(task.isIndeterminate, isFalse);
      expect(task.progressRatio, equals(0.5));
    });

    test('completed status returns 1.0 even if fileSize is 0', () {
      final task = createTestTask(
        id: 'task-3',
        url: 'https://example.com/file.zip',
        fileName: 'file.zip',
        status: DownloadStatus.completed,
        fileSize: 0,
        downloadedBytes: 100,
      );

      expect(task.progress, equals(1.0));
      expect(task.isIndeterminate, isFalse);
    });
  });
}
