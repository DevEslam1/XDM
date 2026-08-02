import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.now();

  group('DownloadTask Model Unit Tests', () {
    test('DownloadTask constructs with accurate default values', () {
      final task = DownloadTask(
        id: 't1',
        fileName: 'ubuntu.iso',
        url: 'https://releases.ubuntu.com/24.04/ubuntu-24.04-desktop-amd64.iso',
        fileSize: 4000000000,
        downloadedBytes: 2000000000,
        category: 'OS',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/ubuntu.iso',
        tempFilePath: '/downloads/ubuntu.iso.dmxpart',
        threadCount: 4,
        chunks: const [0.5],
        createdAt: now,
        updatedAt: now,
      );

      expect(task.id, equals('t1'));
      expect(task.fileName, equals('ubuntu.iso'));
      expect(task.progress, closeTo(0.5, 0.01));
      expect(task.status, equals(DownloadStatus.downloading));
    });

    test('DownloadTask copyWith updates fields correctly', () {
      final task = DownloadTask(
        id: 't2',
        fileName: 'video.mp4',
        url: 'https://example.com/video.mp4',
        fileSize: 100,
        downloadedBytes: 50,
        category: 'Video',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/video.mp4',
        tempFilePath: '/downloads/video.mp4.dmxpart',
        threadCount: 4,
        chunks: const [0.5],
        createdAt: now,
        updatedAt: now,
      );

      final updated = task.copyWith(
        status: DownloadStatus.completed,
        downloadedBytes: 100,
        completedAt: now,
      );

      expect(updated.id, equals('t2'));
      expect(updated.status, equals(DownloadStatus.completed));
      expect(updated.downloadedBytes, equals(100));
      expect(updated.progress, equals(1.0));
    });

    test('DownloadTask formatting helpers produce formatted strings', () {
      final task = DownloadTask(
        id: 't3',
        fileName: 'archive.zip',
        url: 'https://example.com/archive.zip',
        fileSize: 10485760, // 10 MB
        downloadedBytes: 5242880, // 5 MB
        speed: 1048576, // 1 MB/s
        category: 'Archive',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/archive.zip',
        tempFilePath: '/downloads/archive.zip.dmxpart',
        threadCount: 4,
        chunks: const [0.5],
        createdAt: now,
        updatedAt: now,
      );

      expect(task.progressPercentString, equals('50.0%'));
      expect(task.speedFormatted, isNotEmpty);
    });
  });
}
