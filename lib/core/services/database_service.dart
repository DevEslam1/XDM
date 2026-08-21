import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

import '../../features/browser/models/bookmark.dart';
import '../../features/downloads/models/download_task.dart';
import 'database/app_database.dart';
import 'database/hive_migration_service.dart';
import 'database/repositories/bookmark_repository.dart';
import 'database/repositories/browser_history_repository.dart';
import 'database/repositories/browser_tab_repository.dart';
import 'database/repositories/task_companion_converter.dart';
import 'database/services/database_maintenance_service.dart';
import 'download_engine.dart';
import 'logging_service.dart';
import 'power_monitor.dart';

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
  AppDatabase get db => _db;

  late BookmarkRepository _bookmarkRepo;
  late BrowserHistoryRepository _historyRepo;
  late BrowserTabRepository _tabRepo;
  late DatabaseMaintenanceService _maintenanceService;

  BookmarkRepository get bookmarks => _bookmarkRepo;
  BrowserHistoryRepository get history => _historyRepo;
  BrowserTabRepository get tabs => _tabRepo;
  DatabaseMaintenanceService get maintenance => _maintenanceService;

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

    _bookmarkRepo = BookmarkRepository(_db);
    _historyRepo = BrowserHistoryRepository(_db);
    _tabRepo = BrowserTabRepository(_db);
    _maintenanceService = DatabaseMaintenanceService(_db);

    final prefs = await SharedPreferences.getInstance();
    await HiveMigrationService(_db, prefs).migrate();
    _initialized = true;

    _db.startPeriodicWalCheckpointer();
    _maintenanceService.start();
  }

  /// Trigger a WAL checkpoint to truncate or merge the WAL file back to disk.
  Future<int> checkpointWal({bool truncate = true}) =>
      _db.checkpointWal(truncate: truncate);

  /// Performs a connection pool health check.
  Future<bool> cleanupStaleConnections() =>
      _db.cleanupStaleConnections();

  @visibleForTesting
  int get maintenanceRuns => _maintenanceService.maintenanceRuns;

  @visibleForTesting
  set maintenanceRuns(int value) => _maintenanceService.maintenanceRuns = value;

  @visibleForTesting
  Future<void> runPeriodicMaintenanceForTesting() =>
      _maintenanceService.runPeriodicMaintenanceForTesting();

  DownloadTasksCompanion _taskToCompanion(DownloadTask task) =>
      TaskCompanionConverter.taskToCompanion(task);

  @visibleForTesting
  DownloadTask rowToTaskForTesting(DbDownloadTask row) =>
      TaskCompanionConverter.rowToTask(row);

  DownloadTask _rowToTask(DbDownloadTask row) =>
      TaskCompanionConverter.rowToTask(row);

  Future<List<DownloadTask>> loadTasks() async {
    final rows = await (_db.select(
      _db.downloadTasks,
    )..orderBy([(t) => drift.OrderingTerm.desc(t.createdAt)]))
        .get();
    final tasks = <DownloadTask>[];
    final corrected = <DownloadTask>[];
    for (final r in rows) {
      final task = _rowToTask(r);
      tasks.add(task);
      if (TaskCompanionConverter.isInterruptedActiveRow(r)) {
        corrected.add(task);
      }
    }
    if (corrected.isNotEmpty) {
      unawaited(saveTasks(corrected));
    }
    return tasks;
  }

  /// Paginated load of download tasks (DB-02 / Fix 6).
  Future<List<DownloadTask>> loadTasksPage({
    int limit = 50,
    int offset = 0,
    String? status,
    String? category,
    String? search,
  }) async {
    var query = _db.select(_db.downloadTasks);
    if (status != null && status != 'All') {
      query = query..where((t) => t.status.equals(status));
    }
    if (category != null && category != 'All') {
      query = query..where((t) => t.category.equals(category));
    }
    if (search != null && search.trim().isNotEmpty) {
      final term = '%${search.trim()}%';
      query = query..where((t) => t.fileName.like(term) | t.url.like(term));
    }
    query = query
      ..orderBy([(t) => drift.OrderingTerm.desc(t.createdAt)])
      ..limit(limit, offset: offset);
    final rows = await query.get();
    final tasks = <DownloadTask>[];
    final corrected = <DownloadTask>[];
    for (final r in rows) {
      final task = _rowToTask(r);
      tasks.add(task);
      if (TaskCompanionConverter.isInterruptedActiveRow(r)) {
        corrected.add(task);
      }
    }
    if (corrected.isNotEmpty) {
      unawaited(saveTasks(corrected));
    }
    return tasks;
  }

  /// Get total task count with optional filters (Fix 6).
  Future<int> getTaskCount({
    String? status,
    String? category,
    String? search,
  }) async {
    final countExp = _db.downloadTasks.id.count();
    var query = _db.selectOnly(_db.downloadTasks)..addColumns([countExp]);
    if (status != null && status != 'All') {
      query = query..where(_db.downloadTasks.status.equals(status));
    }
    if (category != null && category != 'All') {
      query = query..where(_db.downloadTasks.category.equals(category));
    }
    if (search != null && search.trim().isNotEmpty) {
      final term = '%${search.trim()}%';
      query = query
        ..where(_db.downloadTasks.fileName.like(term) |
            _db.downloadTasks.url.like(term));
    }
    final result = await query.getSingle();
    return result.read(countExp) ?? 0;
  }

  Future<DownloadTask?> getTask(String id) async {
    final query = _db.select(_db.downloadTasks)..where((t) => t.id.equals(id));
    final row = await query.getSingleOrNull();
    return row != null ? _rowToTask(row) : null;
  }

  final Map<String, DownloadTask> _pendingProgressSaves = {};
  final Lock _pendingSavesLock = Lock();
  Timer? _dbBatchTimer;

  @visibleForTesting
  Timer? get dbBatchTimer => _dbBatchTimer;

  @visibleForTesting
  int get pendingProgressSavesCount => _pendingProgressSaves.length;

  Future<void> saveTaskDebounced(DownloadTask task) async {
    if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.failed) {
      await saveTask(task);
      return;
    }

    bool shouldFlushImmediately = false;
    await _pendingSavesLock.synchronized(() {
      _pendingProgressSaves[task.id] = task;
      // Strict threshold: if pending items reach 100, force an immediate flush bypassing the timer
      if (_pendingProgressSaves.length >= 100) {
        shouldFlushImmediately = true;
      }
    });

    if (shouldFlushImmediately) {
      await flushPendingSaves();
      return;
    }

    final isBackground = !DownloadEngine.appInForeground ||
        DownloadEngine.isInBackground ||
        PowerMonitor.screenOff;
    final interval = isBackground
        ? const Duration(seconds: 20) // 20s in background (hardened from 120s)
        : const Duration(seconds: 10); // 10s in foreground

    _scheduleFlush(interval);
  }

  void _scheduleFlush(Duration interval) {
    // Avoid resetting the timer on rapid debounced calls to prevent DB queue starvation
    if (_dbBatchTimer != null && _dbBatchTimer!.isActive) {
      return;
    }
    _dbBatchTimer?.cancel();
    _dbBatchTimer = Timer(interval, flushPendingSaves);
  }

  bool _completedTaskPendingCheckpoint = false;

  @visibleForTesting
  bool get completedTaskPendingCheckpoint => _completedTaskPendingCheckpoint;

  void _scheduleCompletedTaskCheckpoint() {
    if (_completedTaskPendingCheckpoint) return;
    _completedTaskPendingCheckpoint = true;
    scheduleMicrotask(() async {
      try {
        final activeRows = await _db
            .customSelect(
                "SELECT COUNT(*) as cnt FROM download_tasks WHERE status = 'downloading'")
            .get();
        final hasActive =
            activeRows.isNotEmpty && (activeRows.first.read<int>('cnt')) > 0;
        if (!hasActive) {
          await _db.customStatement('PRAGMA wal_checkpoint(FULL)');
        }
      } catch (e, st) {
        _log.warning('Checkpoint after task completion failed: $e', e, st);
      } finally {
        _completedTaskPendingCheckpoint = false;
      }
    });
  }

  void cancelPendingTimers() {
    _dbBatchTimer?.cancel();
    _dbBatchTimer = null;
    _maintenanceService.dispose();
    _historyRepo.dispose();
  }

  Future<void> flushImmediately() => flush();

  /// FIX-1: Flushes all pending writes and checkpoints WAL to disk.
  Future<void> flush() async {
    await flushPendingSaves();
    try {
      await _db.customStatement('PRAGMA wal_checkpoint(PASSIVE)');
    } catch (_) {}
  }

  Future<void> flushPendingSaves() async {
    _dbBatchTimer?.cancel();
    _dbBatchTimer = null;

    List<DownloadTask> toSave = [];
    await _pendingSavesLock.synchronized(() {
      if (_pendingProgressSaves.isEmpty) return;
      toSave = List<DownloadTask>.from(_pendingProgressSaves.values);
      _pendingProgressSaves.clear();
    });

    if (toSave.isEmpty) return;
    await saveTasks(toSave);
  }

  /// Synchronously drains _pendingProgressSaves without awaiting a timer.
  void flushPendingSavesSync() {
    _dbBatchTimer?.cancel();
    _dbBatchTimer = null;
    if (_pendingProgressSaves.isEmpty) return;
    final toSave = List<DownloadTask>.from(_pendingProgressSaves.values);
    _pendingProgressSaves.clear();
    unawaited(saveTasks(toSave));
  }

  Future<void> saveTask(DownloadTask task) async {
    _pendingProgressSaves.remove(task.id);
    int retries = 3;
    int attempt = 0;
    while (true) {
      try {
        await _db.into(_db.downloadTasks).insert(
              _taskToCompanion(task),
              mode: drift.InsertMode.insertOrReplace,
            );
        if (task.status == DownloadStatus.completed) {
          _scheduleCompletedTaskCheckpoint();
        }
        return;
      } catch (e) {
        final errStr = e.toString().toLowerCase();
        final isBusyOrLocked = errStr.contains('busy') ||
            errStr.contains('locked') ||
            errStr.contains('sqlite_busy') ||
            errStr.contains('sqlite_locked');
        if (!isBusyOrLocked) {
          // Task 2.3: Fail fast on schema or non-locking errors
          rethrow;
        }
        retries--;
        attempt++;
        if (retries <= 0) {
          rethrow;
        }
        final delayMs = 100 * (1 << (attempt - 1));
        _log.warning(
            'saveTask failed due to lock/busy, retrying in ${delayMs}ms... Error: $e');
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    }
  }

  /// Transactionally upserts only modified tasks using INSERT OR REPLACE / conflict updates.
  /// This prevents full table rewrites and protects against race conditions.
  Future<void> upsertTasks(Iterable<DownloadTask> changedTasks) async {
    final list = changedTasks.toList();
    if (list.isEmpty) return;
    final comps = list.map(_taskToCompanion).toList();
    try {
      await _db.transaction(() async {
        for (final comp in comps) {
          await _db.into(_db.downloadTasks).insertOnConflictUpdate(comp);
        }
      });
    } catch (e, st) {
      _log.warning(
          'upsertTasks transaction failed, falling back to individual upserts: $e',
          e,
          st);
      for (final comp in comps) {
        try {
          await _db.into(_db.downloadTasks).insertOnConflictUpdate(comp);
        } catch (inner, innerSt) {
          _log.severe(
              'Per-task upsert fallback failed for ${comp.id.value}: $inner',
              inner,
              innerSt);
        }
      }
    }
  }

  Future<void> saveTasks(Iterable<DownloadTask> tasks) async {
    final comps = tasks.map(_taskToCompanion).toList();
    if (comps.isEmpty) return;
    try {
      await _db.transaction(() async {
        await _db.batch(
          (batch) => batch.insertAll(
            _db.downloadTasks,
            comps,
            mode: drift.InsertMode.insertOrReplace,
          ),
        );
      });
    } catch (e, st) {
      _log.warning(
          'saveTasks batch failed, falling back to per-task upsert: $e', e, st);
      for (final comp in comps) {
        try {
          await _db.into(_db.downloadTasks).insertOnConflictUpdate(comp);
        } catch (inner, innerSt) {
          _log.severe(
              'Per-task upsert fallback failed for ${comp.id.value}: $inner',
              inner,
              innerSt);
        }
      }
    }
  }

  /// Batch upserts tasks, falling back to primary key conflict resolution on collision.
  Future<void> batchUpsertTasks(Iterable<DownloadTask> tasks) =>
      upsertTasks(tasks);

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

  Future<List<Bookmark>> loadBookmarks({String? searchQuery}) =>
      _bookmarkRepo.loadBookmarks(searchQuery: searchQuery);

  Future<List<Bookmark>> searchBookmarks(String query, {int limit = 3}) =>
      _bookmarkRepo.searchBookmarks(query, limit: limit);

  Future<void> saveBookmark(Bookmark bookmark) =>
      _bookmarkRepo.saveBookmark(bookmark);

  Future<void> deleteBookmark(String id) => _bookmarkRepo.deleteBookmark(id);

  Future<void> clearBookmarks() => _bookmarkRepo.clearBookmarks();

  Future<List<Map<String, dynamic>>> loadBrowserHistory({
    int? max,
    String? searchQuery,
  }) =>
      _historyRepo.loadBrowserHistory(max: max, searchQuery: searchQuery);

  Future<void> clearBrowserHistoryBefore(DateTime? before) =>
      _historyRepo.clearBrowserHistoryBefore(before);

  Future<int> getVisitCount(String url) => _historyRepo.getVisitCount(url);

  @visibleForTesting
  Timer? get historyFlushTimer => _historyRepo.historyFlushTimer;

  @visibleForTesting
  int get pendingHistoryEntriesCount => _historyRepo.pendingHistoryEntriesCount;

  Future<int> addBrowserHistory(
    Map<String, dynamic> entry, {
    bool immediate = false,
  }) =>
      _historyRepo.addBrowserHistory(entry, immediate: immediate);

  Future<void> flushPendingHistory() => _historyRepo.flushPendingHistory();

  Future<void> updateBrowserHistoryTitle(int id, String title) =>
      _historyRepo.updateBrowserHistoryTitle(id, title);

  Future<void> updateBrowserHistoryTime(int id, int visitedAt) =>
      _historyRepo.updateBrowserHistoryTime(id, visitedAt);

  Future<void> deleteBrowserHistory(int id) =>
      _historyRepo.deleteBrowserHistory(id);

  Future<void> clearBrowserHistory() => _historyRepo.clearBrowserHistory();

  Future<void> saveOpenTabs(List<SavedBrowserTab> tabs) =>
      _tabRepo.saveOpenTabs(tabs);

  Future<List<SavedBrowserTab>> loadAndClearOpenTabs() =>
      _tabRepo.loadAndClearOpenTabs();

  Future<List<SavedBrowserTab>> loadOpenTabs() => _tabRepo.loadOpenTabs();

  Future<void> clearOpenTabs() => _tabRepo.clearOpenTabs();

  Future<void> dispose() async {
    // Force flush on dispose
    flushPendingSavesSync();
    await flushPendingSaves();
    await flushPendingHistory();

    _maintenanceService.dispose();
    _historyRepo.dispose();

    _dbBatchTimer?.cancel();
    _dbBatchTimer = null;
    await _db.closeDatabase();
  }
}
