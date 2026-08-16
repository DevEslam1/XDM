import 'dart:io';

import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  late DatabaseService dbService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('dmx_db_test_');
    dbService = DatabaseService.instance;
    await dbService.init(testPath: tempDir.path);
  });

  tearDown(() async {
    dbService.cancelPendingTimers();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('DatabaseService Coalesced Completion Checkpoint (FIX-04)', () {
    test('saving completed task schedules non-blocking wal_checkpoint(FULL)', () async {
      final completedTask = DownloadTask(
        id: 'completed-1',
        fileName: 'file.bin',
        url: 'https://example.com/file.bin',
        fileSize: 1024,
        downloadedBytes: 1024,
        category: 'General',
        savePath: '/tmp/file.bin',
        localFilePath: '/tmp/file.bin',
        tempFilePath: '/tmp/file.bin.dmx',
        threadCount: 1,
        chunks: [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        status: DownloadStatus.completed,
        cycleState: CycleState.completed,
      );

      await dbService.saveTask(completedTask);
      // Immediately after saveTask, microtask is scheduled or in progress
      expect(dbService.completedTaskPendingCheckpoint, isTrue);

      // Await microtasks to finish
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(dbService.completedTaskPendingCheckpoint, isFalse);
    });
  });
}
