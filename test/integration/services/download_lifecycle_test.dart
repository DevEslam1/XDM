import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

/// Helper to build a minimal [DownloadTask] for testing.
DownloadTask _makeTask({
  required String id,
  DownloadStatus status = DownloadStatus.queued,
  bool pausedByUser = false,
  String? errorMessage,
  DateTime? scheduledAt,
  int fileSize = 1000,
  int downloadedBytes = 0,
}) {
  return DownloadTask(
    id: id,
    fileName: 'file_$id.mp4',
    url: 'https://example.com/$id',
    fileSize: fileSize,
    downloadedBytes: downloadedBytes,
    category: 'Other',
    status: status,
    savePath: '/tmp',
    localFilePath: '/tmp/file_$id.mp4',
    tempFilePath: '/tmp/file_$id.mp4.tmp',
    threadCount: 1,
    chunks: const [0.0],
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    pausedByUser: pausedByUser,
    errorMessage: errorMessage,
    scheduledAt: scheduledAt,
  );
}

void main() {
  group('Download lifecycle state transitions', () {
    test('queued -> downloading', () {
      final task = _makeTask(id: '1', status: DownloadStatus.queued);
      final updated = task.copyWith(status: DownloadStatus.downloading);

      expect(updated.status, equals(DownloadStatus.downloading));
      expect(updated.id, equals('1'));
      expect(updated.url, equals(task.url));
    });

    test('downloading -> paused', () {
      final task = _makeTask(id: '2', status: DownloadStatus.downloading);
      final updated = task.copyWith(
        status: DownloadStatus.paused,
        speed: 0,
        clearEta: true,
        pausedByUser: true,
      );

      expect(updated.status, equals(DownloadStatus.paused));
      expect(updated.pausedByUser, isTrue);
      expect(updated.speed, equals(0));
    });

    test('paused -> downloading (resume)', () {
      final task = _makeTask(
        id: '3',
        status: DownloadStatus.paused,
        pausedByUser: true,
      );
      final updated = task.copyWith(
        status: DownloadStatus.downloading,
        pausedByUser: false,
        clearError: true,
      );

      expect(updated.status, equals(DownloadStatus.downloading));
      expect(updated.pausedByUser, isFalse);
      expect(updated.errorMessage, isNull);
    });

    test('downloading -> completed', () {
      final task = _makeTask(
        id: '4',
        status: DownloadStatus.downloading,
        fileSize: 1000,
      );
      final updated = task.copyWith(
        status: DownloadStatus.completed,
        downloadedBytes: 1000,
        completedAt: DateTime.now(),
      );

      expect(updated.status, equals(DownloadStatus.completed));
      expect(updated.progress, equals(1.0));
      expect(updated.completedAt, isNotNull);
    });

    test('downloading -> failed', () {
      final task = _makeTask(id: '5', status: DownloadStatus.downloading);
      final updated = task.copyWith(
        status: DownloadStatus.failed,
        errorMessage: 'Connection reset',
        speed: 0,
      );

      expect(updated.status, equals(DownloadStatus.failed));
      expect(updated.errorMessage, equals('Connection reset'));
    });

    test('paused -> cancelled (failed with cancel)', () {
      final task = _makeTask(
        id: '6',
        status: DownloadStatus.paused,
        pausedByUser: true,
      );
      // Cancel is modeled as failed in the download system
      final updated = task.copyWith(
        status: DownloadStatus.failed,
        errorMessage: 'Cancelled by user',
      );

      expect(updated.status, equals(DownloadStatus.failed));
    });

    test(
      'full lifecycle: queued -> downloading -> paused -> resume -> completed',
      () {
        // Start queued
        var task = _makeTask(id: '7', status: DownloadStatus.queued);
        expect(task.status, equals(DownloadStatus.queued));

        // Start downloading
        task = task.copyWith(status: DownloadStatus.downloading);
        expect(task.status, equals(DownloadStatus.downloading));

        // Pause
        task = task.copyWith(
          status: DownloadStatus.paused,
          pausedByUser: true,
          speed: 0,
        );
        expect(task.status, equals(DownloadStatus.paused));
        expect(task.pausedByUser, isTrue);

        // Resume
        task = task.copyWith(
          status: DownloadStatus.downloading,
          pausedByUser: false,
          clearError: true,
        );
        expect(task.status, equals(DownloadStatus.downloading));

        // Complete
        task = task.copyWith(
          status: DownloadStatus.completed,
          downloadedBytes: 1000,
          completedAt: DateTime.now(),
        );
        expect(task.status, equals(DownloadStatus.completed));
        expect(task.progress, equals(1.0));
      },
    );

    test('scheduled task transitions: paused (scheduled) -> queued', () {
      final futureTime = DateTime.now().add(const Duration(hours: 1));
      var task = _makeTask(
        id: '8',
        status: DownloadStatus.paused,
        scheduledAt: futureTime,
      );
      expect(task.scheduledAt, isNotNull);

      // Schedule fires: promote to queued, clear schedule
      task = task.copyWith(
        status: DownloadStatus.queued,
        clearError: true,
        clearCompletedAt: true,
        clearScheduledAt: true,
      );
      expect(task.status, equals(DownloadStatus.queued));
      expect(task.scheduledAt, isNull);
    });
  });

  group('DownloadTask progress calculations', () {
    test('progress is 0 when no bytes downloaded', () {
      final task = _makeTask(
        id: 'p1',
        status: DownloadStatus.downloading,
        fileSize: 1000,
      );
      expect(task.progress, equals(0.0));
    });

    test('progress is 0.5 at halfway', () {
      final task = DownloadTask(
        id: 'p2',
        fileName: 'test.mp4',
        url: 'https://example.com/test',
        fileSize: 1000,
        downloadedBytes: 500,
        category: 'Other',
        status: DownloadStatus.downloading,
        savePath: '/tmp',
        localFilePath: '/tmp/test.mp4',
        tempFilePath: '/tmp/test.mp4.tmp',
        threadCount: 1,
        chunks: const [0.5],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      expect(task.progress, equals(0.5));
    });

    test('progress is 1.0 when completed regardless of bytes', () {
      final task = _makeTask(
        id: 'p3',
        status: DownloadStatus.completed,
        fileSize: 1000,
      );
      expect(task.progress, equals(1.0));
    });
  });

  group('DownloadTask copyWith preserves identity', () {
    test('id is preserved across copyWith', () {
      final task = _makeTask(id: 'identity1', status: DownloadStatus.queued);
      final updated = task.copyWith(status: DownloadStatus.downloading);
      expect(updated.id, equals('identity1'));
    });

    test('url is preserved across copyWith', () {
      final task = _makeTask(id: 'identity2', status: DownloadStatus.queued);
      final updated = task.copyWith(status: DownloadStatus.failed);
      expect(updated.url, equals(task.url));
    });
  });
}
