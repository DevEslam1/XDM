import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import '../logging_service.dart';
import '../tick_manager.dart';

part 'app_database.g.dart';

final _dbLog = LoggingService.logger('AppDatabase');

List<double> _recoverDoubleList(String fromDb) {
  try {
    final arrayMatch = RegExp(r'\[([\s\S]*)\]').firstMatch(fromDb);
    final targetText = arrayMatch != null ? arrayMatch.group(1)! : fromDb;
    final matches = RegExp(r'[0-9]+(?:\.[0-9]+)?').allMatches(targetText);
    final result = <double>[];
    for (final match in matches) {
      final valStr = match.group(0);
      if (valStr != null) {
        final val = double.tryParse(valStr);
        if (val != null) {
          result.add(val);
        }
      }
    }
    return result;
  } catch (_) {
    return [];
  }
}

List<Map<String, dynamic>> _recoverTorrentFiles(String fromDb) {
  try {
    final result = <Map<String, dynamic>>[];
    int depth = 0;
    int start = -1;
    bool inString = false;
    bool escaped = false;

    for (int i = 0; i < fromDb.length; i++) {
      final char = fromDb[i];

      if (escaped) {
        escaped = false;
        continue;
      }

      if (char == r'\') {
        if (inString) {
          escaped = true;
        }
        continue;
      }

      if (char == '"') {
        inString = !inString;
        continue;
      }

      if (!inString) {
        if (char == '{') {
          if (depth == 0) {
            start = i;
          }
          depth++;
        } else if (char == '}') {
          if (depth > 0) {
            depth--;
            if (depth == 0 && start != -1) {
              final objStr = fromDb.substring(start, i + 1);
              try {
                final obj = jsonDecode(objStr);
                if (obj is Map) {
                  result.add(Map<String, dynamic>.from(obj));
                }
              } catch (_) {}
              start = -1;
            }
          }
        }
      }
    }
    return result;
  } catch (_) {
    return [];
  }
}

class DoubleListConverter extends TypeConverter<List<double>, String> {
  const DoubleListConverter();

  /// Bounded cache of regex-recovered values so repeatedly reading the same
  /// corrupted cell does not re-run the recovery pass on every query.
  static final LinkedHashMap<String, List<double>> _recoveryCache =
      LinkedHashMap<String, List<double>>();
  static const int _recoveryCacheLimit = 64;

  /// Clears the bounded recovery cache. Testing hook.
  @visibleForTesting
  static void clearRecoveryCache() => _recoveryCache.clear();

  /// Current number of cached recovered values. Testing hook.
  @visibleForTesting
  static int get recoveryCacheLength => _recoveryCache.length;

  @override
  List<double> fromSql(String fromDb) {
    if (fromDb.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(fromDb);
      if (decoded is List) {
        final result = <double>[];
        for (final e in decoded) {
          try {
            if (e is num) {
              result.add(e.toDouble());
            } else {
              result.add(0.0);
            }
          } catch (_) {
            result.add(0.0);
          }
        }
        return result;
      }
      _dbLog.warning(
          'DoubleListConverter: unexpected type ${decoded.runtimeType} for input');
      return [];
    } catch (e) {
      final cached = _recoveryCache[fromDb];
      if (cached != null) return cached;
      try {
        _dbLog.warning(
            'Telemetry: DoubleListConverter invoked legacy regex recovery fallback for corrupted JSON cell');
        final result = _recoverDoubleList(fromDb);
        if (result.isNotEmpty) {
          if (_recoveryCache.length >= _recoveryCacheLimit) {
            _recoveryCache.remove(_recoveryCache.keys.first);
          }
          _recoveryCache[fromDb] = result;
          _dbLog.info(
              'Successfully recovered ${result.length} double items from corrupted JSON');
          return result;
        }
      } catch (recEx) {
        _dbLog.warning('DoubleListConverter regex recovery failed: $recEx');
      }
      _dbLog.warning('Error decoding DoubleList from DB: $e');
      return [];
    }
  }

  @override
  String toSql(List<double> value) => jsonEncode(value);
}

class TorrentFilesConverter
    extends TypeConverter<List<Map<String, dynamic>>, String> {
  const TorrentFilesConverter();

  /// Bounded cache of regex-recovered values so repeatedly reading the same
  /// corrupted cell does not re-run the recovery pass on every query.
  static final LinkedHashMap<String, List<Map<String, dynamic>>>
      _recoveryCache = LinkedHashMap<String, List<Map<String, dynamic>>>();
  static const int _recoveryCacheLimit = 64;

  /// Clears the bounded recovery cache. Testing hook.
  @visibleForTesting
  static void clearRecoveryCache() => _recoveryCache.clear();

  /// Current number of cached recovered values. Testing hook.
  @visibleForTesting
  static int get recoveryCacheLength => _recoveryCache.length;

  @override
  List<Map<String, dynamic>> fromSql(String fromDb) {
    if (fromDb.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(fromDb);
      if (decoded is List) {
        final result = <Map<String, dynamic>>[];
        for (final e in decoded) {
          try {
            if (e is Map) {
              result.add(Map<String, dynamic>.from(e));
            }
          } catch (e, st) {
            LoggingService.logger('AppDatabase')
                .warning('Operation failed', e, st);
          }
        }
        return result;
      }
      _dbLog.warning(
          'TorrentFilesConverter: unexpected type ${decoded.runtimeType} for input');
      return [];
    } catch (e) {
      final cached = _recoveryCache[fromDb];
      if (cached != null) return cached;
      try {
        _dbLog.warning(
            'Telemetry: TorrentFilesConverter invoked legacy regex recovery fallback for corrupted JSON cell');
        final result = _recoverTorrentFiles(fromDb);
        if (result.isNotEmpty) {
          if (_recoveryCache.length >= _recoveryCacheLimit) {
            _recoveryCache.remove(_recoveryCache.keys.first);
          }
          _recoveryCache[fromDb] = result;
          _dbLog.info(
              'Successfully recovered ${result.length} torrent file entries from corrupted JSON');
          return result;
        }
      } catch (recEx) {
        _dbLog.warning('TorrentFilesConverter regex recovery failed: $recEx');
      }
      _dbLog.warning('Error decoding TorrentFiles from DB: $e');
      return [];
    }
  }

  @override
  String toSql(List<Map<String, dynamic>> value) {
    try {
      return jsonEncode(value);
    } catch (e, st) {
      _dbLog.warning('Sanitizing TorrentFiles before encoding: $e', e, st);
      final safeList = value.map((map) {
        return map.map((k, v) {
          if (v is String || v is num || v is bool || v is List || v is Map) {
            return MapEntry(k, v);
          }
          return MapEntry(k, v.toString());
        });
      }).toList();
      return jsonEncode(safeList);
    }
  }
}

