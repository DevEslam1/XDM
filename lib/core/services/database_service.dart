import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:drift/drift.dart' as drift;

import 'database/app_database.dart';
import '../../features/downloads/models/download_task.dart';
import '../../features/browser/models/bookmark.dart';

class DatabaseService {
  late final AppDatabase _db;

  // Hive constants for migration
  static const String downloadsBoxName = 'downloads';
  static const String bookmarksBoxName = 'browser_bookmarks';
  static const String browserHistoryBoxName = 'browser_history';

  Future<void> init() async {
    await Hive.initFlutter();
    _db = AppDatabase();
    await _migrateFromHive();
  }

  Future<void> _migrateFromHive() async {
    // Check if hive boxes exist, migrate, and delete
    try {
      if (await Hive.boxExists(downloadsBoxName)) {
        final box = await Hive.openBox<dynamic>(downloadsBoxName);
        if (box.isNotEmpty) {
          final tasks = <DownloadTasksCompanion>[];
          final failedItems = <dynamic>[];
          for (final value in box.values) {
            if (value is Map) {
              try {
                final task = DownloadTask.fromMap(Map<String, dynamic>.from(value));
                tasks.add(_taskToCompanion(task));
              } catch (e) {
                failedItems.add(value);
              }
            } else {
              failedItems.add(value);
            }
          }
          if (tasks.isNotEmpty) {
            try {
              await _db.batch((batch) => batch.insertAll(
                  _db.downloadTasks, tasks,
                  mode: drift.InsertMode.insertOrReplace));
            } catch (e) {
              failedItems.addAll(box.values);
            }
          }
          if (failedItems.isNotEmpty) {
            debugPrint('Migration of $downloadsBoxName had ${failedItems.length} failures.');
          }
          await box.deleteFromDisk();
        } else {
          await box.deleteFromDisk();
        }
      }

      if (await Hive.boxExists(bookmarksBoxName)) {
        final box = await Hive.openBox<dynamic>(bookmarksBoxName);
        if (box.isNotEmpty) {
          final bms = <BookmarksCompanion>[];
          final failedItems = <dynamic>[];
          for (final value in box.values) {
            if (value is Map) {
              try {
                final bm = Bookmark.fromMap(Map<String, dynamic>.from(value));
                bms.add(_bookmarkToCompanion(bm));
              } catch (e) {
                failedItems.add(value);
              }
            } else {
              failedItems.add(value);
            }
          }
          if (bms.isNotEmpty) {
            try {
              await _db.batch((batch) => batch.insertAll(
                  _db.bookmarks, bms,
                  mode: drift.InsertMode.insertOrReplace));
            } catch (e) {
              failedItems.addAll(box.values);
            }
          }
          if (failedItems.isNotEmpty) {
            debugPrint('Migration of $bookmarksBoxName had ${failedItems.length} failures.');
          }
          await box.deleteFromDisk();
        } else {
          await box.deleteFromDisk();
        }
      }

      if (await Hive.boxExists(browserHistoryBoxName)) {
        final box = await Hive.openBox<dynamic>(browserHistoryBoxName);
        if (box.isNotEmpty) {
          final hist = <BrowserHistoryCompanion>[];
          final failedItems = <dynamic>[];
          for (final key in box.keys) {
            final val = box.get(key);
            if (val is Map) {
              try {
                hist.add(BrowserHistoryCompanion.insert(
                  id: 'hive_${key.toString()}',
                  url: val['url'] as String? ?? '',
                  title: val['title'] as String? ?? val['url'] as String? ?? '',
                  visitedAt: val['visitedAt'] as String? ??
                      DateTime.now().toIso8601String(),
                ));
              } catch (e) {
                failedItems.add(val);
              }
            } else {
              failedItems.add(val);
            }
          }
          if (hist.isNotEmpty) {
            try {
              await _db.batch((batch) => batch.insertAll(
                  _db.browserHistory, hist,
                  mode: drift.InsertMode.insertOrReplace));
            } catch (e) {
              failedItems.addAll(box.values);
            }
          }
          if (failedItems.isNotEmpty) {
            debugPrint('Migration of $browserHistoryBoxName had ${failedItems.length} failures.');
          }
          await box.deleteFromDisk();
        } else {
          await box.deleteFromDisk();
        }
      }
    } catch (e) {
      debugPrint('Hive to Drift migration error: $e');
    }
  }

