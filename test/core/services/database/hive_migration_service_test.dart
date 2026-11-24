import 'dart:io';

import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/hive_migration_service.dart';
import 'package:dmx/features/browser/models/bookmark.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late HiveMigrationService migrationService;
  late SharedPreferences prefs;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tempDir = await Directory.systemTemp.createTemp('hive_migration_test_');
    Hive.init(tempDir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (methodCall) async => tempDir.path,
    );
    db = AppDatabase.forTesting(NativeDatabase.memory());
    migrationService = HiveMigrationService(db, prefs);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await Hive.close();
    await db.close();
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('HiveMigrationService Interrupted Task Mapping (FIX-07)', () {
    test(
        '_taskToCompanion sets pauseReason = appRestarted and cycleState = paused for downloading resumable task',
        () {
      final task = DownloadTask(
        id: 'task-mig-1',
        fileName: 'file.zip',
        url: 'https://example.com/file.zip',
        fileSize: 10000,
        downloadedBytes: 5000,
        category: 'Archive',
        status: DownloadStatus.downloading,
        cycleState: CycleState.downloading,
        savePath: '/tmp/file.zip',
        localFilePath: '/tmp/file.zip',
        tempFilePath: '/tmp/file.zip.dmx',
        threadCount: 4,
        chunks: [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        supportsResume: true,
      );

      final companion = migrationService.taskToCompanionForTesting(task);

      expect(
          companion.pauseReason.value, equals(PauseReason.appRestarted.name));
      expect(companion.cycleState.value, equals(CycleState.paused.name));
      expect(companion.status.value, equals(DownloadStatus.paused.name));
    });
  });

  group('HiveMigrationService.migrate', () {
    test('marks migration complete when all boxes are absent', () async {
      await migrationService.migrate();
      expect(prefs.getBool(HiveMigrationService.migrationKey), isTrue);
    });

    test('skips when the completion flag is already set', () async {
      await prefs.setBool(HiveMigrationService.migrationKey, true);
      await migrationService.migrate();
      expect(prefs.getBool(HiveMigrationService.migrationKey), isTrue);
    });

    test('does not mark complete when a box fails to migrate', () async {
      await Directory('${tempDir.path}/migration_failed_bookmarks.json')
          .create(recursive: true);
      final box = await Hive.openBox<dynamic>(
        HiveMigrationService.bookmarksBoxName,
      );
      await box.add(42);
      await box.close();

      await migrationService.migrate();
      expect(prefs.getBool(HiveMigrationService.migrationKey), isNull);
    });
  });

  group('HiveMigrationService.migrateSingleHiveBox', () {
    test('unknown box names are treated as success', () async {
      expect(await migrationService.migrateSingleHiveBox('nope'), isTrue);
    });

    test('an absent box is treated as success', () async {
      expect(
        await migrationService.migrateSingleHiveBox(
          HiveMigrationService.downloadsBoxName,
        ),
        isTrue,
      );
    });
  });

  group('HiveMigrationService.migrateDownloadsBox', () {
    test('an empty box is deleted', () async {
      final box = await Hive.openBox<dynamic>(
        HiveMigrationService.downloadsBoxName,
      );
      await box.close();

      expect(await migrationService.migrateDownloadsBox(), isTrue);
      expect(
          await Hive.boxExists(HiveMigrationService.downloadsBoxName), isFalse);
    });

    test('deduplicates by id and by composite url+fileName', () async {
      final box = await Hive.openBox<dynamic>(
        HiveMigrationService.downloadsBoxName,
      );
      final older = DateTime(2025, 1, 1, 10);
      final newer = DateTime(2025, 1, 1, 12);

      Map<String, dynamic> task(String id, DateTime updated,
              {String url = 'u'}) =>
          {
            'id': id,
            'fileName': 'a.zip',
            'url': url,
            'fileSize': 100,
            'downloadedBytes': 0,
            'category': 'archive',
            'status': 'completed',
            'savePath': '/s',
            'localFilePath': '/s',
            'tempFilePath': '/s.tmp',
            'threadCount': 1,
            'chunks': '[]',
            'createdAt': older.toIso8601String(),
            'updatedAt': updated.toIso8601String(),
          };

      // Same id, the newer one wins.
      await box.add(task('same-id', older));
      await box.add(task('same-id', newer));
      // Distinct id, same url+fileName: the newer one wins.
      await box.add(task('other', older, url: 'same-url'));
      await box.add(task('other2', newer, url: 'same-url'));
      await box.close();

      expect(await migrationService.migrateDownloadsBox(), isTrue);
      final tasks = await db.select(db.downloadTasks).get();
      expect(tasks.length, 2);
      expect(tasks.firstWhere((t) => t.id == 'same-id').updatedAt,
          newer.millisecondsSinceEpoch);
    });

    test('migrates valid task maps', () async {
      final box = await Hive.openBox<dynamic>(
        HiveMigrationService.downloadsBoxName,
      );
      final now = DateTime(2025, 1, 1);
      await box.add({
        'id': 'task-1',
        'fileName': 'a.zip',
        'url': 'https://example.com/a.zip',
        'fileSize': 100,
        'downloadedBytes': 100,
        'category': 'archive',
        'status': 'completed',
        'savePath': '/s/a.zip',
        'localFilePath': '/s/a.zip',
        'tempFilePath': '/s/a.zip.tmp',
        'threadCount': 2,
        'chunks': '[]',
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
      });
      await box.close();

      expect(await migrationService.migrateDownloadsBox(), isTrue);
      final tasks = await db.select(db.downloadTasks).get();
      expect(tasks.length, 1);
      expect(tasks.single.id, 'task-1');
    });
  });

  group('HiveMigrationService.migrateBookmarksBox', () {
    test('migrates valid bookmark maps', () async {
      final box = await Hive.openBox<dynamic>(
        HiveMigrationService.bookmarksBoxName,
      );
      await box.add(
        Bookmark(
          id: 'bm-1',
          title: 'Example',
          url: 'https://example.com',
          folder: 'Work',
          createdAt: DateTime(2025, 1, 1),
        ).toMap(),
      );
      await box.close();

      expect(await migrationService.migrateBookmarksBox(), isTrue);
      final rows = await db.select(db.bookmarks).get();
      expect(rows.length, 1);
      expect(rows.single.id, 'bm-1');
    });

    test('empty box is deleted', () async {
      final box = await Hive.openBox<dynamic>(
        HiveMigrationService.bookmarksBoxName,
      );
      await box.close();
      expect(await migrationService.migrateBookmarksBox(), isTrue);
      expect(
        await Hive.boxExists(HiveMigrationService.bookmarksBoxName),
        isFalse,
      );
    });
  });

  group('HiveMigrationService.migrateBrowserTabsBox', () {
    test('migrates valid tab maps', () async {
      final box = await Hive.openBox<dynamic>(
        HiveMigrationService.browserTabsBoxName,
      );
      await box.put('tab-1', {
        'url': 'https://example.com',
        'title': 'Example',
        'isActive': true,
        'position': 1,
        'createdAt': 1000,
        'lastVisitedAt': 2000,
        'faviconUrl': 'https://example.com/fav.ico',
      });
      await box.close();

      expect(await migrationService.migrateBrowserTabsBox(), isTrue);
      final rows = await db.select(db.browserTabs).get();
      expect(rows.length, 1);
      expect(rows.single.id, 'tab-1');
      expect(rows.single.isActive, isTrue);
    });
  });

  group('HiveMigrationService.migrateBrowserHistoryBox', () {
    test('migrates and deduplicates history maps', () async {
      final box = await Hive.openBox<dynamic>(
        HiveMigrationService.browserHistoryBoxName,
      );
      await box.add(
          {'url': 'https://example.com', 'title': 'One', 'visitedAt': 1000});
      await box.add(
          {'url': 'https://example.com', 'title': 'Two', 'visitedAt': 2000});
      await box.close();

      expect(await migrationService.migrateBrowserHistoryBox(), isTrue);
      final rows = await db.select(db.browserHistory).get();
      expect(rows.length, 1);
      expect(rows.single.visitCount, 2);
    });
  });

  group('HiveMigrationService corrupt-item handling', () {
    test('exports corrupt items and deletes the box on success', () async {
      final box = await Hive.openBox<dynamic>(
        HiveMigrationService.bookmarksBoxName,
      );
      await box.add(42); // not a Map -> failed item
      await box.close();

      expect(await migrationService.migrateBookmarksBox(), isTrue);
      expect(
        await Hive.boxExists(HiveMigrationService.bookmarksBoxName),
        isFalse,
      );
      expect(
        File('${tempDir.path}/migration_failed_bookmarks.json').existsSync(),
        isTrue,
      );
    });

    test('preserves the box when the export fails', () async {
      // Occupy the export path with a directory so writeAsString fails.
      await Directory('${tempDir.path}/migration_failed_bookmarks.json')
          .create(recursive: true);

      final box = await Hive.openBox<dynamic>(
        HiveMigrationService.bookmarksBoxName,
      );
      await box.add(42);
      await box.close();

      expect(await migrationService.migrateBookmarksBox(), isFalse);
      expect(
        await Hive.boxExists(HiveMigrationService.bookmarksBoxName),
        isTrue,
      );
    });
  });

  group('HiveMigrationService file-backed migrate', () {
    test('runs the isolate migration path for a file-backed database',
        () async {
      final fileDb = AppDatabase('${tempDir.path}/file_migration.db');
      final fileService = HiveMigrationService(fileDb, prefs);
      await fileService.migrate();
      await fileDb.close();

      expect(prefs.getBool(HiveMigrationService.migrationKey), isTrue);
    });
  });
}
