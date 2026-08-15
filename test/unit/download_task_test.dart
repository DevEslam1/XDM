import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadTask createDummyTask({
  String id = 'task-1',
  String fileName = 'file.zip',
  String url = 'https://example.com/file.zip',
  int fileSize = 102400,
  int downloadedBytes = 0,
  String category = 'Other',
  DownloadStatus status = DownloadStatus.paused,
  String savePath = '/downloads',
  String localFilePath = '/downloads/file.zip',
  String tempFilePath = '/downloads/file.zip.tmp',
  double speed = 0.0,
  int? audioSize,
  String? errorMessage,
}) {
  return DownloadTask(
    id: id,
    fileName: fileName,
    url: url,
    fileSize: fileSize,
    downloadedBytes: downloadedBytes,
    category: category,
    status: status,
    savePath: savePath,
    localFilePath: localFilePath,
    tempFilePath: tempFilePath,
    speed: speed,
    audioSize: audioSize ?? 0,
    errorMessage: errorMessage,
    threadCount: 4,
    chunks: const [0.0],
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

void main() {
  group('DownloadTask Model', () {
    test('1. fromMap / toMap roundtrip preserves all fields', () {
      final task = createDummyTask(
        id: 'task-100',
        url: 'https://example.com/file.zip',
        fileName: 'file.zip',
        status: DownloadStatus.downloading,
        fileSize: 102400,
        downloadedBytes: 51200,
        speed: 1024.0,
        category: 'Compressed',
      );
      final map = task.toMap();
      final recreated = DownloadTask.fromMap(map);

      expect(recreated.id, equals(task.id));
      expect(recreated.url, equals(task.url));
      expect(recreated.fileName, equals(task.fileName));
      expect(recreated.status, equals(task.status));
      expect(recreated.fileSize, equals(task.fileSize));
      expect(recreated.downloadedBytes, equals(task.downloadedBytes));
    });

    test('2. fromMap with missing fields uses defaults', () {
      final map = <String, dynamic>{
        'id': 'task-101',
        'url': 'https://example.com/test.mp4',
        'fileName': 'test.mp4',
      };
      final task = DownloadTask.fromMap(map);

      expect(task.id, equals('task-101'));
      expect(task.status, equals(DownloadStatus.paused));
      expect(task.fileSize, equals(0));
      expect(task.downloadedBytes, equals(0));
    });

    test('3. fromMap with invalid status falls back to paused', () {
      final map = <String, dynamic>{
        'id': 'task-102',
        'url': 'https://example.com/test.mp4',
        'fileName': 'test.mp4',
        'status': 'invalid_status_string',
      };
      final task = DownloadTask.fromMap(map);

      expect(task.status, equals(DownloadStatus.paused));
    });

    test('4. copyWith preserves unchanged fields', () {
      final task = createDummyTask(
        id: 'task-103',
        fileSize: 5000,
        downloadedBytes: 1000,
      );
      final updated = task.copyWith(downloadedBytes: 2000);

      expect(updated.id, equals(task.id));
      expect(updated.url, equals(task.url));
      expect(updated.fileSize, equals(5000));
      expect(updated.downloadedBytes, equals(2000));
    });

    test('5. copyWith with clearError removes errorMessage', () {
      final task = createDummyTask(
        id: 'task-104',
        errorMessage: 'Network failed',
      );
      final cleared = task.copyWith(clearError: true);

      expect(cleared.errorMessage, isNull);
    });

    test('6. progress returns -1.0 when fileSize is 0', () {
      final task = createDummyTask(
        id: 'task-105',
        fileSize: 0,
        downloadedBytes: 1024,
      );

      expect(task.progress, equals(-1.0));
    });

    test('7. progress clamps to 0.0-1.0', () {
      final taskOver = createDummyTask(
        id: 'task-106',
        fileSize: 1000,
        downloadedBytes: 2000,
      );
      expect(taskOver.progress, equals(1.0));
    });

    test('8. progressPercentString returns "—" for unknown size', () {
      final task = createDummyTask(
        id: 'task-107',
        fileSize: 0,
      );

      expect(task.progressPercentString, equals('—'));
    });

    test('9. combinedTotalSize sums video + audio correctly', () {
      final task = createDummyTask(
        id: 'task-108',
        fileSize: 12000,
        audioSize: 2000,
      ).copyWith(
        videoStreamSize: 10000,
        mergedAudioUrl: 'https://example.com/audio',
      );

      expect(task.combinedTotalSize, equals(12000));
    });

    test('combinedTotalSize when videoStreamSize=0 and fileSize=0', () {
      final task = createDummyTask(
        id: 'task-audio-fallback',
        fileSize: 0,
        audioSize: 5000,
      ).copyWith(
        videoStreamSize: 0,
        mergedAudioUrl: 'https://example.com/audio',
      );
      expect(task.combinedTotalSize, equals(0));
    });

    test('10. isTorrent detects magnet URLs', () {
      final task = createDummyTask(
        id: 'task-109',
        url: 'magnet:?xt=urn:btih:123456789abcdef',
        fileName: 'Ubuntu.iso',
      );

      expect(task.isTorrent, isTrue);
    });

    test('11. isTorrent detects .torrent file URLs', () {
      final task = createDummyTask(
        id: 'task-110',
        url: 'https://example.com/file.torrent',
        fileName: 'file.torrent',
      );

      expect(task.isTorrent, isTrue);
    });

    test('12. isTorrent detects .torrent in fileName', () {
      final task = createDummyTask(
        id: 'task-111',
        url: 'https://example.com/download?id=99',
        fileName: 'linux_distro.torrent',
      );

      expect(task.isTorrent, isTrue);
    });

    test('13. isValidTransition validates state transitions correctly (D-01)',
        () {
      // Legal transitions
      expect(
          DownloadTask.isValidTransition(
              DownloadStatus.queued, DownloadStatus.downloading),
          isTrue);
      expect(
          DownloadTask.isValidTransition(
              DownloadStatus.downloading, DownloadStatus.paused),
          isTrue);
      expect(
          DownloadTask.isValidTransition(
              DownloadStatus.downloading, DownloadStatus.completed),
          isTrue);
      expect(
          DownloadTask.isValidTransition(
              DownloadStatus.paused, DownloadStatus.queued),
          isTrue);
      expect(
          DownloadTask.isValidTransition(
              DownloadStatus.merging, DownloadStatus.completed),
          isTrue);

      // Identity transitions
      expect(
          DownloadTask.isValidTransition(
              DownloadStatus.downloading, DownloadStatus.downloading),
          isTrue);

      final task = createDummyTask(status: DownloadStatus.queued);
      final downloadingTask = task.transitionTo(DownloadStatus.downloading);
      expect(downloadingTask.status, equals(DownloadStatus.downloading));
    });
  });
}
