import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Torrent Lifecycle Integration Test (FIX-35)', () {
    test('Torrent task correctly parses multi-file structure and aggregates',
        () {
      final task = DownloadTask(
        id: 'torrent_test_1',
        fileName: 'Ubuntu 24.04.iso',
        url: 'magnet:?xt=urn:btih:d3b07384d113edec49eaa6238ad5ff00',
        fileSize: 0, // Initially 0 for magnet
        downloadedBytes: 0,
        category: 'Operating Systems',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/Ubuntu 24.04.iso',
        tempFilePath: '/downloads/Ubuntu 24.04.iso.xdm',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        torrentFiles: const [
          {
            'index': 0,
            'name': 'ubuntu-desktop.iso',
            'length': 4000000000, // 4 GB
            'downloadedBytes': 2000000000,
            'priority': 4,
            'selected': true,
          },
          {
            'index': 1,
            'name': 'sha256sum.txt',
            'length': 1000,
            'downloadedBytes': 1000,
            'priority': 4,
            'selected': true,
          },
          {
            'index': 2,
            'name': 'optional-docs.pdf',
            'length': 5000000,
            'downloadedBytes': 0,
            'priority': 0,
            'selected': false, // unselected
          },
        ],
      );

      expect(task.isTorrent, isTrue);
      expect(task.hasTorrentFiles, isTrue);

      final aggregates = task.torrentFileAggregates;
      // Selected files: 4GB + 1000 bytes
      expect(aggregates.totalFileBytes, equals(4000001000));
      expect(aggregates.downloadedFileBytes, equals(2000001000));
      expect(task.resolvedFileSize, equals(4000001000));
      expect(task.torrentOverallPercent, closeTo(0.5, 0.001));
    });

    test('Torrent seeding ratio calculation and limit tracking', () {
      final task = DownloadTask(
        id: 'torrent_test_2',
        fileName: 'Debian.iso',
        url: 'magnet:?xt=urn:btih:d3b07384d113edec49eaa6238ad5ff01',
        fileSize: 2000000000,
        downloadedBytes: 2000000000,
        uploadedBytes: 3000000000,
        seedingEnabled: true,
        seedingLimited: true,
        seedingLimitKbps: 1000,
        category: 'Operating Systems',
        status: DownloadStatus.completed,
        savePath: '/downloads',
        localFilePath: '/downloads/Debian.iso',
        tempFilePath: '/downloads/Debian.iso.xdm',
        threadCount: 1,
        chunks: const [1.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(task.isTorrent, isTrue);
      expect(task.status, equals(DownloadStatus.completed));
      expect(task.seedingEnabled, isTrue);
      expect(task.seedingRatio, closeTo(1.5, 0.01)); // 3GB / 2GB = 1.5 ratio
    });

    test('Torrent lifecycle state transitions', () {
      var task = DownloadTask(
        id: 'torrent_test_3',
        fileName: 'ArchLinux.iso',
        url: 'magnet:?xt=urn:btih:d3b07384d113edec49eaa6238ad5ff02',
        fileSize: 1000000000,
        downloadedBytes: 500000000,
        category: 'Operating Systems',
        status: DownloadStatus.queued,
        savePath: '/downloads',
        localFilePath: '/downloads/ArchLinux.iso',
        tempFilePath: '/downloads/ArchLinux.iso.xdm',
        threadCount: 1,
        chunks: const [0.5],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(
          DownloadTask.isValidTransition(
              task.status, DownloadStatus.downloading),
          isTrue);
      task = task.copyWith(status: DownloadStatus.downloading);

      expect(DownloadTask.isValidTransition(task.status, DownloadStatus.paused),
          isTrue);
      task = task.copyWith(status: DownloadStatus.paused);

      expect(
          DownloadTask.isValidTransition(
              task.status, DownloadStatus.downloading),
          isTrue);
      task = task.copyWith(status: DownloadStatus.downloading);

      expect(
          DownloadTask.isValidTransition(task.status, DownloadStatus.completed),
          isTrue);
      task = task.copyWith(
        status: DownloadStatus.completed,
        downloadedBytes: 1000000000,
        chunks: const [1.0],
      );

      expect(task.progress, equals(1.0));
    });
  });
}
