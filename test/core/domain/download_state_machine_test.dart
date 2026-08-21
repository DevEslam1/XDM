import 'package:dmx/features/downloads/models/download_state_machine.dart';
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
    threadCount: 4,
    chunks: const [0.0],
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

void main() {
  group('P0-3: DownloadStateMachine & transitionTo hardening', () {
    test('canTransition allows valid lifecycle progression', () {
      expect(DownloadStateMachine.canTransition(DownloadState.queued, DownloadState.downloading), isTrue);
      expect(DownloadStateMachine.canTransition(DownloadState.downloading, DownloadState.paused), isTrue);
      expect(DownloadStateMachine.canTransition(DownloadState.downloading, DownloadState.completed), isTrue);
      expect(DownloadStateMachine.canTransition(DownloadState.downloading, DownloadState.failed), isTrue);
      expect(DownloadStateMachine.canTransition(DownloadState.paused, DownloadState.queued), isTrue);
      expect(DownloadStateMachine.canTransition(DownloadState.paused, DownloadState.downloading), isTrue);
    });

    test('canTransition rejects illegal transitions', () {
      expect(DownloadStateMachine.canTransition(DownloadState.completed, DownloadState.failed), isFalse);
      expect(DownloadStateMachine.canTransition(DownloadState.failed, DownloadState.completed), isFalse);
      expect(DownloadStateMachine.canTransition(DownloadState.idle, DownloadState.completed), isFalse);
    });

    test('transitionTo maintains state when an invalid transition is attempted', () {
      final task = createDummyTask(
        id: 'task-test-1',
        status: DownloadStatus.completed,
      );

      // Transitioning directly from completed to failed is illegal
      final result = task.transitionTo(DownloadStatus.failed, reason: 'test failure');
      expect(result.status, DownloadStatus.completed);
    });

    test('transitionTo permits legal transitions', () {
      final task = createDummyTask(
        id: 'task-test-2',
        status: DownloadStatus.downloading,
      );

      final paused = task.transitionTo(DownloadStatus.paused, reason: 'user paused');
      expect(paused.status, DownloadStatus.paused);

      final downloadingAgain = paused.transitionTo(DownloadStatus.downloading, reason: 'user resumed');
      expect(downloadingAgain.status, DownloadStatus.downloading);

      final completed = downloadingAgain.transitionTo(DownloadStatus.completed, reason: 'done');
      expect(completed.status, DownloadStatus.completed);
    });
  });
}
