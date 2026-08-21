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
    tempDir = await Directory.systemTemp.createTemp('dmx_db_upsert_test_');
    dbService = DatabaseService.instance;
    await dbService.init(testPath: tempDir.path);
  });

  tearDown(() async {
    dbService.cancelPendingTimers();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('P0-2: DatabaseService Transactional Upsert', () {
    test('upsertTasks persists changed tasks correctly', () async {
      final task1 = DownloadTask(
        id: 'task-upsert-1',
        fileName: 'file1.bin',
        url: 'https://example.com/file1.bin',
        fileSize: 1024,
        downloadedBytes: 512,
        category: 'General',
        savePath: '/tmp/file1.bin',
        localFilePath: '/tmp/file1.bin',
        tempFilePath: '/tmp/file1.bin.dmx',
        threadCount: 1,
        chunks: const [0.5],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        status: DownloadStatus.downloading,
      );

      final task2 = DownloadTask(
        id: 'task-upsert-2',
        fileName: 'file2.bin',
        url: 'https://example.com/file2.bin',
        fileSize: 2048,
        downloadedBytes: 0,
        category: 'General',
        savePath: '/tmp/file2.bin',
        localFilePath: '/tmp/file2.bin',
        tempFilePath: '/tmp/file2.bin.dmx',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        status: DownloadStatus.queued,
      );

      await dbService.upsertTasks([task1, task2]);

      final loaded = await dbService.loadTasks();
      expect(loaded.length, 2);
      expect(loaded.any((t) => t.id == 'task-upsert-1' && t.downloadedBytes == 512), isTrue);
      expect(loaded.any((t) => t.id == 'task-upsert-2' && t.status == DownloadStatus.queued), isTrue);

      // Now update task1 and verify upsert modifies existing record
      final updatedTask1 = task1.copyWith(
        downloadedBytes: 1024,
        status: DownloadStatus.completed,
      );

      await dbService.upsertTasks([updatedTask1]);

      final reloaded = await dbService.loadTasks();
      expect(reloaded.length, 2);
      final persistedTask1 = reloaded.firstWhere((t) => t.id == 'task-upsert-1');
      expect(persistedTask1.downloadedBytes, 1024);
      expect(persistedTask1.status, DownloadStatus.completed);
    });
  });
}