  DownloadTasksCompanion _taskToCompanion(DownloadTask task) {
    return DownloadTasksCompanion.insert(
      id: task.id,
      fileName: task.fileName,
      url: task.url,
      fileSize: drift.Value(task.fileSize),
      downloadedBytes: drift.Value(task.downloadedBytes),
      speed: drift.Value(task.speed),
      eta: drift.Value(task.eta),
      category: task.category,
      status: task.status.name,
      savePath: task.savePath,
      localFilePath: task.localFilePath,
      tempFilePath: task.tempFilePath,
      errorMessage: drift.Value(task.errorMessage),
      threadCount: task.threadCount,
      chunks: task.chunks,
      createdAt: task.createdAt.toIso8601String(),
      updatedAt: task.updatedAt.toIso8601String(),
      completedAt: drift.Value(task.completedAt?.toIso8601String()),
      scheduledAt: drift.Value(task.scheduledAt?.toIso8601String()),
      supportsResume: drift.Value(task.supportsResume),
      speedLimitKbps: drift.Value(task.speedLimitKbps),
      seedingEnabled: drift.Value(task.seedingEnabled),
      seedingLimited: drift.Value(task.seedingLimited),
      seedingLimitKbps: drift.Value(task.seedingLimitKbps),
      torrentFiles: drift.Value(task.torrentFiles),
      downloadPageUrl: drift.Value(task.downloadPageUrl),
      mergedAudioUrl: drift.Value(task.mergedAudioUrl),
      audioSize: drift.Value(task.audioSize),
      audioProgress: drift.Value(task.audioProgress),
      pausedByUser: drift.Value(task.pausedByUser),
      youtubeQualityPreset: drift.Value(task.youtubeQualityPreset),
    );
  }

  DownloadTask _rowToTask(DbDownloadTask row) {
    DateTime parseDate(String dateStr) {
      try {
        return DateTime.parse(dateStr);
      } catch (_) {
        return DateTime.now();
      }
    }

    DateTime? parseNullableDate(String? dateStr) {
      if (dateStr == null) return null;
      try {
        return DateTime.parse(dateStr);
      } catch (_) {
        return DateTime.now();
      }
    }

    final statusName = row.status;
    final status = DownloadStatus.values.firstWhere(
      (value) => value.name == statusName,
      orElse: () => DownloadStatus.paused,
    );

    return DownloadTask(
      id: row.id,
      fileName: row.fileName,
      url: row.url,
      fileSize: row.fileSize,
      downloadedBytes: row.downloadedBytes,
      speed: row.speed,
      eta: row.eta,
      category: row.category,
      status: status,
      savePath: row.savePath,
      localFilePath: row.localFilePath,
      tempFilePath: row.tempFilePath,
      errorMessage: row.errorMessage,
      threadCount: row.threadCount,
      chunks: row.chunks,
      createdAt: parseDate(row.createdAt),
      updatedAt: parseDate(row.updatedAt),
      completedAt: parseNullableDate(row.completedAt),
      scheduledAt: parseNullableDate(row.scheduledAt),
      supportsResume: row.supportsResume,
      speedLimitKbps: row.speedLimitKbps,
      seedingEnabled: row.seedingEnabled,
      seedingLimited: row.seedingLimited,
      seedingLimitKbps: row.seedingLimitKbps,
      torrentFiles: row.torrentFiles,
      downloadPageUrl: row.downloadPageUrl,
      mergedAudioUrl: row.mergedAudioUrl,
      audioSize: row.audioSize,
      audioProgress: row.audioProgress,
      pausedByUser: row.pausedByUser,
      youtubeQualityPreset: row.youtubeQualityPreset,
    );
  }

