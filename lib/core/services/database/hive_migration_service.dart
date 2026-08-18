import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../features/browser/models/bookmark.dart';
import '../../../features/downloads/models/download_task.dart';
import '../history_merger.dart';
import '../logging_service.dart';
import 'app_database.dart';
import 'repositories/task_companion_converter.dart';

final _log = LoggingService.logger('HiveMigrationService');

class _MigratePayload {
  final String? dbPath;
  final String? hivePath;
  final Map<String, Object> initialPrefs;

  _MigratePayload(
    AppDatabase db,
    SharedPreferences prefs, {
    String? hiveDirectoryPath,
  })  : dbPath = db.dbPath,
        hivePath = hiveDirectoryPath ??
            (db.dbPath != null ? File(db.dbPath!).parent.path : null),
        initialPrefs = {
          for (final key in prefs.getKeys())
            if (prefs.get(key) != null) key: prefs.get(key)!,
        };
}

Future<bool> _migrateIsolate(_MigratePayload payload) async {
  if (payload.hivePath != null && payload.hivePath!.isNotEmpty) {
    Hive.init(payload.hivePath!);
  }

  final AppDatabase isolateDb;
  if (payload.dbPath != null && payload.dbPath!.isNotEmpty) {
    isolateDb = AppDatabase(payload.dbPath!);
  } else {
    isolateDb = AppDatabase.forTesting(NativeDatabase.memory());
  }

  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues(payload.initialPrefs);
  final isolatePrefs = await SharedPreferences.getInstance();

  try {
    final service = HiveMigrationService._direct(isolateDb, isolatePrefs);
    const boxes = [
      HiveMigrationService.downloadsBoxName,
      HiveMigrationService.bookmarksBoxName,
      HiveMigrationService.browserTabsBoxName,
      HiveMigrationService.browserHistoryBoxName,
    ];

    bool allSuccessful = true;
    for (final boxName in boxes) {
      final success = await service.migrateSingleHiveBox(boxName);
      if (!success) {
        allSuccessful = false;
        _log.warning(
          'Migration had errors for box $boxName; will retry on next launch.',
        );
      }
    }
    return allSuccessful;
  } finally {
    await isolateDb.close();
  }
}

/// Service responsible for one-time migration of legacy Hive data boxes into SQLite (Drift).
class HiveMigrationService {
  final AppDatabase db;
  final SharedPreferences prefs;

  HiveMigrationService(this.db, this.prefs);

  HiveMigrationService._direct(this.db, this.prefs);

  static const String downloadsBoxName = 'downloads';
  static const String bookmarksBoxName = 'browser_bookmarks';
  static const String browserHistoryBoxName = 'browser_history';
  static const String browserTabsBoxName = 'browser_tabs';
  static const String migrationKey = 'hive_migration_complete';

  /// Migrates Hive boxes using a single global completion flag (DB-03).
  Future<void> migrate() async {
    if (prefs.getBool(migrationKey) == true) return;

    if (db.dbPath == null) {
      const boxes = [
        downloadsBoxName,
        bookmarksBoxName,
        browserTabsBoxName,
        browserHistoryBoxName,
      ];

      bool allSuccessful = true;
      for (final boxName in boxes) {
        final success = await migrateSingleHiveBox(boxName);
        if (!success) {
          allSuccessful = false;
          _log.warning(
            'Migration had errors for box $boxName; will retry on next launch.',
          );
        }
      }

      if (allSuccessful) {
        await prefs.setBool(migrationKey, true);
      }
      return;
    }

    final allSuccessful = await compute(
      _migrateIsolate,
      _MigratePayload(db, prefs),
    );

    if (allSuccessful) {
      await prefs.setBool(migrationKey, true);
    }
  }

  /// Migrates a single Hive box by name. Returns true on success.
  Future<bool> migrateSingleHiveBox(String boxName) async {
    try {
      switch (boxName) {
        case downloadsBoxName:
          return await migrateDownloadsBox();
        case bookmarksBoxName:
          return await migrateBookmarksBox();
        case browserTabsBoxName:
          return await migrateBrowserTabsBox();
        case browserHistoryBoxName:
          return await migrateBrowserHistoryBox();
        default:
          _log.warning('Unknown Hive box name for migration: $boxName');
          return true;
      }
    } catch (e, stackTrace) {
      _log.severe('Hive migration error for box $boxName', e, stackTrace);
      return false;
    }
  }

