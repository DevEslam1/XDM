import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadTask createTestTask({
  String id = 'task-1',
  String fileName = 'test.zip',
  String url = 'https://example.com/test.zip',
  int fileSize = 1000,
  int downloadedBytes = 0,
  String category = 'Other',
  DownloadStatus status = DownloadStatus.queued,
  String savePath = '/downloads/test.zip',
  String localFilePath = '/downloads/test.zip',
  String tempFilePath = '/downloads/test.zip.dmxpart',
  int threadCount = 1,
  List<double> chunks = const [0.0],
  DateTime? createdAt,
  DateTime? updatedAt,
  int queueOrder = 0,
  double speed = 0.0,
}) {
  final now = DateTime.now();
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
    threadCount: threadCount,
    chunks: chunks,
    createdAt: createdAt ?? now,
    updatedAt: updatedAt ?? now,
    queueOrder: queueOrder,
    speed: speed,
  );
}

void main() {
  group('DownloadTask model', () {
    test('creates valid download task and computes progress correctly', () {
      final task = createTestTask(
        id: 'task-1',
        url: 'https://example.com/file.zip',
        fileName: 'file.zip',
        fileSize: 1000,
        downloadedBytes: 500,
        status: DownloadStatus.downloading,
      );

      expect(task.progress, 0.5);
      expect(task.progressPercentString, '50.0%');
      expect(task.isTorrent, false);
    });

    test('copyWith updates fields while preserving unmentioned ones', () {
      final task = createTestTask(
        id: 'task-2',
        url: 'https://example.com/file2.zip',
        fileName: 'file2.zip',
        fileSize: 2000,
        downloadedBytes: 0,
        status: DownloadStatus.queued,
      );

      final updated = task.copyWith(
        status: DownloadStatus.downloading,
        downloadedBytes: 1000,
        speed: 500000,
      );

      expect(updated.id, 'task-2');
      expect(updated.status, DownloadStatus.downloading);
      expect(updated.downloadedBytes, 1000);
      expect(updated.speed, 500000);
      expect(updated.fileSize, 2000);
    });

    test('RecoveryHints provides actionable hints for FailureCategory', () {
      expect(RecoveryHints.hintFor(FailureCategory.network),
          contains('internet connection'));
      expect(RecoveryHints.hintFor(FailureCategory.diskFull),
          contains('storage space'));
      expect(RecoveryHints.hintFor(FailureCategory.authError),
          contains('URL expired'));
      expect(RecoveryHints.hintFor(FailureCategory.integrityError),
          contains('Restart download'));
    });

    test('RecoveryHints maps string error family names correctly', () {
      expect(RecoveryHints.fromFamily('network'), FailureCategory.network);
      expect(RecoveryHints.fromFamily('disk'), FailureCategory.diskFull);
      expect(RecoveryHints.fromFamily('auth'), FailureCategory.authError);
      expect(RecoveryHints.fromFamily('server'), FailureCategory.serverError);
    });

    test('DownloadTask JSON serialization and deserialization', () {
      final task = createTestTask(
        id: 'task-json',
        url: 'https://example.com/music.mp3',
        fileName: 'music.mp3',
        fileSize: 5000,
        downloadedBytes: 5000,
        status: DownloadStatus.completed,
      );

      final map = task.toMap();
      final reconstructed = DownloadTask.fromMap(map);

      expect(reconstructed.id, task.id);
      expect(reconstructed.url, task.url);
      expect(reconstructed.status, DownloadStatus.completed);
      expect(reconstructed.downloadedBytes, 5000);
    });
  });
}