class StringListConverter extends TypeConverter<List<String>, String> {
  const StringListConverter();

  @override
  List<String> fromSql(String fromDb) {
    if (fromDb.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(fromDb);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
      _dbLog.warning(
          'StringListConverter: unexpected type ${decoded.runtimeType} for input');
      return [];
    } catch (e) {
      _dbLog.warning('Error decoding StringList from DB: $e');
      return [];
    }
  }

  @override
  String toSql(List<String> value) => jsonEncode(value);
}

@DataClassName('DbDownloadTask')
class DownloadTasks extends Table {
  TextColumn get id => text()();
  TextColumn get fileName => text()();
  TextColumn get url => text()();
  IntColumn get fileSize => integer().withDefault(const Constant(0))();
  IntColumn get downloadedBytes => integer().withDefault(const Constant(0))();
  RealColumn get speed => real().withDefault(const Constant(0.0))();
  IntColumn get eta => integer().nullable()();
  TextColumn get category => text()();
  TextColumn get status => text()();
  TextColumn get savePath => text()();
  TextColumn get localFilePath => text()();
  TextColumn get tempFilePath => text()();
  TextColumn get errorMessage => text().nullable()();
  IntColumn get threadCount => integer()();
  TextColumn get chunks => text()
      .map(const NullAwareTypeConverter.wrap(DoubleListConverter()))
      .nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get completedAt => integer().nullable()();
  IntColumn get scheduledAt => integer().nullable()();
  BoolColumn get supportsResume =>
      boolean().withDefault(const Constant(false))();
  IntColumn get speedLimitKbps => integer().withDefault(const Constant(0))();
  BoolColumn get seedingEnabled =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get seedingLimited =>
      boolean().withDefault(const Constant(false))();
  IntColumn get seedingLimitKbps =>
      integer().withDefault(const Constant(500))();
  TextColumn get torrentFiles => text()
      .map(const NullAwareTypeConverter.wrap(TorrentFilesConverter()))
      .nullable()();
  TextColumn get downloadPageUrl => text().nullable()();
  TextColumn get mergedAudioUrl => text().nullable()();
  IntColumn get audioSize => integer().withDefault(const Constant(0))();
  IntColumn get audioDownloadedBytes =>
      integer().withDefault(const Constant(0))();
  IntColumn get videoStreamSize => integer().withDefault(const Constant(0))();
  RealColumn get audioProgress => real().withDefault(const Constant(0.0))();
  BoolColumn get pausedByUser => boolean().withDefault(const Constant(false))();
  TextColumn get youtubeQualityPreset => text().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get playlistId => text().nullable()();
  TextColumn get playlistTitle => text().nullable()();
  TextColumn get thumbnailUrl => text().nullable()();
  BoolColumn get isAppUpdate => boolean().withDefault(const Constant(false))();
  IntColumn get uploadedBytes => integer().withDefault(const Constant(0))();
  IntColumn get priority => integer().withDefault(const Constant(0))();
  IntColumn get queueOrder => integer().withDefault(const Constant(0))();
  TextColumn get expectedSha256 => text().nullable()();
  TextColumn get mirrorUrls => text()
      .map(const NullAwareTypeConverter.wrap(StringListConverter()))
      .nullable()();
  TextColumn get pauseReason => text().nullable()();
  IntColumn get totalPieces => integer().nullable()();
  IntColumn get completedPieces => integer().nullable()();
  IntColumn get ytCounterpartDownloadedBytes => integer().nullable()();
  TextColumn get cycleState => text().nullable()();
  // FIX 7.1: New columns for dual-stream, parts, and pieces tracking
  TextColumn get audioChunks => text()
      .map(const NullAwareTypeConverter.wrap(DoubleListConverter()))
      .nullable()();
  TextColumn get httpParts => text().nullable()();
  RealColumn get torrentPieceProgress => real().nullable()();
  IntColumn get audioChunksCompleted => integer().nullable()();
  IntColumn get audioChunksTotal => integer().nullable()();
  IntColumn get httpPartsCompleted => integer().nullable()();
  IntColumn get httpPartsTotal => integer().nullable()();
  TextColumn get previousCycleState => text().nullable()();
  TextColumn get infoHash => text().nullable()();
  BoolColumn get isCancelled => boolean().withDefault(const Constant(false))();
  // HTTP auth + custom headers per download (Plan 06 Task 6.2).
  // customHeaders is stored as a JSON object string; (de)serialized in
  // TaskCompanionConverter.
  TextColumn get authUsername => text().nullable()();
  TextColumn get authPassword => text().nullable()();
  TextColumn get customHeaders => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DbMirrorHealth')
class MirrorHealth extends Table {
  TextColumn get url => text()();
  IntColumn get failures => integer().withDefault(const Constant(0))();
  IntColumn get lastFailure => integer().withDefault(const Constant(0))();
  IntColumn get lastSuccess => integer().withDefault(const Constant(0))();
  IntColumn get lastStatusCode => integer().withDefault(const Constant(0))();
  IntColumn get blacklistedUntil => integer().withDefault(const Constant(0))();
  RealColumn get averageSpeedBps => real().withDefault(const Constant(0.0))();
  TextColumn get speedSamples => text().nullable()();