  Future<bool> migrateDownloadsBox() async {
    if (!await Hive.boxExists(downloadsBoxName)) return true;
    final box = await Hive.openBox<dynamic>(downloadsBoxName);
    if (box.isEmpty) {
      await _safeDeleteBox(box);
      return true;
    }

    final existingTasks = await db.select(db.downloadTasks).get();
    final existingTaskIds = existingTasks.map((t) => t.id).toSet();

    final tasks = <DownloadTasksCompanion>[];
    final parsedValues = <dynamic>[];
    final failedItems = <dynamic>[];
    final Map<String, DownloadTask> deduplicatedTasks = {};
    final Map<String, DownloadTask> byCompositeKey = {};

    for (final value in box.values) {
      if (value is Map) {
        try {
          final task = DownloadTask.fromMap(Map<String, dynamic>.from(value));
          if (!existingTaskIds.contains(task.id)) {
            final compositeKey = '${task.url}|${task.fileName}';

            // Check collision on task.id
            if (deduplicatedTasks.containsKey(task.id)) {
              final existing = deduplicatedTasks[task.id]!;
              if (task.updatedAt.isAfter(existing.updatedAt)) {
                final oldCompKey = '${existing.url}|${existing.fileName}';
                if (byCompositeKey[oldCompKey]?.id == existing.id) {
                  byCompositeKey.remove(oldCompKey);
                }
                deduplicatedTasks[task.id] = task;
                byCompositeKey[compositeKey] = task;
              }
            } else {
              // Check collision on composite URL + fileName (O(1))
              final existingWithKey = byCompositeKey[compositeKey];
              if (existingWithKey != null) {
                if (task.updatedAt.isAfter(existingWithKey.updatedAt)) {
                  deduplicatedTasks.remove(existingWithKey.id);
                  deduplicatedTasks[task.id] = task;
                  byCompositeKey[compositeKey] = task;
                }
              } else {
                deduplicatedTasks[task.id] = task;
                byCompositeKey[compositeKey] = task;
              }
            }
            parsedValues.add(value);
          }
        } catch (e) {
          failedItems.add(value);
        }
      } else {
        failedItems.add(value);
      }
    }

    for (final task in deduplicatedTasks.values) {
      tasks.add(_taskToCompanion(task));
    }

    if (tasks.isNotEmpty) {
      try {
        await db.batch(
          (batch) => batch.insertAll(
            db.downloadTasks,
            tasks,
            mode: drift.InsertMode.insertOrReplace,
          ),
        );
      } catch (e) {
        failedItems.addAll(parsedValues);
      }
    }
    if (failedItems.isNotEmpty) {
      _log.warning(
        '$downloadsBoxName: ${failedItems.length} corrupt '
        'item(s) skipped. ${tasks.length} item(s) migrated successfully.',
      );
      final exportOk = await _exportFailedItems(
        'migration_failed_downloads.json',
        failedItems,
      );
      if (!exportOk) {
        _log.severe(
          'Failed to export corrupt downloads. '
          'Preserving Hive box to prevent data loss.',
        );
        await _backupHiveBox(box, downloadsBoxName);
        return false;
      }
    }
    await _safeDeleteBox(box);
    return true;
  }

