import 'dart:io';

import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late DatabaseService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('db_upsert_test_');
    service = DatabaseService();
    await service.init(testPath: tempDir.path);
  });

  tearDown(() async {
    service.cancelPendingTimers();
    await service.dispose();
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('DatabaseService Batch Upsert & PK Collision Fallback (L6)', () {
    test(
        'insert task T1, batch-upsert with same ID updates record without collision error',
        () async {
      final now = DateTime.now();
      final task1 = DownloadTask(
        id: 'task_t1',
        url: 'https://example.com/file.zip',
        fileName: 'file.zip',
        savePath: '${tempDir.path}/file.zip',
        localFilePath: '${tempDir.path}/file.zip',
        tempFilePath: '${tempDir.path}/file.zip.tmp',
        fileSize: 100000,
        downloadedBytes: 10000,
        category: 'other',
        status: DownloadStatus.downloading,
        threadCount: 4,
        chunks: const [],
        createdAt: now,
        updatedAt: now,
        cycleState: CycleState.downloading,
      );

      // Initial save
      await service.saveTask(task1);

      final initialTasks = await service.loadTasks();
      expect(initialTasks.length, equals(1));
      expect(initialTasks.first.id, equals('task_t1'));
      expect(initialTasks.first.fileName, equals('file.zip'));

      // Modified task with same ID
      final updatedTask1 = task1.copyWith(
        fileName: 'file_renamed.zip',
        downloadedBytes: 50000,
        status: DownloadStatus.completed,
        cycleState: CycleState.completed,
      );

      final task2 = DownloadTask(
        id: 'task_t2',
        url: 'https://example.com/other.zip',
        fileName: 'other.zip',
        savePath: '${tempDir.path}/other.zip',
        localFilePath: '${tempDir.path}/other.zip',
        tempFilePath: '${tempDir.path}/other.zip.tmp',
        fileSize: 200000,
        downloadedBytes: 0,
        category: 'other',
        status: DownloadStatus.downloading,
        threadCount: 4,
        chunks: const [],
        createdAt: now,
        updatedAt: now,
        cycleState: CycleState.starting,
      );

      // Batch upsert with collision on T1 and new T2
      await service.batchUpsertTasks([updatedTask1, task2]);

      final allTasks = await service.loadTasks();
      expect(allTasks.length, equals(2));

      final loadedT1 = allTasks.firstWhere((t) => t.id == 'task_t1');
      expect(loadedT1.fileName, equals('file_renamed.zip'));
      expect(loadedT1.downloadedBytes, equals(50000));
      expect(loadedT1.status, equals(DownloadStatus.completed));
      expect(loadedT1.cycleState, equals(CycleState.completed));

      final loadedT2 = allTasks.firstWhere((t) => t.id == 'task_t2');
      expect(loadedT2.fileName, equals('other.zip'));
    });
  });
}
