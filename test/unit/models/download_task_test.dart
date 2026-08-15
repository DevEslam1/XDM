import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('DownloadTask priority queue sorting orders correctly', () {
      final now = DateTime.now();
      final appUpdate = DownloadTask(
        id: 't_app',
        fileName: 'update.apk',
        url: 'https://example.com/update.apk',
        fileSize: 100,
        downloadedBytes: 0,
        category: 'Update',
        status: DownloadStatus.queued,
        savePath: '/downloads',
        localFilePath: '/downloads/update.apk',
        tempFilePath: '/downloads/update.apk.dmxpart',
        threadCount: 4,
        chunks: const [],
        createdAt: now.add(const Duration(seconds: 1)),
        updatedAt: now,
        isAppUpdate: true,
        priority: 0,
      );

      final urgent = DownloadTask(
        id: 't_urgent',
        fileName: 'urgent.iso',
        url: 'https://example.com/urgent.iso',
        fileSize: 100,
        downloadedBytes: 0,
        category: 'OS',
        status: DownloadStatus.queued,
        savePath: '/downloads',
        localFilePath: '/downloads/urgent.iso',
        tempFilePath: '/downloads/urgent.iso.dmxpart',
        threadCount: 4,
        chunks: const [],
        createdAt: now.add(const Duration(seconds: 2)),
        updatedAt: now,
        isAppUpdate: false,
        priority: 2, // urgent
      );

      final normalOld = DownloadTask(
        id: 't_normal_old',
        fileName: 'old.zip',
        url: 'https://example.com/old.zip',
        fileSize: 100,
        downloadedBytes: 0,
        category: 'Archive',
        status: DownloadStatus.queued,
        savePath: '/downloads',
        localFilePath: '/downloads/old.zip',
        tempFilePath: '/downloads/old.zip.dmxpart',
        threadCount: 4,
        chunks: const [],
        createdAt: now.subtract(const Duration(seconds: 10)),
        updatedAt: now,
        isAppUpdate: false,
        priority: 0, // normal
        queueOrder: 5,
      );

      final normalNewLowOrder = DownloadTask(
        id: 't_normal_new_low_order',
        fileName: 'new.zip',
        url: 'https://example.com/new.zip',
        fileSize: 100,
        downloadedBytes: 0,
        category: 'Archive',
        status: DownloadStatus.queued,
        savePath: '/downloads',
        localFilePath: '/downloads/new.zip',
        tempFilePath: '/downloads/new.zip.dmxpart',
        threadCount: 4,
        chunks: const [],
        createdAt: now,
        updatedAt: now,
        isAppUpdate: false,
        priority: 0, // normal
        queueOrder: 2, // lower order = higher priority
      );

      final list = [normalOld, urgent, normalNewLowOrder, appUpdate];

      list.sort((a, b) {
        if (a.isAppUpdate != b.isAppUpdate) return b.isAppUpdate ? 1 : -1;
        final prioCmp = b.priority.compareTo(a.priority);
        if (prioCmp != 0) return prioCmp;
        final orderCmp = a.queueOrder.compareTo(b.queueOrder);
        if (orderCmp != 0) return orderCmp;
        return a.createdAt.compareTo(b.createdAt);
      });

      expect(list[0].id, equals('t_app'));
      expect(list[1].id, equals('t_urgent'));
      expect(list[2].id, equals('t_normal_new_low_order'));
      expect(list[3].id, equals('t_normal_old'));
    });

    // TEST-T1: Chunk averaging, padding, and NaN/Inf handling
    test('TEST-T1: sanitizedChunks handles padding, averaging, and NaN/Inf',
        () {
      final taskWithFewerChunks = DownloadTask(
        id: 't_chunks_1',
        fileName: 'file.bin',
        url: 'https://example.com/file.bin',
        fileSize: 1000,
        downloadedBytes: 500,
        category: 'Other',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/file.bin',
        tempFilePath: '/downloads/file.bin.dmxpart',
        threadCount: 4,
        chunks: const [0.2, 0.4], // 2 chunks for 4 threads -> average is 0.3
        createdAt: now,
        updatedAt: now,
      );

      final chunks1 = taskWithFewerChunks.sanitizedChunks;
      expect(chunks1.length, equals(4));
      expect(chunks1[0], closeTo(0.2, 0.001));
      expect(chunks1[1], closeTo(0.4, 0.001));
      expect(chunks1[2], closeTo(0.3, 0.001));
      expect(chunks1[3], closeTo(0.3, 0.001));

      final taskWithNanInf = DownloadTask(
        id: 't_chunks_2',
        fileName: 'file2.bin',
        url: 'https://example.com/file2.bin',
        fileSize: 1000,
        downloadedBytes: 500,
        category: 'Other',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/file2.bin',
        tempFilePath: '/downloads/file2.bin.dmxpart',
        threadCount: 3,
        chunks: const [double.nan, double.infinity, 0.75],
        createdAt: now,
        updatedAt: now,
      );

      final chunks2 = taskWithNanInf.sanitizedChunks;
      expect(chunks2.length, equals(3));
      expect(chunks2[0], equals(0.0));
      expect(chunks2[1], equals(0.0));
      expect(chunks2[2], closeTo(0.75, 0.001));
    });
  });
}