  Future<bool> migrateBookmarksBox() async {
    if (!await Hive.boxExists(bookmarksBoxName)) return true;
    final box = await Hive.openBox<dynamic>(bookmarksBoxName);
    if (box.isEmpty) {
      await _safeDeleteBox(box);
      return true;
    }

    final existingBms = await db.select(db.bookmarks).get();
    final existingBmIds = existingBms.map((b) => b.id).toSet();

    final bms = <BookmarksCompanion>[];
    final parsedValues = <dynamic>[];
    final failedItems = <dynamic>[];
    for (final value in box.values) {
      if (value is Map) {
        try {
          final bm = Bookmark.fromMap(Map<String, dynamic>.from(value));
          if (!existingBmIds.contains(bm.id)) {
            bms.add(_bookmarkToCompanion(bm));
            parsedValues.add(value);
          }
        } catch (e) {
          failedItems.add(value);
        }
      } else {
        failedItems.add(value);
      }
    }
    if (bms.isNotEmpty) {
      try {
        await db.batch(
          (batch) => batch.insertAll(
            db.bookmarks,
            bms,
            mode: drift.InsertMode.insertOrReplace,
          ),
        );
      } catch (e) {
        failedItems.addAll(parsedValues);
      }
    }
    if (failedItems.isNotEmpty) {
      _log.warning(
        '$bookmarksBoxName: ${failedItems.length} corrupt '
        'item(s) skipped. ${bms.length} item(s) migrated successfully.',
      );
      final exportOk = await _exportFailedItems(
        'migration_failed_bookmarks.json',
        failedItems,
      );
      if (!exportOk) {
        _log.severe(
          'Failed to export corrupt bookmarks. '
          'Preserving Hive box.',
        );
        await _backupHiveBox(box, bookmarksBoxName);
        return false;
      }
    }
    await _safeDeleteBox(box);
    return true;
  }