  Future<List<DownloadTask>> loadTasks() async {
    final rows = await (_db.select(_db.downloadTasks)
          ..orderBy([(t) => drift.OrderingTerm.desc(t.createdAt)]))
        .get();
    return rows.map(_rowToTask).toList();
  }

  Future<void> saveTask(DownloadTask task) {
    return _db.into(_db.downloadTasks).insert(_taskToCompanion(task),
        mode: drift.InsertMode.insertOrReplace);
  }

  Future<void> saveTasks(Iterable<DownloadTask> tasks) async {
    final comps = tasks.map(_taskToCompanion).toList();
    if (comps.isEmpty) return;
    await _db.batch((batch) => batch.insertAll(_db.downloadTasks, comps,
        mode: drift.InsertMode.insertOrReplace));
  }

  Future<void> deleteTask(String id) {
    return (_db.delete(_db.downloadTasks)..where((t) => t.id.equals(id))).go();
  }

  Future<void> clearAllTasks() {
    return _db.delete(_db.downloadTasks).go();
  }

  BookmarksCompanion _bookmarkToCompanion(Bookmark bm) {
    return BookmarksCompanion.insert(
      id: bm.id,
      title: bm.title,
      url: bm.url,
      folder: drift.Value(bm.folder),
      createdAt: bm.createdAt.toIso8601String(),
    );
  }

  Bookmark _rowToBookmark(DbBookmark row) {
    return Bookmark.fromMap({
      'id': row.id,
      'title': row.title,
      'url': row.url,
      'folder': row.folder,
      'createdAt': row.createdAt,
    });
  }

  Future<List<Bookmark>> loadBookmarks() async {
    final rows = await (_db.select(_db.bookmarks)
          ..orderBy([(t) => drift.OrderingTerm.desc(t.createdAt)]))
        .get();
    return rows.map(_rowToBookmark).toList();
  }

  Future<void> saveBookmark(Bookmark bookmark) {
    return _db.into(_db.bookmarks).insert(_bookmarkToCompanion(bookmark),
        mode: drift.InsertMode.insertOrReplace);
  }

  Future<void> deleteBookmark(String id) {
    return (_db.delete(_db.bookmarks)..where((t) => t.id.equals(id))).go();
  }

  Future<void> clearBookmarks() {
    return _db.delete(_db.bookmarks).go();
  }

  Future<List<Map<String, dynamic>>> loadBrowserHistory(
      {int max = 200}) async {
    final rows = await (_db.select(_db.browserHistory)
          ..orderBy([(t) => drift.OrderingTerm.desc(t.visitedAt)])
          ..limit(max))
        .get();

    return rows
        .map((r) => {
              'id': r.id,
              'url': r.url,
              'title': r.title,
              'visitedAt': r.visitedAt,
            })
        .toList();
  }

  Future<String> addBrowserHistory(Map<String, dynamic> entry) async {
    final url = entry['url'] as String? ?? '';
    if (url.isEmpty || url == 'about:blank') return '';
    final now = DateTime.now();
    final ts = now.millisecondsSinceEpoch;
    final us = now.microsecond;
    final id = '${ts}_${us}_${url.hashCode}';

    await _db.into(_db.browserHistory).insert(
        BrowserHistoryCompanion.insert(
          id: id,
          url: url,
          title: entry['title'] as String? ?? url,
          visitedAt: entry['visitedAt'] as String? ??
              DateTime.now().toIso8601String(),
        ),
        mode: drift.InsertMode.insertOrReplace);
    return id;
  }

  Future<void> updateBrowserHistoryTitle(String id, String title) async {
    await (_db.update(_db.browserHistory)..where((t) => t.id.equals(id)))
        .write(BrowserHistoryCompanion(title: drift.Value(title)));
  }

  Future<void> deleteBrowserHistory(String id) {
    return (_db.delete(_db.browserHistory)..where((t) => t.id.equals(id)))
        .go();
  }

  Future<void> clearBrowserHistory() {
    return _db.delete(_db.browserHistory).go();
  }
}
