import 'dart:io';

import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseService loadTasksPage Pagination (DB-02)', () {
    late Directory tempDir;
    late DatabaseService dbService;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('db_pagination_test_');
      dbService = DatabaseService();
      await dbService.init(testPath: tempDir.path);

      // Insert 120 mock tasks
      for (int i = 1; i <= 120; i++) {
        final task = DownloadTask(
          id: 'task_$i',
          fileName: 'file_$i.zip',
          url: 'https://example.com/file_$i.zip',
          category: 'other',
          threadCount: 4,
          chunks: const [],
          fileSize: 1024 * i,
          downloadedBytes: 1024 * i,
          status: DownloadStatus.completed,
          savePath: tempDir.path,
          localFilePath: '${tempDir.path}/file_$i.zip',
          tempFilePath: '${tempDir.path}/file_$i.zip.part',
          createdAt: DateTime.now().subtract(Duration(minutes: 120 - i)),
          updatedAt: DateTime.now().subtract(Duration(minutes: 120 - i)),
        );
        await dbService.saveTask(task);
      }
    });

    tearDown(() async {
      dbService.cancelPendingTimers();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('loadTasksPage respects limit and offset', () async {
      final page1 = await dbService.loadTasksPage(limit: 50, offset: 0);
      expect(page1.length, equals(50));

      final page2 = await dbService.loadTasksPage(limit: 50, offset: 50);
      expect(page2.length, equals(50));

      final page3 = await dbService.loadTasksPage(limit: 50, offset: 100);
      expect(page3.length, equals(20));

      // Disjoint IDs across pages
      final ids1 = page1.map((t) => t.id).toSet();
      final ids2 = page2.map((t) => t.id).toSet();
      expect(ids1.intersection(ids2), isEmpty);
    });
  });
}
