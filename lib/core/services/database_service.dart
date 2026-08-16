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
import '../../features/settings/provider/settings_provider.dart';
import 'background_gate.dart';
import 'crash_reporting_service.dart';
import 'database/app_database.dart';
import 'database/hive_migration_service.dart';
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

  /// FIX(23): history is capped on *every* write (below), so the old
  /// "every Nth insert" counter — which reset on hot restart and let history
  /// grow unbounded — is removed.

  /// FIX(15): periodic WAL checkpoint + occasional VACUUM to keep the
  /// database file small and recovery fast.
  Timer? _maintenanceTimer;
  int _maintenanceRuns = 0;
  int _historyInsertCount = 0;

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
    await HiveMigrationService(_db, prefs).migrate();
    _initialized = true;

    _scheduleMaintenanceTimer();
    _throttleFactorListener = () => _scheduleMaintenanceTimer();
    PowerMonitor.throttleFactorNotifier.addListener(_throttleFactorListener!);
    _screenStateSub = PowerMonitor.screenStateStream
        .listen((_) => _scheduleMaintenanceTimer());
  }

  StreamSubscription<bool>? _screenStateSub;
  VoidCallback? _throttleFactorListener;

  void _scheduleMaintenanceTimer() {
    _maintenanceTimer?.cancel();
    if (!_initialized) return;
    final interval = BackgroundGate.adaptInterval(const Duration(minutes: 30));
    _maintenanceTimer = Timer.periodic(interval, (_) async {
      await _runPeriodicMaintenance();
    });
  }

  @visibleForTesting
  int get maintenanceRuns => _maintenanceRuns;

  @visibleForTesting
  set maintenanceRuns(int value) => _maintenanceRuns = value;

  @visibleForTesting
  Future<void> runPeriodicMaintenanceForTesting() => _runPeriodicMaintenance();

  /// Periodic SQLite maintenance cadence:
  /// - When active downloads exist: skip wal_checkpoint to protect throughput; run PRAGMA optimize.
  /// - When idle: wal_checkpoint(RESTART) to fully fold the WAL into the database file.
  /// - Every 6th cycle (3h): Check WAL size, force TRUNCATE if > 1250 pages (~5MB)
  /// - Every 12th cycle (6h): PRAGMA optimize, incremental_vacuum, foreign_key_check (when idle)
  Future<void> _runPeriodicMaintenance() async {
    final activeRows = await _db
        .customSelect(
            "SELECT COUNT(*) as cnt FROM download_tasks WHERE status = 'downloading'")
        .get();
    final hasActiveDownloads = (activeRows.first.read<int>('cnt')) > 0;

    final swCheckpoint = Stopwatch()..start();
    int logPages = 0;
    try {
      if (hasActiveDownloads) {
        _log.fine(
            '[DatabaseService] Active downloads in progress; skipping periodic wal_checkpoint');
      } else {
        final walRows =
            await _db.customSelect('PRAGMA wal_checkpoint(RESTART)').get();
        if (walRows.isNotEmpty) {
          final row = walRows.first.data;
          final log = row['log'] ?? 0;
          if (log is num) {
            logPages = log.toInt();
          }
        }
      }
      if (_maintenanceRuns % 12 == 0) {
        await _db.customStatement('PRAGMA optimize');
      }
      swCheckpoint.stop();
      if (swCheckpoint.elapsedMilliseconds > 500) {
        _log.info('wal_checkpoint took ${swCheckpoint.elapsedMilliseconds}ms');
      }
    } catch (e) {
      _log.warning('wal_checkpoint failed', e);
    }

    _maintenanceRuns++;
    if (_maintenanceRuns % 6 == 0 && !hasActiveDownloads) {
      try {
        if (logPages > 1250) {
          // ~5MB in 4KB pages
          _log.warning('WAL too large ($logPages pages), forcing TRUNCATE');
          await _db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
        }
      } catch (e, st) {
        LoggingService.logger('DatabaseService')
            .warning('Operation failed', e, st);
      }
    }
    if (_maintenanceRuns % 12 == 0 && !hasActiveDownloads) {
      try {
        final swVacuum = Stopwatch()..start();
        await _db.customStatement('PRAGMA incremental_vacuum(50)');
        try {
          await _db.customStatement('PRAGMA foreign_key_check');
        } catch (e, st) {
          LoggingService.logger('DatabaseService')
              .warning('PRAGMA foreign_key_check failed', e, st);
        }
        swVacuum.stop();
        if (swVacuum.elapsedMilliseconds > 500) {
          _log.info(
              'incremental_vacuum took ${swVacuum.elapsedMilliseconds}ms');
        }
      } catch (e, st) {
        LoggingService.logger('DatabaseService')
            .warning('Periodic vacuum/fk check failed', e, st);
      }
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
      pauseReason: drift.Value(task.pauseReason?.name),
      totalPieces: drift.Value(task.totalPieces),
      completedPieces: drift.Value(task.completedPieces),
      ytCounterpartDownloadedBytes:
          drift.Value(task.ytCounterpartDownloadedBytes),
      cycleState: drift.Value(task.cycleState?.name),
    );
  }

  @visibleForTesting
  DownloadTask rowToTaskForTesting(DbDownloadTask row) => _rowToTask(row);

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
    final parsedStatus = DownloadStatus.values.firstWhere(
      (value) => value.name == statusName,
      orElse: () {
        debugPrint(
          '[DMX] _rowToTask: unrecognised status "$statusName" for task '
          '${row.id} — reporting and defaulting to error.',
        );
        CrashReportingService.recordError(
          FormatException('Unrecognised download task status: "$statusName"'),
          StackTrace.current,
          hint: 'Task ${row.id} has invalid status "$statusName" in SQLite',
        );
        return DownloadStatus.failed;
      },
    );

    final rawCycleState =
        row.cycleState != null ? CycleState.fromName(row.cycleState) : null;
    final rawPauseReason =
        row.pauseReason != null ? PauseReason.fromName(row.pauseReason) : null;

    // State recovery: include allocating and stalled transient states on restart
    final isInterruptedActive = parsedStatus == DownloadStatus.downloading ||
        rawCycleState == CycleState.starting ||
        rawCycleState == CycleState.resuming ||
        rawCycleState == CycleState.retrying ||
        rawCycleState == CycleState.fetchingMetadata ||
        rawCycleState == CycleState.merging ||
        rawCycleState == CycleState.verifying ||
        rawCycleState == CycleState.updatingLinks ||
        rawCycleState == CycleState.allocating ||
        rawCycleState == CycleState.stalled;

    final isUpdatingLinks = rawCycleState == CycleState.updatingLinks;
    final status = isInterruptedActive ? DownloadStatus.paused : parsedStatus;
    final cycleState = isInterruptedActive ? CycleState.paused : rawCycleState;
    final pauseReason = isUpdatingLinks
        ? PauseReason.urlExpired
        : (isInterruptedActive ? PauseReason.appRestarted : rawPauseReason);
    // Ensure previousCycleState is populated for UI hinting
    final previousCycleState = isInterruptedActive ? rawCycleState : null;

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
      pauseReason: pauseReason,
      totalPieces: row.totalPieces,
      completedPieces: row.completedPieces,
      ytCounterpartDownloadedBytes: row.ytCounterpartDownloadedBytes,
      cycleState: cycleState,
      previousCycleState: previousCycleState,
      totalFiles: (row.torrentFiles != null && row.torrentFiles!.isNotEmpty)
          ? row.torrentFiles!
              .where((f) => (f['selected'] as bool?) ?? true)
              .length
          : null,
      completedFiles: (row.torrentFiles != null && row.torrentFiles!.isNotEmpty)
          ? row.torrentFiles!
              .where((f) => (f['selected'] as bool?) ?? true)
              .where((f) {
              final len = (f['length'] as num?)?.toInt() ?? 0;
              final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
              return len == 0 || dl >= len;
            }).length
          : null,
      totalFileBytes: (row.torrentFiles != null && row.torrentFiles!.isNotEmpty)
          ? row.torrentFiles!
              .where((f) => (f['selected'] as bool?) ?? true)
              .fold<int>(
                  0, (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0))
          : null,
      downloadedFileBytes:
          (row.torrentFiles != null && row.torrentFiles!.isNotEmpty)
              ? row.torrentFiles!
                  .where((f) => (f['selected'] as bool?) ?? true)
                  .fold<int>(0, (sum, f) {
                  final len = (f['length'] as num?)?.toInt() ?? 0;
                  final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
                  return sum + (len > 0 ? dl.clamp(0, len) : 0);
                })
              : null,
    );
  }

  Future<List<DownloadTask>> loadTasks() async {
    final rows = await (_db.select(
      _db.downloadTasks,
    )..orderBy([(t) => drift.OrderingTerm.desc(t.createdAt)]))
        .get();
    return rows.map(_rowToTask).toList();
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
    return rows.map(_rowToTask).toList();
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
    bool shouldFlushImmediately = false;
    await _pendingSavesLock.synchronized(() {
      _pendingProgressSaves[task.id] = task;
      // Strict threshold: if pending items reach 25, force an immediate flush bypassing the timer
      if (_pendingProgressSaves.length >= 25) {
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
        ? const Duration(seconds: 120) // 120s in background
        : const Duration(seconds: 30); // 30s in foreground

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

  void cancelPendingTimers() {
    _dbBatchTimer?.cancel();
    _dbBatchTimer = null;
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    _historyFlushTimer?.cancel();
    _historyFlushTimer = null;
  }

  Future<void> flushImmediately() => flushPendingSaves();

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

  Future<void> saveTask(DownloadTask task) async {
    _pendingProgressSaves.remove(task.id);
    int retries = 3;
    int attempt = 0;
    while (true) {
      try {
        if (task.status == DownloadStatus.completed) {
          // Task 5.2: Durable completion writes with PRAGMA synchronous = FULL
          try {
            await _db.customStatement('PRAGMA synchronous = FULL');
          } catch (_) {}
          await _db.into(_db.downloadTasks).insert(
                _taskToCompanion(task),
                mode: drift.InsertMode.insertOrReplace,
              );
          try {
            await _db.customStatement('PRAGMA synchronous = NORMAL');
          } catch (_) {}
        } else {
          await _db.into(_db.downloadTasks).insert(_taskToCompanion(task),
              mode: drift.InsertMode.insertOrReplace);
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
      saveTasks(tasks);

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

  Timer? _historyFlushTimer;
  final Map<String, Map<String, dynamic>> _pendingHistoryEntries = {};

  @visibleForTesting
  Timer? get historyFlushTimer => _historyFlushTimer;

  @visibleForTesting
  int get pendingHistoryEntriesCount => _pendingHistoryEntries.length;

  /// Adds browser history using a single global 5-second flush timer (DB-04).
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

    if (_pendingHistoryEntries.length >= 20) {
      await flushPendingHistory();
      return 1;
    }

    _historyFlushTimer ??= Timer(const Duration(seconds: 5), () async {
      _historyFlushTimer = null;
      await flushPendingHistory();
    });

    return 1;
  }

  Future<void> flushPendingHistory() async {
    _historyFlushTimer?.cancel();
    _historyFlushTimer = null;
    if (_pendingHistoryEntries.isEmpty) return;

    final entries =
        List<Map<String, dynamic>>.from(_pendingHistoryEntries.values);
    _pendingHistoryEntries.clear();

    for (final entry in entries) {
      await _writeBrowserHistoryDirect(entry);
    }
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

    _historyInsertCount++;
    if (_historyInsertCount % 100 == 0) {
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
    await flushPendingHistory();

    if (_throttleFactorListener != null) {
      PowerMonitor.throttleFactorNotifier
          .removeListener(_throttleFactorListener!);
      _throttleFactorListener = null;
    }
    _screenStateSub?.cancel();
    _screenStateSub = null;

    _historyFlushTimer?.cancel();
    _historyFlushTimer = null;
    _pendingHistoryEntries.clear();

    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    _dbBatchTimer?.cancel();
    _dbBatchTimer = null;
    await _db.close();
  }
}
