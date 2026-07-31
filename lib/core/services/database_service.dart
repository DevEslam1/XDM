import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';

import 'database/app_database.dart';
import 'logging_service.dart';
import '../../features/downloads/models/download_task.dart';
import '../../features/browser/models/bookmark.dart';

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DatabaseService {
  /// Shared singleton instance.
  static final DatabaseService instance = DatabaseService._create();

  /// Returns the shared singleton instance.
  factory DatabaseService() => instance;

  static final _log = LoggingService.logger('DatabaseService');

  /// Constructor for subclasses (e.g., test fakes).
  /// Does NOT initialize _db — call [init] first.
  DatabaseService.forSubclass();

  DatabaseService._create();

  late final AppDatabase _db;
  bool _initialized = false;
  bool get isInitialized => _initialized;

  int _historyInsertCount = 0;
  static const int _historyTrimInterval = 100;

  // Hive constants for migration
  static const String downloadsBoxName = 'downloads';
  static const String bookmarksBoxName = 'browser_bookmarks';
  static const String browserHistoryBoxName = 'browser_history';
  static const String browserTabsBoxName = 'browser_tabs';

  Future<void> init({String? testPath}) async {
    if (testPath != null) {
      Hive.init(testPath);
      _db = AppDatabase.forTesting(NativeDatabase.memory());
    } else {
      await Hive.initFlutter();
      bool isPortable = false;
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final exePath = Platform.resolvedExecutable;
        final exeDir = File(exePath).parent.path;
        if (File(p.join(exeDir, '.portable')).existsSync()) {
          isPortable = true;
        }
      }

      late String dbPath;
      if (isPortable) {
        final exePath = Platform.resolvedExecutable;
        final exeDir = File(exePath).parent.path;
        dbPath = p.join(exeDir, 'dmx_app.sqlite');
      } else {
        final dbFolder = await getApplicationDocumentsDirectory();
        dbPath = p.join(dbFolder.path, 'dmx_app.sqlite');
      }
      _db = AppDatabase(dbPath);
    }

    final prefs = await SharedPreferences.getInstance();
    await _migrateFromHivePerBox(prefs);
    _initialized = true;
  }

  /// Migrates each Hive box independently, tracking success per-box via
  /// individual SharedPreferences keys so that a partial failure + retry
  /// does not re-migrate already-migrated boxes (which would cause
  /// duplicates via insertOrReplace).
  Future<void> _migrateFromHivePerBox(SharedPreferences prefs) async {
    const boxKeys = {
      downloadsBoxName: 'hive_migrated_downloads',
      bookmarksBoxName: 'hive_migrated_bookmarks',
      browserTabsBoxName: 'hive_migrated_tabs',
      browserHistoryBoxName: 'hive_migrated_history',
    };

    for (final entry in boxKeys.entries) {
      final boxName = entry.key;
      final prefKey = entry.value;
      if (prefs.getBool(prefKey) == true) continue;

      final success = await _migrateSingleHiveBox(boxName);
      if (success) {
        await prefs.setBool(prefKey, true);
      } else {
        _log.warning('Migration failed for box $boxName; will retry next run.');
      }
    }
  }

  /// Migrates a single Hive box by name. Returns true on success.
  Future<bool> _migrateSingleHiveBox(String boxName) async {
    try {
      switch (boxName) {
        case downloadsBoxName:
          return await _migrateDownloadsBox();
        case bookmarksBoxName:
          return await _migrateBookmarksBox();
        case browserTabsBoxName:
          return await _migrateBrowserTabsBox();
        case browserHistoryBoxName:
          return await _migrateBrowserHistoryBox();
        default:
          _log.warning('Unknown Hive box name for migration: $boxName');
          return true;
      }
    } catch (e, stackTrace) {
      _log.severe('Hive migration error for box $boxName', e, stackTrace);
      return false;
    }
  }

  Future<bool> _migrateDownloadsBox() async {
    if (!await Hive.boxExists(downloadsBoxName)) return true;
    final box = await Hive.openBox<dynamic>(downloadsBoxName);
    if (box.isEmpty) {
      box.deleteFromDisk();
      return true;
    }

    final existingTasks = await _db.select(_db.downloadTasks).get();
    final existingTaskIds = existingTasks.map((t) => t.id).toSet();

    final tasks = <DownloadTasksCompanion>[];
    final parsedValues = <dynamic>[];
    final failedItems = <dynamic>[];
    for (final value in box.values) {
      if (value is Map) {
        try {
          final task = DownloadTask.fromMap(Map<String, dynamic>.from(value));
          if (!existingTaskIds.contains(task.id)) {
            tasks.add(_taskToCompanion(task));
            parsedValues.add(value);
          }
        } catch (e) {
          failedItems.add(value);
        }
      } else {
        failedItems.add(value);
      }
    }
    if (tasks.isNotEmpty) {
      try {
        await _db.batch(
          (batch) => batch.insertAll(
            _db.downloadTasks,
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
    box.deleteFromDisk();
    return true;
  }

  Future<bool> _migrateBookmarksBox() async {
    if (!await Hive.boxExists(bookmarksBoxName)) return true;
    final box = await Hive.openBox<dynamic>(bookmarksBoxName);
    if (box.isEmpty) {
      box.deleteFromDisk();
      return true;
    }

    final existingBms = await _db.select(_db.bookmarks).get();
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
        await _db.batch(
          (batch) => batch.insertAll(
            _db.bookmarks,
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
    box.deleteFromDisk();
    return true;
  }

  Future<bool> _migrateBrowserTabsBox() async {
    if (!await Hive.boxExists(browserTabsBoxName)) return true;
    final box = await Hive.openBox<dynamic>(browserTabsBoxName);
    if (box.isEmpty) {
      box.deleteFromDisk();
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
              createdAt: DateTime.now().millisecondsSinceEpoch,
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
        await _db.batch(
          (batch) => batch.insertAll(
            _db.browserTabs,
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
    box.deleteFromDisk();
    return true;
  }

  Future<bool> _migrateBrowserHistoryBox() async {
    if (!await Hive.boxExists(browserHistoryBoxName)) return true;
    final box = await Hive.openBox<dynamic>(browserHistoryBoxName);
    if (box.isEmpty) {
      box.deleteFromDisk();
      return true;
    }

    final hist = <BrowserHistoryCompanion>[];
    final failedItems = <dynamic>[];
    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        try {
          hist.add(
            BrowserHistoryCompanion.insert(
              url: val['url'] as String? ?? '',
              title: val['title'] as String? ?? val['url'] as String? ?? '',
              visitedAt:
                  val['visitedAt'] as String? ??
                  DateTime.now().toIso8601String(),
            ),
          );
        } catch (e) {
          failedItems.add(val);
        }
      } else {
        failedItems.add(val);
      }
    }
    if (hist.isNotEmpty) {
      try {
        await _db.batch(
          (batch) => batch.insertAll(
            _db.browserHistory,
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
    box.deleteFromDisk();
    return true;
  }

  /// Backs up a Hive box to a safe location instead of deleting it.
  /// `box` is a Hive Box instance.
  Future<void> _backupHiveBox(dynamic box, String boxName) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final backupDir = Directory(p.join(dir.path, 'hive_backups'));
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }
      final backupPath = p.join(backupDir.path, '${boxName}_backup.hive');
      // Hive Box.path is String?
      final String? boxPath = box is Box
          ? box.path
          : (box as dynamic).path as String?;
      if (boxPath != null) {
        final srcDir = Directory(boxPath);
        if (await srcDir.exists()) {
          final backupFile = File(backupPath);
          if (await backupFile.exists()) {
            await backupFile.delete();
          }
          await srcDir.rename(backupPath);
          _log.info('Backed up Hive box $boxName to $backupPath');
        }
      }
    } catch (e) {
      _log.severe('Failed to back up Hive box $boxName', e);
    }
  }

  /// Writes [failedItems] that could not be migrated to a JSON file named
  /// [fileName] in the application documents directory, so the user can
  /// manually recover data that would otherwise be lost when the Hive box is
  /// deleted. Returns true if export succeeded, false otherwise.
  Future<bool> _exportFailedItems(
    String fileName,
    List<dynamic> failedItems,
  ) async {
    if (failedItems.isEmpty) return true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, fileName));
      final payload = <String, dynamic>{
        'exportedAt': DateTime.now().toIso8601String(),
        'count': failedItems.length,
        'items': failedItems.map(_normalizeForJson).toList(),
      };
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

  /// Recursively converts [value] into a JSON-encodable structure. Hive maps
  /// use dynamic keys and may contain non-encodable values, so keys are
  /// stringified and unknown leaf types fall back to their `toString()`.
  Object? _normalizeForJson(Object? value) {
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
      chunks: drift.Value(task.chunks),
      createdAt: task.createdAt.millisecondsSinceEpoch,
      updatedAt: task.updatedAt.millisecondsSinceEpoch,
      completedAt: drift.Value(task.completedAt?.millisecondsSinceEpoch),
      scheduledAt: drift.Value(task.scheduledAt?.millisecondsSinceEpoch),
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
      notes: drift.Value(task.notes),
      playlistId: drift.Value(task.playlistId),
      playlistTitle: drift.Value(task.playlistTitle),
      thumbnailUrl: drift.Value(task.thumbnailUrl),
      isAppUpdate: drift.Value(task.isAppUpdate),
      priority: drift.Value(task.priority),
      expectedSha256: drift.Value(task.expectedSha256),
    );
  }

  DownloadTask _rowToTask(DbDownloadTask row) {
    DateTime parseIntDate(int msSinceEpoch) {
      try {
        return DateTime.fromMillisecondsSinceEpoch(msSinceEpoch);
      } catch (e) {
        debugPrint(
          '[DMX] Error parsing date millisecondsSinceEpoch $msSinceEpoch: $e',
        );
        return DateTime.fromMillisecondsSinceEpoch(0);
      }
    }

    DateTime? parseNullableIntDate(int? msSinceEpoch) {
      if (msSinceEpoch == null) return null;
      try {
        return DateTime.fromMillisecondsSinceEpoch(msSinceEpoch);
      } catch (e) {
        debugPrint(
          '[DMX] Error parsing nullable date millisecondsSinceEpoch $msSinceEpoch: $e',
        );
        return null;
      }
    }

    final statusName = row.status;
    final status = DownloadStatus.values.firstWhere(
      (value) => value.name == statusName,
      orElse: () {
        debugPrint(
          '[DMX] _rowToTask: unrecognised status "$statusName" for task '
          '${row.id} — defaulting to paused.',
        );
        return DownloadStatus.paused;
      },
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
      chunks: row.chunks ?? [],
      createdAt: parseIntDate(row.createdAt),
      updatedAt: parseIntDate(row.updatedAt),
      completedAt: parseNullableIntDate(row.completedAt),
      scheduledAt: parseNullableIntDate(row.scheduledAt),
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
      notes: row.notes,
      playlistId: row.playlistId?.isNotEmpty == true ? row.playlistId : null,
      playlistTitle: row.playlistTitle?.isNotEmpty == true
          ? row.playlistTitle
          : null,
      thumbnailUrl: row.thumbnailUrl,
      isAppUpdate: row.isAppUpdate,
      priority: row.priority,
      expectedSha256: row.expectedSha256,
    );
  }

  Future<List<DownloadTask>> loadTasks() async {
    final rows = await (_db.select(
      _db.downloadTasks,
    )..orderBy([(t) => drift.OrderingTerm.desc(t.createdAt)])).get();
    return rows.map(_rowToTask).toList();
  }

  Future<DownloadTask?> getTask(String id) async {
    final query = _db.select(_db.downloadTasks)..where((t) => t.id.equals(id));
    final row = await query.getSingleOrNull();
    return row != null ? _rowToTask(row) : null;
  }

  Future<void> saveTask(DownloadTask task) {
    return _db
        .into(_db.downloadTasks)
        .insert(_taskToCompanion(task), mode: drift.InsertMode.insertOrReplace);
  }

  Future<void> saveTasks(Iterable<DownloadTask> tasks) async {
    final comps = tasks.map(_taskToCompanion).toList();
    if (comps.isEmpty) return;
    await _db.batch(
      (batch) => batch.insertAll(
        _db.downloadTasks,
        comps,
        mode: drift.InsertMode.insertOrReplace,
      ),
    );
  }

  Future<void> deleteTask(String id) {
    return (_db.delete(_db.downloadTasks)..where((t) => t.id.equals(id))).go();
  }

  Future<void> deleteTasks(Iterable<String> ids) {
    if (ids.isEmpty) return Future.value();
    return (_db.delete(_db.downloadTasks)..where((t) => t.id.isIn(ids))).go();
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
    final rows = await (_db.select(
      _db.bookmarks,
    )..orderBy([(t) => drift.OrderingTerm.desc(t.createdAt)])).get();
    return rows.map(_rowToBookmark).toList();
  }

  Future<void> saveBookmark(Bookmark bookmark) {
    return _db
        .into(_db.bookmarks)
        .insert(
          _bookmarkToCompanion(bookmark),
          mode: drift.InsertMode.insertOrReplace,
        );
  }

  Future<void> deleteBookmark(String id) {
    return (_db.delete(_db.bookmarks)..where((t) => t.id.equals(id))).go();
  }

  Future<void> clearBookmarks() {
    return _db.delete(_db.bookmarks).go();
  }

  Future<List<Map<String, dynamic>>> loadBrowserHistory({int max = 200}) async {
    final rows =
        await (_db.select(_db.browserHistory)
              ..orderBy([(t) => drift.OrderingTerm.desc(t.visitedAt)])
              ..limit(max))
            .get();

    return rows
        .map(
          (r) => {
            'id': r.id,
            'url': r.url,
            'title': r.title,
            'visitedAt': r.visitedAt,
          },
        )
        .toList();
  }

  Future<int> addBrowserHistory(Map<String, dynamic> entry) async {
    final url = entry['url'] as String? ?? '';
    if (url.isEmpty || url == 'about:blank') return 0;
    final visitedAt =
        entry['visitedAt'] as String? ?? DateTime.now().toIso8601String();
    final title = entry['title'] as String? ?? url;

    final id = await _db
        .into(_db.browserHistory)
        .insert(
          BrowserHistoryCompanion.insert(
            url: url,
            title: title,
            visitedAt: visitedAt,
          ),
        );

    _historyInsertCount++;
    if (_historyInsertCount >= _historyTrimInterval) {
      _historyInsertCount = 0;
      await _db.customStatement(
        'DELETE FROM browser_history WHERE id IN ('
        '  SELECT id FROM browser_history '
        '  ORDER BY visited_at DESC '
        '  LIMIT -1 OFFSET 500'
        ')',
      );
    }

    return id;
  }

  Future<void> updateBrowserHistoryTitle(int id, String title) async {
    await (_db.update(_db.browserHistory)..where((t) => t.id.equals(id))).write(
      BrowserHistoryCompanion(title: drift.Value(title)),
    );
  }

  Future<void> deleteBrowserHistory(int id) {
    return (_db.delete(_db.browserHistory)..where((t) => t.id.equals(id))).go();
  }

  Future<void> clearBrowserHistory() {
    return _db.delete(_db.browserHistory).go();
  }

  Future<void> saveOpenTabs(List<SavedBrowserTab> tabs) async {
    await _db.transaction(() async {
      await _db.delete(_db.browserTabs).go();
      for (final t in tabs) {
        await _db.into(_db.browserTabs).insert(t);
      }
    });
  }

  Future<List<SavedBrowserTab>> loadOpenTabs() {
    return (_db.select(
      _db.browserTabs,
    )..orderBy([(t) => drift.OrderingTerm.asc(t.position)])).get();
  }

  Future<void> clearOpenTabs() => _db.delete(_db.browserTabs).go();

  Future<void> dispose() async {
    await _db.close();
  }
}
