import 'dart:io';

import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DownloadTask createTask(String id, String name, int downloadedBytes, Directory tempDir) {
    final now = DateTime.now();
    return DownloadTask(
      id: id,
      fileName: name,
      url: 'https://example.com/$name',
      fileSize: 1000,
      downloadedBytes: downloadedBytes,
      category: 'other',
      status: DownloadStatus.downloading,
      savePath: '${tempDir.path}/$name',
      localFilePath: '${tempDir.path}/$name',
      tempFilePath: '${tempDir.path}/$name.tmp',
      threadCount: 4,
      chunks: const [],
      createdAt: now,
      updatedAt: now,
    );
  }

  group('DatabaseService saveTaskDebounced Coalescing & Timer Tests', () {
    late Directory tempDir;
    late DatabaseService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('db_debounce_test_');
      service = DatabaseService();
      await service.init(testPath: tempDir.path);
    });

    tearDown(() async {
      service.cancelPendingTimers();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('coalesces 100 rapid saveTaskDebounced calls with at most 1 active timer', () async {
      for (int i = 0; i < 100; i++) {
        final task = createTask('task_$i', 'file_$i.zip', 10 * i, tempDir);
        await service.saveTaskDebounced(task);
      }

      // After 100 calls (which trigger immediate flushes every 20 items),
      // the remaining pending saves (<20) have at most 1 active timer.
      expect(service.dbBatchTimer?.isActive ?? true, isTrue);

      await service.flushPendingSaves();
      expect(service.dbBatchTimer, isNull);
      expect(service.pendingProgressSavesCount, equals(0));
    });

    test('multiple rapid updates to the same task coalesce to 1 pending entry and 1 active timer', () async {
      for (int i = 0; i < 10; i++) {
        final task = createTask('single_task', 'file.zip', i * 50, tempDir);
        await service.saveTaskDebounced(task);
      }

      expect(service.pendingProgressSavesCount, equals(1));
      expect(service.dbBatchTimer, isNotNull);
      expect(service.dbBatchTimer!.isActive, isTrue);

      await service.flushPendingSaves();
      expect(service.dbBatchTimer, isNull);
      expect(service.pendingProgressSavesCount, equals(0));
    });
  });
}
