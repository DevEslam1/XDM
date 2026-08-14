import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';

import 'database/app_database.dart';
import 'download_engine.dart';
import 'logging_service.dart';
import 'power_monitor.dart';
import '../../features/downloads/models/download_task.dart';
import '../../features/browser/models/bookmark.dart';
import '../../features/settings/provider/settings_provider.dart';

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

  late AppDatabase _db;
  bool _initialized = false;
  bool get isInitialized => _initialized;

  /// FIX(23): history is capped on *every* write (below), so the old
  /// "every Nth insert" counter — which reset on hot restart and let history
  /// grow unbounded — is removed.

  /// FIX(15): periodic WAL checkpoint + occasional VACUUM to keep the
  /// database file small and recovery fast.
  Timer? _maintenanceTimer;
  int _maintenanceRuns = 0;

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

    // FIX(15): periodic WAL checkpoint (TRUNCATE) keeps the -wal file small;
    // VACUUM reclaims freed pages every ~12 runs (approx 6h).
    _maintenanceTimer = Timer.periodic(const Duration(minutes: 30), (_) async {
      final swCheckpoint = Stopwatch()..start();
      try {
        await _db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
        await _db.customStatement('PRAGMA optimize');
        swCheckpoint.stop();
        if (swCheckpoint.elapsedMilliseconds > 500) {
          _log.info(
              'wal_checkpoint(TRUNCATE) took ${swCheckpoint.elapsedMilliseconds}ms');
        }
      } catch (e) {
        _log.warning('wal_checkpoint(TRUNCATE) failed', e);
      }

      _maintenanceRuns++;
      if (_maintenanceRuns % 12 == 0) {
        try {
          final activeCountResult = await _db
              .customSelect(
                "SELECT COUNT(*) as cnt FROM download_tasks WHERE status IN ('downloading', 'paused', 'queued', 'seeding')",
              )
              .get();
          final activeCount = activeCountResult.first.read<int>('cnt');
          if (activeCount > 0) {
            _log.info(
              'Skipping periodic DB incremental_vacuum because $activeCount active/paused/queued download(s) in progress',
            );
          } else {
            final swVacuum = Stopwatch()..start();
            await _db.customStatement('PRAGMA incremental_vacuum(50)');
            swVacuum.stop();
            if (swVacuum.elapsedMilliseconds > 500) {
              _log.info(
                  'incremental_vacuum took ${swVacuum.elapsedMilliseconds}ms');
            }
          }
        } catch (e) {
          _log.warning('incremental_vacuum failed', e);
        }
      }
    });
  }

  /// Migrates Hive boxes using a single global completion flag (DB-03).
  Future<void> _migrateFromHivePerBox(SharedPreferences prefs) async {
    const String migrationKey = 'hive_migration_complete';
    if (prefs.getBool(migrationKey) == true) return;

    const boxes = [
      downloadsBoxName,
      bookmarksBoxName,
      browserTabsBoxName,
      browserHistoryBoxName,
    ];

    bool allSuccessful = true;
    for (final boxName in boxes) {
      final success = await _migrateSingleHiveBox(boxName);
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
              // FIX-P4-28: Preserve original createdAt timestamp from Hive map if present
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

    final failedItems = <dynamic>[];
    // FIX-P4-29: Deduplicate Hive history items by URL before inserting into Drift
    final Map<String, _MergedHistoryItem> mergedHistory = {};

    for (final key in box.keys) {
      final val = box.get(key);
      if (val is Map) {
        try {
          final url = val['url'] as String? ?? '';
          if (url.isEmpty) continue;
          final title = val['title'] as String? ?? url;
          final visitedAt = (val['visitedAt'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch;
          final faviconUrl = val['faviconUrl'] as String?;

          final existing = mergedHistory[url];
          if (existing == null) {
            mergedHistory[url] = _MergedHistoryItem(
              url: url,
              title: title,
              visitedAt: visitedAt,
              visitCount: 1,
              faviconUrl: faviconUrl,
            );
          } else {
            existing.visitCount += 1;
            if (visitedAt > existing.visitedAt) {
              existing.visitedAt = visitedAt;
              existing.title = title;
            }
            if (faviconUrl != null) {
              existing.faviconUrl = faviconUrl;
            }
          }
        } catch (e) {
          failedItems.add(val);
        }
      } else {
        failedItems.add(val);
      }
    }

    final hist = mergedHistory.values
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
      final backupParentDir = Directory(p.join(dir.path, 'hive_backups'));
      if (!await backupParentDir.exists()) {
        await backupParentDir.create(recursive: true);
      }
      final backupPath = p.join(backupParentDir.path, '${boxName}_backup.hive');
      // Hive Box.path is String?
      final String? boxPath =
          box is Box ? box.path : (box as dynamic).path as String?;
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
      audioDownloadedBytes:
          drift.Value(task.audioDownloadedBytes), // FIX-AUDIT-01
      videoStreamSize: drift.Value(task.videoStreamSize), // FIX-B4
      audioProgress: drift.Value(task.audioProgress),
      pausedByUser: drift.Value(task.pausedByUser),
      youtubeQualityPreset: drift.Value(task.youtubeQualityPreset),
      notes: drift.Value(task.notes),
      playlistId: drift.Value(task.playlistId),
      playlistTitle: drift.Value(task.playlistTitle),
      thumbnailUrl: drift.Value(task.thumbnailUrl),
      isAppUpdate: drift.Value(task.isAppUpdate),
      uploadedBytes: drift.Value(task.uploadedBytes), // FIX F5
      priority: drift.Value(task.priority),
      expectedSha256: drift.Value(task.expectedSha256),
      mirrorUrls: drift.Value(task.mirrorUrls),
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
      audioDownloadedBytes: row.audioDownloadedBytes, // FIX-AUDIT-01
      videoStreamSize: row.videoStreamSize, // FIX-B4
      audioProgress: row.audioProgress,
      pausedByUser: row.pausedByUser,
      youtubeQualityPreset: row.youtubeQualityPreset,
      notes: row.notes,
      playlistId: row.playlistId?.isNotEmpty == true ? row.playlistId : null,
      playlistTitle:
          row.playlistTitle?.isNotEmpty == true ? row.playlistTitle : null,
      thumbnailUrl: row.thumbnailUrl,
      isAppUpdate: row.isAppUpdate,
      uploadedBytes: row.uploadedBytes, // FIX F5
      priority: row.priority,
      expectedSha256: row.expectedSha256,
      mirrorUrls: row.mirrorUrls,
    );
  }

  Future<List<DownloadTask>> loadTasks() async {
    final rows = await (_db.select(
      _db.downloadTasks,
    )..orderBy([(t) => drift.OrderingTerm.desc(t.createdAt)]))
        .get();
    return rows.map(_rowToTask).toList();
  }

  /// Paginated load of download tasks (DB-02).
  Future<List<DownloadTask>> loadTasksPage({
    int limit = 50,
    int offset = 0,
  }) async {
    final query = _db.select(_db.downloadTasks)
      ..orderBy([(t) => drift.OrderingTerm.desc(t.createdAt)])
      ..limit(limit, offset: offset);
    final rows = await query.get();
    return rows.map(_rowToTask).toList();
  }

  Future<DownloadTask?> getTask(String id) async {
    final query = _db.select(_db.downloadTasks)..where((t) => t.id.equals(id));
    final row = await query.getSingleOrNull();
    return row != null ? _rowToTask(row) : null;
  }

  final Map<String, DownloadTask> _pendingProgressSaves = {};
  Timer? _dbBatchTimer;

  Future<void> saveTaskDebounced(DownloadTask task) async {
    _pendingProgressSaves[task.id] = task;

    // FIX-M2: Higher threshold = fewer flushes (flush immediately if pending >= 20)
    if (_pendingProgressSaves.length >= 20) {
      await flushPendingSaves();
      return;
    }

    final isBackground = !DownloadEngine.appInForeground ||
        DownloadEngine.isInBackground ||
        PowerMonitor.screenOff;
    final interval = isBackground
        ? const Duration(seconds: 120) // BG-05: 120s in background (was 45s)
        : const Duration(seconds: 8); // 8s in foreground

    _dbBatchTimer ??= Timer(interval, flushPendingSaves);
  }

  void cancelPendingTimers() {
    _dbBatchTimer?.cancel();
    _dbBatchTimer = null;
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
  }

  Future<void> flushImmediately() => flushPendingSaves();

  Future<void> flushPendingSaves() async {
    _dbBatchTimer?.cancel();
    _dbBatchTimer = null;
    if (_pendingProgressSaves.isEmpty) return;
    final toSave = List<DownloadTask>.from(_pendingProgressSaves.values);
    _pendingProgressSaves.clear();
    await _db.transaction(() async {
      await saveTasks(toSave);
    });
  }

  Future<void> saveTask(DownloadTask task) async {
    _pendingProgressSaves.remove(task.id);
    int retries = 3;
    int attempt = 0;
    while (true) {
      try {
        await _db.into(_db.downloadTasks).insert(_taskToCompanion(task),
            mode: drift.InsertMode.insertOrReplace);
        return;
      } catch (e) {
        retries--;
        attempt++;
        if (retries <= 0) {
          rethrow;
        }
        final delayMs = 100 * (1 << (attempt - 1));
        _log.warning('saveTask failed, retrying in ${delayMs}ms... Error: $e');
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    }
  }

  Future<void> saveTasks(Iterable<DownloadTask> tasks) async {
    final comps = tasks.map(_taskToCompanion).toList();
    if (comps.isEmpty) return;
    await _db.transaction(() async {
      await _db.batch(
        (batch) => batch.insertAll(
          _db.downloadTasks,
          comps,
          mode: drift.InsertMode.insertOrReplace,
        ),
      );
    });
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
      createdAt: bm.createdAt.millisecondsSinceEpoch,
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

  Future<List<Bookmark>> loadBookmarks({String? searchQuery}) async {
    final query = _db.select(_db.bookmarks);
    if (searchQuery != null && searchQuery.trim().isNotEmpty) {
      final term = '%${searchQuery.trim().toLowerCase()}%';
      query.where((t) =>
          t.title.lower().like(term) |
          t.url.lower().like(term) |
          t.folder.lower().like(term));
    }
    final rows = await (query
          ..orderBy([(t) => drift.OrderingTerm.desc(t.createdAt)]))
        .get();
    return rows.map(_rowToBookmark).toList();
  }

  Future<List<Bookmark>> searchBookmarks(String query, {int limit = 3}) async {
    if (query.trim().isEmpty) return [];
    final term = '%${query.trim().toLowerCase()}%';
    final q = _db.select(_db.bookmarks)
      ..where((t) => t.title.lower().like(term) | t.url.lower().like(term))
      ..limit(limit);
    final rows = await q.get();
    return rows.map(_rowToBookmark).toList();
  }

  Future<void> saveBookmark(Bookmark bookmark) async {
    // FIX: Prevent duplicate bookmarks by checking if a bookmark with the
    // same URL already exists. Updates the existing entry instead of creating
    // a duplicate.
    final existing = await (_db.select(_db.bookmarks)
          ..where((t) => t.url.equals(bookmark.url))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) {
      await (_db.update(_db.bookmarks)..where((t) => t.id.equals(existing.id)))
          .write(BookmarksCompanion(
        title: drift.Value(bookmark.title),
        url: drift.Value(bookmark.url),
        folder: drift.Value(bookmark.folder),
        // FIX-BM-02: Preserve original createdAt — re-saving should not
        // reset the bookmark's creation date or break ordering.
        createdAt: drift.Value(existing.createdAt),
      ));
      return;
    }
    await _db.into(_db.bookmarks).insert(
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

  Future<List<Map<String, dynamic>>> loadBrowserHistory({
    int? max,
    String? searchQuery,
  }) async {
    // FIX: Default to SettingsProvider.instance.historyMaxEntries so the
    // load limit matches the cap enforced in addBrowserHistory. Previously
    // this defaulted to 200 while the cap could be set higher by the user,
    // causing entries to be invisible in the UI even though they existed
    // in the database.
    int effectiveMax;
    try {
      await SettingsProvider.instance.ensureLoaded();
      effectiveMax = max ?? SettingsProvider.instance.historyMaxEntries;
    } catch (_) {
      effectiveMax = max ?? 500; // safe default
    }
    final query = _db.select(_db.browserHistory)
      ..orderBy([(t) => drift.OrderingTerm.desc(t.visitedAt)])
      ..limit(effectiveMax);

    if (searchQuery != null && searchQuery.trim().isNotEmpty) {
      final term = searchQuery.trim();
      query.where((t) => t.url.contains(term) | t.title.contains(term));
    }

    final rows = await query.get();

    return rows
        .map(
          (r) => {
            'id': r.id,
            'url': r.url,
            'title': r.title,
            'visitedAt': r.visitedAt,
            'visitCount': r.visitCount,
            'faviconUrl': r.faviconUrl,
          },
        )
        .toList();
  }

  /// FIX-BH-07: Clear browser history older than [before].
  /// If [before] is null, clears all history.
  Future<void> clearBrowserHistoryBefore(DateTime? before) async {
    if (before == null) {
      await clearBrowserHistory();
      return;
    }
    await (_db.delete(_db.browserHistory)
          ..where((t) =>
              t.visitedAt.isSmallerThanValue(before.millisecondsSinceEpoch)))
        .go();
  }

  /// FIX-BH-08: Get total visit count for a specific URL.
  Future<int> getVisitCount(String url) async {
    final rows = await (_db.select(_db.browserHistory)
          ..where((t) => t.url.equals(url)))
        .get();
    return rows.fold<int>(0, (sum, r) => sum + r.visitCount);
  }

  final Map<String, Timer> _historyDebounceTimers = {};
  final Map<String, Map<String, dynamic>> _pendingHistoryEntries = {};

  /// Adds browser history with a 5-second per-URL write debounce (DB-04).
  Future<int> addBrowserHistory(
    Map<String, dynamic> entry, {
    bool immediate = false,
  }) async {
    final url = entry['url'] as String? ?? '';
    if (url.isEmpty || url == 'about:blank') return 0;

    if (immediate) {
      return _writeBrowserHistoryDirect(entry);
    }

    _pendingHistoryEntries[url] = entry;
    _historyDebounceTimers[url]?.cancel();

    _historyDebounceTimers[url] = Timer(const Duration(seconds: 5), () async {
      _historyDebounceTimers.remove(url);
      final latestEntry = _pendingHistoryEntries.remove(url);
      if (latestEntry != null) {
        await _writeBrowserHistoryDirect(latestEntry);
      }
    });

    return 1;
  }

  Future<int> _writeBrowserHistoryDirect(Map<String, dynamic> entry) async {
    final url = entry['url'] as String? ?? '';
    if (url.isEmpty || url == 'about:blank') return 0;
    final visitedAt = (entry['visitedAt'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final title = entry['title'] as String? ?? url;
    final faviconUrl = entry['faviconUrl'] as String?;

    // FIX-BH-04 + FIX-RACE: Deduplicate by URL using a transaction with
    // a re-check inside the transaction to eliminate the race condition
    // where two concurrent writes both find no existing row and both insert.
    final id = await _db.transaction(() async {
      final existing = await (_db.select(_db.browserHistory)
            ..where((t) => t.url.equals(url))
            ..orderBy([(t) => drift.OrderingTerm.desc(t.visitedAt)])
            ..limit(1))
          .getSingleOrNull();

      if (existing != null) {
        await (_db.update(_db.browserHistory)
              ..where((t) => t.id.equals(existing.id)))
            .write(BrowserHistoryCompanion(
          title: drift.Value(title),
          visitedAt: drift.Value(visitedAt),
          visitCount: drift.Value(existing.visitCount + 1),
          faviconUrl: drift.Value(faviconUrl ?? existing.faviconUrl),
        ));
        return existing.id;
      } else {
        return await _db.into(_db.browserHistory).insert(
              BrowserHistoryCompanion.insert(
                url: url,
                title: title,
                visitedAt: visitedAt,
                visitCount: const drift.Value(1),
                faviconUrl: drift.Value(faviconUrl),
              ),
            );
      }
    });

    int maxHistory;
    try {
      await SettingsProvider.instance.ensureLoaded();
      maxHistory = SettingsProvider.instance.historyMaxEntries;
    } catch (_) {
      maxHistory = 500;
    }
    final countResult = await _db
        .customSelect(
          'SELECT COUNT(*) as cnt FROM browser_history',
        )
        .get();
    final count = countResult.first.read<int>('cnt');
    if (count > maxHistory) {
      await _db.customStatement(
        'DELETE FROM browser_history WHERE id NOT IN ('
        '  SELECT id FROM browser_history '
        '  ORDER BY visited_at DESC '
        '  LIMIT ?'
        ')',
        [maxHistory],
      );
    }

    return id;
  }

  Future<void> updateBrowserHistoryTitle(int id, String title) async {
    await (_db.update(_db.browserHistory)..where((t) => t.id.equals(id))).write(
      BrowserHistoryCompanion(title: drift.Value(title)),
    );
  }

  Future<void> updateBrowserHistoryTime(int id, int visitedAt) async {
    // FIX-BH-09: Also increment visit_count when updating visit time,
    // since this is called when a page is re-visited. Uses raw SQL to
    // avoid an extra SELECT round-trip.
    await _db.customStatement(
      'UPDATE browser_history SET visited_at = ?, visit_count = visit_count + 1 WHERE id = ?',
      [visitedAt, id],
    );
  }

  Future<void> deleteBrowserHistory(int id) {
    return (_db.delete(_db.browserHistory)..where((t) => t.id.equals(id))).go();
  }

  Future<void> clearBrowserHistory() {
    return _db.delete(_db.browserHistory).go();
  }

  Future<void> saveOpenTabs(List<SavedBrowserTab> tabs) async {
    // FIX-BT-05: Use batch insert instead of per-tab individual inserts
    // for better performance (single transaction, single write).
    await _db.transaction(() async {
      await _db.delete(_db.browserTabs).go();
      if (tabs.isEmpty) return;
      await _db.batch((batch) {
        batch.insertAll(_db.browserTabs, tabs);
      });
    });
  }

  Future<List<SavedBrowserTab>> loadAndClearOpenTabs() async {
    // FIX-BT-04: Actually clear tabs after loading so they don't duplicate
    // on next app launch. The previous implementation was a no-op that
    // left all tabs in the DB, causing stale duplicates on restore.
    final tabs = await loadOpenTabs();
    await clearOpenTabs();
    return tabs;
  }

  Future<List<SavedBrowserTab>> loadOpenTabs() {
    return (_db.select(
      _db.browserTabs,
    )..orderBy([(t) => drift.OrderingTerm.asc(t.position)]))
        .get();
  }

  Future<void> clearOpenTabs() => _db.delete(_db.browserTabs).go();

  Future<void> dispose() async {
    // FIX-M2: Force flush on dispose
    await flushPendingSaves();
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    await _db.close();
  }
}

class _MergedHistoryItem {
  final String url;
  String title;
  int visitedAt;
  int visitCount;
  String? faviconUrl;

  _MergedHistoryItem({
    required this.url,
    required this.title,
    required this.visitedAt,
    required this.visitCount,
    this.faviconUrl,
  });
}