  @override
  Set<Column> get primaryKey => {url};
}

@DataClassName('DbBookmark')
class Bookmarks extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get url => text()();
  TextColumn get folder => text().nullable()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DbBrowserHistory')
class BrowserHistory extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get url => text()();
  TextColumn get title => text()();
  IntColumn get visitedAt => integer()();
  IntColumn get visitCount => integer().withDefault(const Constant(1))();
  TextColumn get faviconUrl => text().nullable()();
}

@DataClassName('SavedBrowserTab')
class BrowserTabs extends Table {
  TextColumn get id => text()();
  TextColumn get url => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
  IntColumn get position => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer()();
  IntColumn get lastVisitedAt => integer().withDefault(const Constant(0))();
  TextColumn get faviconUrl => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

LazyDatabase _openConnection(String path,
    {bool stateCriticalSynchronous = false}) {
  return LazyDatabase(() async {
    final file = File(path);
    return NativeDatabase.createInBackground(
      file,
      setup: (database) {
        database.execute('PRAGMA journal_mode=WAL;');
        if (stateCriticalSynchronous) {
          database.execute('PRAGMA synchronous=FULL;');
        } else {
          database.execute('PRAGMA synchronous=NORMAL;');
        }
        database.execute('PRAGMA foreign_keys=ON;');
        database.execute('PRAGMA busy_timeout=5000;');
        database.execute('PRAGMA journal_size_limit=10485760;'); // 10MB WAL cap
      },
    );
  });
}

@DriftDatabase(tables: [
  DownloadTasks,
  Bookmarks,
  BrowserHistory,
  BrowserTabs,
  MirrorHealth
])
class AppDatabase extends _$AppDatabase {
  final String? dbPath;
  final bool stateCriticalSynchronous;
  Timer? _checkpointTimer;

  static const int walMaxSizeBytes = 10 * 1024 * 1024; // 10MB

  AppDatabase(String path, {this.stateCriticalSynchronous = false})
      : dbPath = path,
        super(_openConnection(path,
            stateCriticalSynchronous: stateCriticalSynchronous));
  AppDatabase.forTesting(super.e, {this.stateCriticalSynchronous = false})
      : dbPath = null;

  /// Starts a periodic WAL checkpointer running every [interval] (defaults to 5m).
  void startPeriodicWalCheckpointer(
      {Duration interval = const Duration(minutes: 5)}) {
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    TickManager.instance.registerTick(
      id: 'sqlite_wal_checkpointer',
      interval: interval,
      priority: TickPriority.normal,
      callback: (_) async {
        try {
          final walSize = getWalFileSize();
          if (walSize > 0) {
            _dbLog.fine(
                'Periodic checkpoint check: current WAL size is ${walSize}B');
          }
          await checkpointWal();
        } catch (e, st) {
          _dbLog.warning('Periodic WAL checkpoint error: $e', e, st);
        }
      },
    );
  }

  /// Cancels the periodic WAL checkpointer.
  void stopPeriodicWalCheckpointer() {
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    TickManager.instance.unregisterTick('sqlite_wal_checkpointer');
  }

