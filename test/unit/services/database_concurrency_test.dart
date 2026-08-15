import 'dart:io';

import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseService Concurrency & WAL (DB-01/DB-02)', () {
    late Directory tempDir;
    late DatabaseService dbService;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('db_concurrency_test_');
      dbService = DatabaseService();
      await dbService.init(testPath: tempDir.path);
    });

    tearDown(() async {
      dbService.cancelPendingTimers();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
        '20 concurrent task writes complete simultaneously without database lock',
        () async {
      final futures = <Future<void>>[];

      for (var i = 0; i < 20; i++) {
        final task = DownloadTask(
          id: 'concurrent_task_$i',
          fileName: 'file_$i.bin',
          url: 'https://example.com/file_$i.bin',
          category: 'other',
          threadCount: 4,
          chunks: const [],
          fileSize: 1000 * (i + 1),
          downloadedBytes: 100 * i,
          status: DownloadStatus.downloading,
          savePath: tempDir.path,
          localFilePath: '${tempDir.path}/file_$i.bin',
          tempFilePath: '${tempDir.path}/file_$i.tmp',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        futures.add(dbService.saveTask(task));
      }

      // Must complete without throwing SqliteException(5)
      await Future.wait(futures);

      final loaded = await dbService.loadTasks();
      expect(loaded.length, equals(20));
    });

    test('saveTasks batch transaction saves multiple tasks atomically',
        () async {
      final tasks = List<DownloadTask>.generate(
        15,
        (i) => DownloadTask(
          id: 'batch_task_$i',
          fileName: 'batch_file_$i.bin',
          url: 'https://example.com/batch_file_$i.bin',
          category: 'other',
          threadCount: 4,
          chunks: const [],
          fileSize: 5000,
          downloadedBytes: 2500,
          status: DownloadStatus.downloading,
          savePath: tempDir.path,
          localFilePath: '${tempDir.path}/batch_file_$i.bin',
          tempFilePath: '${tempDir.path}/batch_file_$i.tmp',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      await dbService.saveTasks(tasks);

      final task5 = await dbService.getTask('batch_task_5');
      expect(task5, isNotNull);
      expect(task5!.fileName, equals('batch_file_5.bin'));
    });
  });
}
