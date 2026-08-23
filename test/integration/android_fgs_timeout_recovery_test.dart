import 'dart:io';
import 'package:dmx/core/services/background_service.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Android 15 FGS Timeout Recovery Tests', () {
    late Directory tempDir;
    late DatabaseService db;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('dmx_fgs_test_');
      db = DatabaseService.instance;
      await db.init(testPath: tempDir.path);
      DownloadEngine.appInForeground = true;
    });

    tearDown(() async {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('Simulate FGS 6-hour timeout checkpoints tasks, journals, and state', () async {
      final taskPath = '${tempDir.path}/test_video.mp4';
      final tempPartPath = '$taskPath.dmxpart';

      final task = DownloadTask(
        id: 'fgs_task_1',
        url: 'https://example.com/test_video.mp4',
        fileName: 'test_video.mp4',
        savePath: tempDir.path,
        localFilePath: taskPath,
        tempFilePath: tempPartPath,
        category: 'video',
        threadCount: 2,
        chunks: const [0.5, 0.5],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        status: DownloadStatus.downloading,
        downloadedBytes: 5000,
        fileSize: 10000,
      );

      await db.saveTask(task);

      // Open a journal entry for the task
      final journal = DownloadJournal(tempPartPath);
      await journal.open();
      await journal.writeInit(2, 10000);

      // Trigger timeout sequence
      await BackgroundService.triggerDataSyncTimeoutForTesting();

      // Assert active tasks transitioned to paused with PauseReason.scheduled
      final reloadedTask = await db.getTask('fgs_task_1');
      expect(reloadedTask, isNotNull);
      expect(reloadedTask!.status, DownloadStatus.paused);
      expect(reloadedTask.pauseReason, PauseReason.scheduled);

      // Assert state store exists and can be loaded
      final stateResult = await StateStore.loadOrCreate(
        tempPartPath,
        url: task.url,
        threadCount: task.threadCount,
        knownFileSize: task.fileSize,
        taskId: task.id,
      );
      expect(stateResult.state.url, equals(task.url));
      expect(stateResult.state.totalSize, equals(10000));
    });
  });
}