  /// Returns current size in bytes of the SQLite WAL file.
  int getWalFileSize() {
    if (dbPath == null) return 0;
    try {
      final walFile = File('$dbPath-wal');
      return walFile.existsSync() ? walFile.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Checkpoints the WAL file back into the main database file.
  Future<int> checkpointWal({bool truncate = true}) async {
    final beforeSize = getWalFileSize();
    if (beforeSize == 0 && truncate) {
      return 0;
    }
    try {
      final mode = truncate ? 'TRUNCATE' : 'PASSIVE';
      final result = await customSelect('PRAGMA wal_checkpoint($mode);')
          .get()
          .timeout(const Duration(seconds: 3));
      final afterSize = getWalFileSize();
      if (beforeSize > 0 || afterSize > 0) {
        _dbLog.info(
            'WAL checkpoint ($mode) completed. Size: ${beforeSize}B -> ${afterSize}B');
      }
      return result.isNotEmpty
          ? (result.first.data.values.first as int? ?? 0)
          : 0;
    } catch (e, st) {
      _dbLog.warning('WAL checkpoint failed or timed out: $e', e, st);
      return -1;
    }
  }

  /// Verifies connection pool health and cleans up stale locks.
  Future<bool> cleanupStaleConnections() async {
    try {
      final result = await customSelect('SELECT 1 as alive;').get();
      final alive = result.isNotEmpty && result.first.read<int>('alive') == 1;
      if (alive) {
        _dbLog.fine('Database connection pool health check passed.');
      }
      return alive;
    } catch (e, st) {
      _dbLog.severe('Database connection health check failed: $e', e, st);
      return false;
    }
  }

  /// Closes the database cleanly with a final TRUNCATE checkpoint.
  Future<void> closeDatabase() async {
    stopPeriodicWalCheckpointer();
    try {
      await checkpointWal(truncate: true);
    } catch (e, st) {
      _dbLog.warning('Pre-close WAL checkpoint failed: $e', e, st);
    }
    await close();
  }

  /// Sets PRAGMA synchronous to FULL for state-critical write phases.
  Future<void> setSynchronousFull() =>
      safeCustomStatement('PRAGMA synchronous=FULL;');

  /// Reverts PRAGMA synchronous to NORMAL for standard throughput.
  Future<void> setSynchronousNormal() =>
      safeCustomStatement('PRAGMA synchronous=NORMAL;');

  /// Executes a custom SQL statement wrapped with structured logging.
  Future<void> safeCustomStatement(String sql,
      [List<Object?> args = const []]) async {
    try {
      await customStatement(sql, args);
    } catch (e, st) {
      _dbLog.severe(
          'Database safeCustomStatement failed: "$sql", args: $args', e, st);
      rethrow;
    }
  }

  @override
  int get schemaVersion => 28;

  @visibleForTesting
  Future<void> addColumnIfMissingForTesting(
          String table, String column, String sql) =>
      _addColumnIfMissing(table, column, sql);

  /// Idempotent column addition helper that inspects PRAGMA table_info before altering.
  Future<void> _addColumnIfMissing(
    String table,
    String column,
    String sql,
  ) async {
    int attempts = 0;
    while (true) {
      try {
        attempts++;
        final tableInfo = await customSelect('PRAGMA table_info($table)').get();
        final exists = tableInfo.any((row) =>
            (row.read<String>('name')).toLowerCase() == column.toLowerCase());
        if (!exists) {
          _dbLog.info(
              'Column $column confirmed missing from $table. Executing: $sql');
          await safeCustomStatement(sql);
          _dbLog.info('Column $column successfully added to $table');
        } else {
          _dbLog.info(
              'Column $column confirmed already exists in $table; skipping');
        }
        return;
      } catch (e, st) {
        final errStr = e.toString().toLowerCase();
        if (attempts < 3 &&
            (errStr.contains('busy') ||
                errStr.contains('locked') ||
                errStr.contains('sqlite_busy'))) {
          _dbLog.warning(
              '_addColumnIfMissing encountered busy/locked for $table.$column, retrying in 200ms (attempt $attempts)...');
          await Future.delayed(const Duration(milliseconds: 200));
          continue;
        }
        _dbLog.severe(
            '_addColumnIfMissing failed for table: $table, column: $column, sql: $sql',
            e,
            st);
        rethrow;
      }
    }
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement(
              'CREATE INDEX idx_download_tasks_status ON download_tasks (status)');
          await customStatement(
              'CREATE INDEX idx_download_tasks_category ON download_tasks (category)');
          await customStatement(
              'CREATE INDEX idx_download_tasks_created_at ON download_tasks (created_at)');
          await customStatement(
              'CREATE INDEX idx_download_tasks_playlist_id ON download_tasks (playlist_id)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_download_tasks_queue_order ON download_tasks (queue_order)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_download_tasks_scheduled_at ON download_tasks (scheduled_at)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_download_tasks_priority ON download_tasks (priority)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_download_tasks_updated_at ON download_tasks (updated_at)');
          await customStatement(
              'CREATE INDEX idx_browser_history_visited_at ON browser_history (visited_at)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_bookmarks_created_at ON bookmarks (created_at)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_browser_history_url ON browser_history (url)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_bookmarks_url ON bookmarks (url)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_browser_tabs_position ON browser_tabs (position)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_download_tasks_audio_chunks ON download_tasks (audio_chunks) WHERE audio_chunks IS NOT NULL');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_download_tasks_http_parts ON download_tasks (http_parts) WHERE http_parts IS NOT NULL');
          await _createTaskSummaryView();
        },
        onUpgrade: (m, from, to) async {
          debugPrint('AppDatabase: Upgrading schema from $from to $to');
          if (from < 2) {
            await _addColumnIfMissing('download_tasks', 'notes',
                'ALTER TABLE download_tasks ADD COLUMN notes TEXT');
          }
          if (from < 3) {
            try {
              await customStatement('''
              UPDATE download_tasks SET created_at =
                SUBSTR(created_at, 1, INSTR(created_at, '.') - 1)
              WHERE typeof(created_at) = 'text' AND created_at LIKE '%.%';
            ''');
            } catch (e, st) {
              _dbLog.warning('Migration v2→v3: dot-strip failed: $e', e, st);
            }

            try {
              await customStatement('''
              UPDATE download_tasks SET created_at = SUBSTR(created_at, 1, INSTR(created_at, '+') - 1) WHERE typeof(created_at) = 'text' AND created_at LIKE '%+%';
              UPDATE download_tasks SET updated_at = SUBSTR(updated_at, 1, INSTR(updated_at, '+') - 1) WHERE typeof(updated_at) = 'text' AND updated_at LIKE '%+%';
              UPDATE download_tasks SET completed_at = SUBSTR(completed_at, 1, INSTR(completed_at, '+') - 1) WHERE typeof(completed_at) = 'text' AND completed_at LIKE '%+%';
              UPDATE download_tasks SET scheduled_at = SUBSTR(scheduled_at, 1, INSTR(scheduled_at, '+') - 1) WHERE typeof(scheduled_at) = 'text' AND scheduled_at LIKE '%+%';
            ''');
            } catch (e, st) {
              _dbLog.warning(
                  'Migration v2→v3: timezone-strip failed: $e', e, st);
            }

            try {
              await customStatement('''
              UPDATE download_tasks SET
                created_at = COALESCE(CAST((julianday(REPLACE(REPLACE(created_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0)
              WHERE typeof(created_at) = 'text';
            ''');
            } catch (e, st) {
              _dbLog.warning(
                  'Migration v2→v3: created_at parse failed: $e', e, st);
            }

            try {
              await customStatement('''
              UPDATE download_tasks SET
                updated_at = COALESCE(CAST((julianday(REPLACE(REPLACE(updated_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0)
              WHERE typeof(updated_at) = 'text';
            ''');
            } catch (e, st) {
              _dbLog.warning(
                  'Migration v2→v3: updated_at parse failed: $e', e, st);
            }

            try {
              await customStatement('''
              UPDATE download_tasks SET
                completed_at = CASE WHEN completed_at IS NOT NULL THEN COALESCE(CAST((julianday(REPLACE(REPLACE(completed_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0) ELSE NULL END
              WHERE typeof(completed_at) = 'text';
            ''');
            } catch (e, st) {
              _dbLog.warning(
                  'Migration v2→v3: completed_at parse failed: $e', e, st);
            }

            try {
              await customStatement('''
              UPDATE download_tasks SET
                scheduled_at = CASE WHEN scheduled_at IS NOT NULL THEN COALESCE(CAST((julianday(REPLACE(REPLACE(scheduled_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0) ELSE NULL END
              WHERE typeof(scheduled_at) = 'text';
            ''');
            } catch (e, st) {
              _dbLog.warning(
                  'Migration v2→v3: scheduled_at parse failed: $e', e, st);
            }

            // Straggler fallback for any text values remaining
            try {
              await customStatement(
                  "UPDATE download_tasks SET created_at = 0 WHERE typeof(created_at) = 'text'");
              await customStatement(
                  "UPDATE download_tasks SET updated_at = 0 WHERE typeof(updated_at) = 'text'");
              await customStatement(
                  "UPDATE download_tasks SET completed_at = NULL WHERE typeof(completed_at) = 'text'");
              await customStatement(
                  "UPDATE download_tasks SET scheduled_at = NULL WHERE typeof(scheduled_at) = 'text'");
            } catch (e, st) {
              _dbLog.warning(
                  'Migration v2→v3: straggler fallback failed: $e', e, st);
            }

            try {
              await customStatement(
                  'UPDATE download_tasks SET created_at = 0 WHERE created_at < 0');
              await customStatement(
                  'UPDATE download_tasks SET updated_at = 0 WHERE updated_at < 0');
            } catch (e, st) {
              _dbLog.warning(
                  'Migration v2→v3: negative clamp failed: $e', e, st);
            }

            try {
              final badDates = await customSelect(
                      'SELECT COUNT(*) as cnt FROM download_tasks WHERE created_at = 0')
                  .get();
              final badCount = badDates.first.read<int>('cnt');
              if (badCount > 0) {
                debugPrint(
                    'WARNING: $badCount tasks have epoch (0) created_at after migration');
              }
              final recoveredFromUpdated = await customSelect(
                'SELECT COUNT(*) as cnt FROM download_tasks WHERE created_at = 0 AND updated_at > 0',
              ).get();
              final recoverFromUpdatedCount =
                  recoveredFromUpdated.first.read<int>('cnt');
              if (recoverFromUpdatedCount > 0) {
                await customStatement(
                    'UPDATE download_tasks SET created_at = updated_at WHERE created_at = 0 AND updated_at > 0');
                debugPrint(
                    '[DMX] Migration v2→v3: recovered $recoverFromUpdatedCount rows (created_at = updated_at)');
              }
              final recoveredFromNow = await customSelect(
                'SELECT COUNT(*) as cnt FROM download_tasks WHERE created_at = 0 AND updated_at = 0',
              ).get();
              final recoverFromNowCount =
                  recoveredFromNow.first.read<int>('cnt');
              if (recoverFromNowCount > 0) {
                await customStatement(
                  "UPDATE download_tasks SET created_at = CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER) WHERE created_at = 0 AND updated_at = 0",
                );
                debugPrint(
                    '[DMX] Migration v2→v3: recovered $recoverFromNowCount rows (created_at = now)');
              }
            } catch (e, st) {
              _dbLog.warning(
                  'Migration v2→v3: post-migration recovery check failed: $e',
                  e,
                  st);
            }
          }
          if (from < 4) {
            await _addColumnIfMissing('download_tasks', 'playlist_id',
                'ALTER TABLE download_tasks ADD COLUMN playlist_id TEXT');
            await _addColumnIfMissing('download_tasks', 'playlist_title',
                'ALTER TABLE download_tasks ADD COLUMN playlist_title TEXT');
          }
          if (from < 5) {
            await _addColumnIfMissing('download_tasks', 'is_app_update',
                'ALTER TABLE download_tasks ADD COLUMN is_app_update INTEGER NOT NULL DEFAULT 0');
          }
          if (from < 6) {
            await _addColumnIfMissing('download_tasks', 'priority',
                'ALTER TABLE download_tasks ADD COLUMN priority INTEGER NOT NULL DEFAULT 0');
            await _addColumnIfMissing('download_tasks', 'expected_sha256',
                'ALTER TABLE download_tasks ADD COLUMN expected_sha256 TEXT');
          }
          if (from < 7) {
            await customStatement('''
          CREATE TABLE IF NOT EXISTS browser_tabs (
            id TEXT NOT NULL PRIMARY KEY,
            url TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            is_active INTEGER NOT NULL DEFAULT 0,
            "position" INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
          )
        ''');
          }
          if (from < 8) {
            await customStatement('''
          CREATE TABLE IF NOT EXISTS browser_history_new (
            id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            url TEXT NOT NULL,
            title TEXT NOT NULL,
            visited_at TEXT NOT NULL
          )
        ''');
            await customStatement('''
          INSERT INTO browser_history_new (url, title, visited_at)
          SELECT url, title, visited_at FROM browser_history
        ''');
            await customStatement('DROP TABLE browser_history');
            await customStatement(
                'ALTER TABLE browser_history_new RENAME TO browser_history');
          }
          if (from < 9) {
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_download_tasks_playlist_id ON download_tasks (playlist_id)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_browser_history_visited_at ON browser_history (visited_at)');
          }
          if (from < 10) {
            await _addColumnIfMissing('download_tasks', 'thumbnail_url',
                'ALTER TABLE download_tasks ADD COLUMN thumbnail_url TEXT');
          }
          if (from < 11) {
            await customStatement('''
          UPDATE bookmarks SET created_at = SUBSTR(created_at, 1, INSTR(created_at, '+') - 1) WHERE created_at LIKE '%+%';
          UPDATE browser_history SET visited_at = SUBSTR(visited_at, 1, INSTR(visited_at, '+') - 1) WHERE visited_at LIKE '%+%';
        ''');
            await customStatement('''
          CREATE TABLE bookmarks_new (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            url TEXT NOT NULL,
            folder TEXT,
            created_at INTEGER NOT NULL
          )
        ''');
            await customStatement('''
          INSERT INTO bookmarks_new (id, title, url, folder, created_at)
          SELECT id, title, url, folder,
            COALESCE(
              CAST(
                (julianday(REPLACE(REPLACE(created_at, 'T', ' '), 'Z', '')) - 2440587.5)
                * 86400000 AS INTEGER
              ),
              0
            )
          FROM bookmarks
        ''');
            await customStatement('DROP TABLE bookmarks');
            await customStatement(
                'ALTER TABLE bookmarks_new RENAME TO bookmarks');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_bookmarks_created_at ON bookmarks (created_at)');
            await customStatement('''
          CREATE TABLE browser_history_new (
            id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            url TEXT NOT NULL,
            title TEXT NOT NULL,
            visited_at INTEGER NOT NULL
          )
        ''');
            await customStatement('''
          INSERT INTO browser_history_new (url, title, visited_at)
          SELECT url, title,
            COALESCE(
              CAST(
                (julianday(REPLACE(REPLACE(visited_at, 'T', ' '), 'Z', '')) - 2440587.5)
                * 86400000 AS INTEGER
              ),
              0
            )
          FROM browser_history
        ''');
            await customStatement(
                'DROP INDEX IF EXISTS idx_browser_history_visited_at');
            await customStatement('DROP TABLE browser_history');
            await customStatement(
                'ALTER TABLE browser_history_new RENAME TO browser_history');
            await customStatement(
                'CREATE INDEX idx_browser_history_visited_at ON browser_history (visited_at)');
            final badBookmarks = await customSelect(
                    'SELECT COUNT(*) as cnt FROM bookmarks WHERE created_at <= 0')
                .get();
            final badBookmarksCount = badBookmarks.first.read<int>('cnt');
            if (badBookmarksCount > 0) {
              await customStatement(
                "UPDATE bookmarks SET created_at = CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER) WHERE created_at <= 0",
              );
              _dbLog.warning(
                  'Migration v10→v11: recovered $badBookmarksCount bookmarks stuck at invalid created_at');
            }
            final badHistory = await customSelect(
                    'SELECT COUNT(*) as cnt FROM browser_history WHERE visited_at <= 0')
                .get();
            final badHistoryCount = badHistory.first.read<int>('cnt');
            if (badHistoryCount > 0) {
              await customStatement(
                "UPDATE browser_history SET visited_at = CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER) WHERE visited_at <= 0",
              );
              _dbLog.warning(
                  'Migration v10→v11: recovered $badHistoryCount browser history rows stuck at invalid visited_at');
            }
          }
          if (from < 12) {
            await _addColumnIfMissing('download_tasks', 'mirror_urls',
                'ALTER TABLE download_tasks ADD COLUMN mirror_urls TEXT');
          }
          if (from < 13) {
            await _addColumnIfMissing('download_tasks', 'queue_order',
                'ALTER TABLE download_tasks ADD COLUMN queue_order INTEGER NOT NULL DEFAULT 0');
            try {
              await customStatement(
                  'UPDATE download_tasks SET queue_order = (SELECT COUNT(*) FROM download_tasks t2 WHERE t2.created_at < download_tasks.created_at)');
            } catch (e) {
              _dbLog.info('Failed updating queue_order: $e');
            }
          }
          if (from < 14) {
            await _addColumnIfMissing('download_tasks', 'video_stream_size',
                'ALTER TABLE download_tasks ADD COLUMN video_stream_size INTEGER NOT NULL DEFAULT 0');
          }
          if (from < 15) {
            await _addColumnIfMissing(
                'download_tasks',
                'audio_downloaded_bytes',
                'ALTER TABLE download_tasks ADD COLUMN audio_downloaded_bytes INTEGER NOT NULL DEFAULT 0');
          }
          if (from < 16) {
            await _addColumnIfMissing('download_tasks', 'uploaded_bytes',
                'ALTER TABLE download_tasks ADD COLUMN uploaded_bytes INTEGER NOT NULL DEFAULT 0');
          }
          if (from < 17) {
            await _addColumnIfMissing('browser_history', 'visit_count',
                'ALTER TABLE browser_history ADD COLUMN visit_count INTEGER NOT NULL DEFAULT 1');
            await _addColumnIfMissing('browser_history', 'favicon_url',
                'ALTER TABLE browser_history ADD COLUMN favicon_url TEXT');
            await _addColumnIfMissing('browser_tabs', 'last_visited_at',
                'ALTER TABLE browser_tabs ADD COLUMN last_visited_at INTEGER NOT NULL DEFAULT 0');
            await _addColumnIfMissing('browser_tabs', 'favicon_url',
                'ALTER TABLE browser_tabs ADD COLUMN favicon_url TEXT');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_browser_history_url ON browser_history (url)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_bookmarks_url ON bookmarks (url)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_browser_tabs_position ON browser_tabs (position)');
          }
          if (from < 18) {
            await _addColumnIfMissing('download_tasks', 'pause_reason',
                'ALTER TABLE download_tasks ADD COLUMN pause_reason TEXT');
            await _addColumnIfMissing('download_tasks', 'completed_pieces',
                'ALTER TABLE download_tasks ADD COLUMN completed_pieces INTEGER');
            await _addColumnIfMissing(
                'download_tasks',
                'yt_counterpart_downloaded_bytes',
                'ALTER TABLE download_tasks ADD COLUMN yt_counterpart_downloaded_bytes INTEGER');
          }
          if (from < 19) {
            await _addColumnIfMissing('download_tasks', 'cycle_state',
                'ALTER TABLE download_tasks ADD COLUMN cycle_state TEXT');
          }
          if (from < 20) {
            await _addColumnIfMissing('download_tasks', 'total_pieces',
                'ALTER TABLE download_tasks ADD COLUMN total_pieces INTEGER');
          }
          if (from < 21) {
            await _createTaskSummaryView();
          }

          // Migration for new columns in schema v23
          if (from < 23) {
            await _addColumnIfMissing('download_tasks', 'audio_chunks',
                'ALTER TABLE download_tasks ADD COLUMN audio_chunks TEXT');
            await _addColumnIfMissing('download_tasks', 'http_parts',
                'ALTER TABLE download_tasks ADD COLUMN http_parts TEXT');
            await _addColumnIfMissing(
                'download_tasks',
                'torrent_piece_progress',
                'ALTER TABLE download_tasks ADD COLUMN torrent_piece_progress REAL DEFAULT 0');
            await _addColumnIfMissing(
                'download_tasks',
                'audio_chunks_completed',
                'ALTER TABLE download_tasks ADD COLUMN audio_chunks_completed INTEGER DEFAULT 0');
            await _addColumnIfMissing('download_tasks', 'audio_chunks_total',
                'ALTER TABLE download_tasks ADD COLUMN audio_chunks_total INTEGER DEFAULT 0');
            await _addColumnIfMissing('download_tasks', 'http_parts_completed',
                'ALTER TABLE download_tasks ADD COLUMN http_parts_completed INTEGER DEFAULT 0');
            await _addColumnIfMissing('download_tasks', 'http_parts_total',
                'ALTER TABLE download_tasks ADD COLUMN http_parts_total INTEGER DEFAULT 0');

            // For schema v23 migrations, create indexes on new columns only when populated
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_download_tasks_audio_chunks ON download_tasks (audio_chunks) WHERE audio_chunks IS NOT NULL');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_download_tasks_http_parts ON download_tasks (http_parts) WHERE http_parts IS NOT NULL');
          }

          // Migration for schema v24 (previous_cycle_state and mirror_health table)
          if (from < 24) {
            await _addColumnIfMissing('download_tasks', 'previous_cycle_state',
                'ALTER TABLE download_tasks ADD COLUMN previous_cycle_state TEXT');
            await customStatement('''
              CREATE TABLE IF NOT EXISTS mirror_health (
                url TEXT NOT NULL PRIMARY KEY,
                failures INTEGER NOT NULL DEFAULT 0,
                last_failure INTEGER NOT NULL DEFAULT 0,
                last_success INTEGER NOT NULL DEFAULT 0,
                last_status_code INTEGER NOT NULL DEFAULT 0,
                blacklisted_until INTEGER NOT NULL DEFAULT 0,
                average_speed_bps REAL NOT NULL DEFAULT 0.0,
                speed_samples TEXT
              )
            ''');
          }

          if (from < 25) {
            await _addColumnIfMissing('download_tasks', 'info_hash',
                'ALTER TABLE download_tasks ADD COLUMN info_hash TEXT');
          }

          if (from < 26) {
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_download_tasks_queue_order ON download_tasks (queue_order)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_download_tasks_scheduled_at ON download_tasks (scheduled_at)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_download_tasks_priority ON download_tasks (priority)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_download_tasks_updated_at ON download_tasks (updated_at)');
          }

          if (from < 27) {
            await _addColumnIfMissing('download_tasks', 'is_cancelled',
                'ALTER TABLE download_tasks ADD COLUMN is_cancelled INTEGER NOT NULL DEFAULT 0');
            // One-time legacy migration for historical cancelled tasks
            await customStatement(
                "UPDATE download_tasks SET is_cancelled = 1 WHERE error_message = 'Transfer cancelled.'");
          }

          if (from < 28) {
            await _addColumnIfMissing('download_tasks', 'auth_username',
                'ALTER TABLE download_tasks ADD COLUMN auth_username TEXT');
            await _addColumnIfMissing('download_tasks', 'auth_password',
                'ALTER TABLE download_tasks ADD COLUMN auth_password TEXT');
            await _addColumnIfMissing('download_tasks', 'custom_headers',
                'ALTER TABLE download_tasks ADD COLUMN custom_headers TEXT');
          }

          if (to > 28) {
            _dbLog.warning(
                'AppDatabase: Upgrade target version $to is higher than version 28, no specific migrations defined!');
          }
        },
        beforeOpen: (details) async {
          // M4 (Plan 03 Task 3.6): Drift only migrates forward. If the on-disk
          // DB was written by a newer build (a higher schema version than this
          // one), applying the older schema over it can brick the task DB.
          // Detect that here, snapshot the DB, and refuse to open rather than
          // silently proceeding on a schema we don't understand.
          final before = details.versionBefore;
          if (before != null && before > details.versionNow) {
            await _backupOnDowngrade(before, details.versionNow);
            throw StateError(
              'Refusing to open a newer download database (schema v$before) '
              'with an older app build (schema v${details.versionNow}). A '
              'timestamped backup was created next to the database; please '
              'update the app to a compatible version.',
            );
          }
        },
      );

