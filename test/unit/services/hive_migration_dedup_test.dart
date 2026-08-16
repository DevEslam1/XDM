import 'dart:io';

import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/hive_migration_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase db;
  late SharedPreferences prefs;
  late HiveMigrationService migrationService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_dedup_test_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    migrationService = HiveMigrationService(db, prefs);
  });

  tearDown(() async {
    await Hive.close();
    await db.close();
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('HiveMigrationService Task Deduplication Tests (E7)', () {
    test(
        'deduplicates tasks with duplicate IDs or same URL/fileName keeping the newer record',
        () async {
      final box =
          await Hive.openBox<dynamic>(HiveMigrationService.downloadsBoxName);

      final olderDate = DateTime(2025, 1, 1, 10, 0);
      final newerDate = DateTime(2025, 1, 1, 12, 0);

      // Task 1 (older version)
      final task1Old = {
        'id': 'task_1',
        'fileName': 'archive.zip',
        'url': 'https://example.com/archive.zip',
        'fileSize': 1000,
        'downloadedBytes': 100,
        'category': 'archive',
        'status': 'downloading',
        'savePath': '${tempDir.path}/archive.zip',
        'localFilePath': '${tempDir.path}/archive.zip',
        'tempFilePath': '${tempDir.path}/archive.zip.tmp',
        'threadCount': 2,
        'chunks': '[]',
        'createdAt': olderDate.toIso8601String(),
        'updatedAt': olderDate.toIso8601String(),
      };

      // Task 1 (newer version with same ID)
      final task1New = {
        'id': 'task_1',
        'fileName': 'archive.zip',
        'url': 'https://example.com/archive.zip',
        'fileSize': 1000,
        'downloadedBytes': 900,
        'category': 'archive',
        'status': 'completed',
        'savePath': '${tempDir.path}/archive.zip',
        'localFilePath': '${tempDir.path}/archive.zip',
        'tempFilePath': '${tempDir.path}/archive.zip.tmp',
        'threadCount': 2,
        'chunks': '[]',
        'createdAt': olderDate.toIso8601String(),
        'updatedAt': newerDate.toIso8601String(),
      };

      // Task 2 with distinct ID but same URL & filename (duplicate download attempt)
      final task2Duplicate = {
        'id': 'task_2_dup',
        'fileName': 'archive.zip',
        'url': 'https://example.com/archive.zip',
        'fileSize': 1000,
        'downloadedBytes': 50,
        'category': 'archive',
        'status': 'downloading',
        'savePath': '${tempDir.path}/archive.zip',
        'localFilePath': '${tempDir.path}/archive.zip',
        'tempFilePath': '${tempDir.path}/archive.zip.tmp',
        'threadCount': 2,
        'chunks': '[]',
        'createdAt': olderDate.toIso8601String(),
        'updatedAt': olderDate.toIso8601String(),
      };

      // Unique Task 3
      final task3 = {
        'id': 'task_3',
        'fileName': 'other.pdf',
        'url': 'https://example.com/other.pdf',
        'fileSize': 500,
        'downloadedBytes': 500,
        'category': 'document',
        'status': 'completed',
        'savePath': '${tempDir.path}/other.pdf',
        'localFilePath': '${tempDir.path}/other.pdf',
        'tempFilePath': '${tempDir.path}/other.pdf.tmp',
        'threadCount': 1,
        'chunks': '[]',
        'createdAt': newerDate.toIso8601String(),
        'updatedAt': newerDate.toIso8601String(),
      };

      await box.add(task1Old);
      await box.add(task1New);
      await box.add(task2Duplicate);
      await box.add(task3);
      await box.close();

      // Execute migration
      final success = await migrationService.migrateDownloadsBox();
      expect(success, isTrue);

      final migratedTasks = await db.select(db.downloadTasks).get();
      // Should contain exactly 2 tasks: task_1 (the newer completed one) and task_3
      expect(migratedTasks.length, equals(2));

      final migratedTask1 = migratedTasks.firstWhere((t) => t.id == 'task_1');
      expect(migratedTask1.downloadedBytes, equals(900));
      expect(migratedTask1.status, equals('completed'));

      final migratedTask3 = migratedTasks.firstWhere((t) => t.id == 'task_3');
      expect(migratedTask3.fileName, equals('other.pdf'));
    });
  });
}