  Future<bool> migrateBrowserTabsBox() async {
    if (!await Hive.boxExists(browserTabsBoxName)) return true;
    final box = await Hive.openBox<dynamic>(browserTabsBoxName);
    if (box.isEmpty) {
      await _safeDeleteBox(box);
      return true;
    }

    final tabs = <SavedBrowserTab>[];
    final failedItems = <dynamic>[];
    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        try {
          tabs.add(
            SavedBrowserTab(
              id: key.toString(),
              url: val['url'] as String? ?? '',
              title: val['title'] as String? ?? '',
              isActive: val['isActive'] as bool? ?? false,
              position: val['position'] as int? ?? 0,
              createdAt: (val['createdAt'] as num?)?.toInt() ??
                  DateTime.now().millisecondsSinceEpoch,
              lastVisitedAt: val['lastVisitedAt'] as int? ??
                  DateTime.now().millisecondsSinceEpoch,
              faviconUrl: val['faviconUrl'] as String?,
            ),
          );
        } catch (e) {
          failedItems.add(val);
        }
      } else {
        failedItems.add(val);
      }
    }
    if (tabs.isNotEmpty) {
      try {
        await db.batch(
          (batch) => batch.insertAll(
            db.browserTabs,
            tabs,
            mode: drift.InsertMode.insertOrReplace,
          ),
        );
      } catch (e) {
        failedItems.addAll(box.values);
      }
    }
    if (failedItems.isNotEmpty) {
      _log.warning(
        '$browserTabsBoxName: ${failedItems.length} corrupt '
        'item(s) skipped. ${tabs.length} item(s) migrated successfully.',
      );
      final exportOk = await _exportFailedItems(
        'migration_failed_tabs.json',
        failedItems,
      );
      if (!exportOk) {
        _log.severe(
          'Failed to export corrupt tabs. '
          'Preserving Hive box.',
        );
        await _backupHiveBox(box, browserTabsBoxName);
        return false;
      }
    }
    await _safeDeleteBox(box);
    return true;
  }

  Future<bool> migrateBrowserHistoryBox() async {
    if (!await Hive.boxExists(browserHistoryBoxName)) return true;
    final box = await Hive.openBox<dynamic>(browserHistoryBoxName);
    if (box.isEmpty) {
      await _safeDeleteBox(box);
      return true;
    }

    final failedItems = <dynamic>[];
    final merged = mergeHistoryEntries(box.values);
    final mergedHistory = merged.merged;
    failedItems.addAll(merged.failed);

    final hist = mergedHistory
        .map(
          (item) => BrowserHistoryCompanion.insert(
            url: item.url,
            title: item.title,
            visitedAt: item.visitedAt,
            visitCount: drift.Value(item.visitCount),
            faviconUrl: drift.Value(item.faviconUrl),
          ),
        )
        .toList();
    if (hist.isNotEmpty) {
      try {
        await db.batch(
          (batch) => batch.insertAll(
            db.browserHistory,
            hist,
            mode: drift.InsertMode.insertOrReplace,
          ),
        );
      } catch (e) {
        failedItems.addAll(box.values);
      }
    }
    if (failedItems.isNotEmpty) {
      _log.warning(
        '$browserHistoryBoxName: ${failedItems.length} corrupt '
        'item(s) skipped. ${hist.length} item(s) migrated successfully.',
      );
      final exportOk = await _exportFailedItems(
        'migration_failed_history.json',
        failedItems,
      );
      if (!exportOk) {
        _log.severe(
          'Failed to export corrupt history. '
          'Preserving Hive box.',
        );
        await _backupHiveBox(box, browserHistoryBoxName);
        return false;
      }
    }
    await _safeDeleteBox(box);
    return true;
  }

  Future<void> _safeDeleteBox(Box<dynamic> box) async {
    try {
      await box.deleteFromDisk();
    } catch (e) {
      _log.info('deleteFromDisk safely handled: $e');
    }
  }

  Future<void> _backupHiveBox(Box<dynamic> box, String boxName) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final backupParentDir = Directory(p.join(dir.path, 'hive_backups'));
      if (!await backupParentDir.exists()) {
        await backupParentDir.create(recursive: true);
      }
      final backupPath = p.join(backupParentDir.path, '${boxName}_backup.hive');
      final String? boxPath = box.path;
      if (boxPath != null) {
        final srcFile = File(boxPath);
        final srcDir = Directory(boxPath);
        if (await srcFile.exists()) {
          final backupFile = File(backupPath);
          if (await backupFile.exists()) {
            await backupFile.delete();
          }
          await srcFile.copy(backupPath);
          _log.info('Backed up Hive box file $boxName to $backupPath');
        } else if (await srcDir.exists()) {
          final backupDir = Directory(backupPath);
          if (await backupDir.exists()) {
            await backupDir.delete(recursive: true);
          }
          await srcDir.rename(backupPath);
          _log.info('Backed up Hive box dir $boxName to $backupPath');
        }
      }
    } catch (e) {
      _log.severe('Failed to back up Hive box $boxName', e);
    }
  }

  Future<bool> _exportFailedItems(
    String fileName,
    List<dynamic> failedItems,
  ) async {
    if (failedItems.isEmpty) return true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, fileName));
      final payload = await compute(_buildExportPayload, failedItems);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      _log.info(
        'Exported ${failedItems.length} unmigrated item(s) to ${file.path}',
      );
      return true;
    } catch (e) {
      _log.severe('Failed to export unmigrated items to $fileName', e);
      return false;
    }
  }

  static Map<String, dynamic> _buildExportPayload(List<dynamic> failedItems) {
    return {
      'exportedAt': DateTime.now().toIso8601String(),
      'count': failedItems.length,
      'items': failedItems.map(_normalizeForJson).toList(),
    };
  }

  static Object? _normalizeForJson(Object? value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _normalizeForJson(v)));
    }
    if (value is Iterable) {
      return value.map(_normalizeForJson).toList();
    }
    return value.toString();
  }

  DownloadTasksCompanion _taskToCompanion(DownloadTask task) {
    final isInterrupted = task.status == DownloadStatus.downloading ||
        task.cycleState == CycleState.downloading ||
        task.cycleState == CycleState.starting ||
        task.cycleState == CycleState.resuming;
    final migratedTask = isInterrupted
        ? task.copyWith(
            status: DownloadStatus.paused,
            cycleState: CycleState.paused,
            pauseReason: PauseReason.appRestarted,
          )
        : task;
    return TaskCompanionConverter.taskToCompanion(migratedTask);
  }

  @visibleForTesting
  DownloadTasksCompanion taskToCompanionForTesting(DownloadTask task) =>
      _taskToCompanion(task);

  BookmarksCompanion _bookmarkToCompanion(Bookmark bm) {
    return BookmarksCompanion.insert(
      id: bm.id,
      title: bm.title,
      url: bm.url,
      folder: drift.Value(bm.folder),
      createdAt: bm.createdAt.millisecondsSinceEpoch,
    );
  }
}