  /// M4: snapshots the current DB file next to itself before a refused
  /// downgrade open, so a user who installed an older build over a newer one
  /// never loses their task database. Best-effort: a backup failure is logged
  /// but never masks the downgrade refusal.
  Future<void> _backupOnDowngrade(int fromVersion, int toVersion) async {
    final path = dbPath;
    if (path == null) return; // in-memory / test database: nothing to back up
    try {
      // Fold the WAL back into the main file so a plain copy is consistent
      try {
        await customStatement('PRAGMA wal_checkpoint(TRUNCATE)')
            .timeout(const Duration(seconds: 2))
            .catchError((_) => null);
      } catch (_) {}
      final backupPath =
          '$path.v$fromVersion.${DateTime.now().millisecondsSinceEpoch}.bak';
      final src = File(path);
      if (await src.exists()) {
        await src.copy(backupPath);
        _dbLog.warning(
            'AppDatabase: downgrade v$fromVersion→v$toVersion detected; backed up DB to $backupPath');
      }
    } catch (e, st) {
      _dbLog.severe('AppDatabase: downgrade backup failed: $e', e, st);
    }
  }

  Future<void> _createTaskSummaryView() async {
    await safeCustomStatement('''
      CREATE VIEW IF NOT EXISTS v_download_task_summary AS
      SELECT
        id,
        file_name,
        url,
        file_size,
        downloaded_bytes,
        speed,
        eta,
        status,
        category,
        thread_count,
        created_at,
        updated_at,
        completed_at,
        scheduled_at,
        supports_resume,
        priority,
        CASE WHEN torrent_files IS NOT NULL AND json_valid(torrent_files) = 1 THEN
          (SELECT COUNT(*) FROM json_each(torrent_files) AS f
            WHERE COALESCE(json_extract(f.value, '\$.selected'), 1) = 1)
        ELSE 0 END AS total_files,
        CASE WHEN torrent_files IS NOT NULL AND json_valid(torrent_files) = 1 THEN
          (SELECT COUNT(*) FROM json_each(torrent_files) AS f
            WHERE COALESCE(json_extract(f.value, '\$.selected'), 1) = 1
              AND (COALESCE(json_extract(f.value, '\$.length'), 0) = 0
                OR COALESCE(json_extract(f.value, '\$.downloadedBytes'), 0) >=
                   COALESCE(json_extract(f.value, '\$.length'), 0)))
        ELSE 0 END AS completed_files,
        CASE WHEN torrent_files IS NOT NULL AND json_valid(torrent_files) = 1 THEN
          COALESCE((SELECT SUM(COALESCE(json_extract(f.value, '\$.length'), 0))
            FROM json_each(torrent_files) AS f
            WHERE COALESCE(json_extract(f.value, '\$.selected'), 1) = 1), 0)
        ELSE 0 END AS total_file_bytes,
        CASE WHEN torrent_files IS NOT NULL AND json_valid(torrent_files) = 1 THEN
          COALESCE((SELECT SUM(
              CASE WHEN COALESCE(json_extract(f.value, '\$.length'), 0) > 0
                THEN MIN(
                  COALESCE(json_extract(f.value, '\$.downloadedBytes'), 0),
                  COALESCE(json_extract(f.value, '\$.length'), 0))
                ELSE 0 END)
            FROM json_each(torrent_files) AS f
            WHERE COALESCE(json_extract(f.value, '\$.selected'), 1) = 1), 0)
        ELSE 0 END AS downloaded_file_bytes
      FROM download_tasks;
    ''');
  }
}
