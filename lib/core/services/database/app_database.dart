import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import '../logging_service.dart';

part 'app_database.g.dart';

final _dbLog = LoggingService.logger('AppDatabase');

/// Binary packed format converter for chunk and torrent file detail blobs (FIX-12).
/// Format: [int32 count, [int64 start, int64 end, int64 size, int64 downloaded, int8 isComplete] * count]
class BinaryChunkBlobConverter {
  const BinaryChunkBlobConverter._();

  static Uint8List pack(
    List<({int start, int end, int size, int downloaded, bool isComplete})> items,
  ) {
    final count = items.length;
    final byteData = ByteData(4 + count * 33);
    byteData.setInt32(0, count, Endian.big);
    int offset = 4;
    for (final item in items) {
      byteData.setInt64(offset, item.start, Endian.big);
      byteData.setInt64(offset + 8, item.end, Endian.big);
      byteData.setInt64(offset + 16, item.size, Endian.big);
      byteData.setInt64(offset + 24, item.downloaded, Endian.big);
      byteData.setUint8(offset + 32, item.isComplete ? 1 : 0);
      offset += 33;
    }
    return byteData.buffer.asUint8List();
  }

  static List<({int start, int end, int size, int downloaded, bool isComplete})>
      unpack(Uint8List bytes) {
    if (bytes.length < 4) {
      return _tryParseJson(bytes);
    }
    // Fallback detection: if first byte is '[' or '{' (ASCII 91 or 123), it is json text
    if (bytes[0] == 0x5B || bytes[0] == 0x7B) {
      return _tryParseJson(bytes);
    }
    try {
      final byteData = ByteData.sublistView(bytes);
      final count = byteData.getInt32(0, Endian.big);
      if (count <= 0 || bytes.length < 4 + count * 33) {
        return _tryParseJson(bytes);
      }
      final result = <({
        int start,
        int end,
        int size,
        int downloaded,
        bool isComplete
      })>[];
      int offset = 4;
      for (int i = 0; i < count; i++) {
        final start = byteData.getInt64(offset, Endian.big);
        final end = byteData.getInt64(offset + 8, Endian.big);
        final size = byteData.getInt64(offset + 16, Endian.big);
        final downloaded = byteData.getInt64(offset + 24, Endian.big);
        final isComplete = byteData.getUint8(offset + 32) != 0;
        offset += 33;
        result.add((
          start: start,
          end: end,
          size: size,
          downloaded: downloaded,
          isComplete: isComplete,
        ));
      }
      return result;
    } catch (_) {
      return _tryParseJson(bytes);
    }
  }

  static List<({int start, int end, int size, int downloaded, bool isComplete})>
      _tryParseJson(Uint8List bytes) {
    try {
      final text = utf8.decode(bytes);
      final decoded = jsonDecode(text);
      if (decoded is List) {
        return decoded.map((e) {
          if (e is Map) {
            return (
              start: (e['start'] as num?)?.toInt() ?? 0,
              end: (e['end'] as num?)?.toInt() ?? 0,
              size: (e['size'] as num?)?.toInt() ?? 0,
              downloaded: (e['downloaded'] as num?)?.toInt() ?? 0,
              isComplete: (e['isComplete'] as bool?) ?? false,
            );
          }
          return (start: 0, end: 0, size: 0, downloaded: 0, isComplete: false);
        }).toList();
      }
    } catch (_) {}
    return [];
  }
}

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
    final regex = RegExp(r'\{[^{}]*\}');
    final matches = regex.allMatches(fromDb);
    for (final match in matches) {
      final objStr = match.group(0);
      if (objStr != null) {
        try {
          final obj = jsonDecode(objStr);
          if (obj is Map) {
            result.add(Map<String, dynamic>.from(obj));
          }
        } catch (_) {}
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
  static final Map<String, List<double>> _recoveryCache = {};
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
        final result = _recoverDoubleList(fromDb);
        if (result.isNotEmpty) {
          if (_recoveryCache.length >= _recoveryCacheLimit) {
            _recoveryCache.clear();
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
  static final Map<String, List<Map<String, dynamic>>> _recoveryCache = {};
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
        final result = _recoverTorrentFiles(fromDb);
        if (result.isNotEmpty) {
          if (_recoveryCache.length >= _recoveryCacheLimit) {
            _recoveryCache.clear();
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
    return jsonEncode(value);
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

  @override
  Set<Column> get primaryKey => {id};
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

LazyDatabase _openConnection(String path) {
  return LazyDatabase(() async {
    final file = File(path);
    return NativeDatabase.createInBackground(
      file,
      setup: (database) {
        database.execute('PRAGMA journal_mode=WAL;');
        database.execute('PRAGMA synchronous=NORMAL;');
        database.execute('PRAGMA foreign_keys=ON;');
        database.execute('PRAGMA busy_timeout=5000;');
      },
    );
  });
}

@DriftDatabase(tables: [DownloadTasks, Bookmarks, BrowserHistory, BrowserTabs])
class AppDatabase extends _$AppDatabase {
  final String? dbPath;
  AppDatabase(String path) : dbPath = path, super(_openConnection(path));
  AppDatabase.forTesting(super.e) : dbPath = null;

  @override
  int get schemaVersion => 23;

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
              'CREATE INDEX idx_browser_history_visited_at ON browser_history (visited_at)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_bookmarks_created_at ON bookmarks (created_at)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_browser_history_url ON browser_history (url)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_bookmarks_url ON bookmarks (url)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_browser_tabs_position ON browser_tabs (position)');
          await _createTaskSummaryView();
        },
        onUpgrade: (m, from, to) async {
          debugPrint('AppDatabase: Upgrading schema from $from to $to');
          if (from < 2) {
            await m.addColumn(downloadTasks, downloadTasks.notes);
          }
          if (from < 3) {
            await customStatement('BEGIN TRANSACTION');
            try {
              await customStatement('''
            UPDATE download_tasks SET created_at =
              SUBSTR(created_at, 1, INSTR(created_at, '.') - 1)
            WHERE typeof(created_at) = 'text' AND created_at LIKE '%.%';
          ''');
              await customStatement('''
            UPDATE download_tasks SET created_at = SUBSTR(created_at, 1, INSTR(created_at, '+') - 1) WHERE typeof(created_at) = 'text' AND created_at LIKE '%+%';
            UPDATE download_tasks SET updated_at = SUBSTR(updated_at, 1, INSTR(updated_at, '+') - 1) WHERE typeof(updated_at) = 'text' AND updated_at LIKE '%+%';
            UPDATE download_tasks SET completed_at = SUBSTR(completed_at, 1, INSTR(completed_at, '+') - 1) WHERE typeof(completed_at) = 'text' AND completed_at LIKE '%+%';
            UPDATE download_tasks SET scheduled_at = SUBSTR(scheduled_at, 1, INSTR(scheduled_at, '+') - 1) WHERE typeof(scheduled_at) = 'text' AND scheduled_at LIKE '%+%';
          ''');
              await customStatement('''
            UPDATE download_tasks SET
              created_at = COALESCE(CAST((julianday(REPLACE(REPLACE(created_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0)
            WHERE typeof(created_at) = 'text';
          ''');
              await customStatement('''
            UPDATE download_tasks SET
              updated_at = COALESCE(CAST((julianday(REPLACE(REPLACE(updated_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0)
            WHERE typeof(updated_at) = 'text';
          ''');
              await customStatement('''
            UPDATE download_tasks SET
              completed_at = CASE WHEN completed_at IS NOT NULL THEN COALESCE(CAST((julianday(REPLACE(REPLACE(completed_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0) ELSE NULL END
            WHERE typeof(completed_at) = 'text';
          ''');
              await customStatement('''
            UPDATE download_tasks SET
              scheduled_at = CASE WHEN scheduled_at IS NOT NULL THEN COALESCE(CAST((julianday(REPLACE(REPLACE(scheduled_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0) ELSE NULL END
            WHERE typeof(scheduled_at) = 'text';
          ''');
              await customStatement(
                  'UPDATE download_tasks SET created_at = 0 WHERE created_at < 0');
              await customStatement(
                  'UPDATE download_tasks SET updated_at = 0 WHERE updated_at < 0');
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
              await customStatement('COMMIT');
            } catch (e) {
              await customStatement('ROLLBACK');
              rethrow;
            }
          }
          if (from < 4) {
            await m.addColumn(downloadTasks, downloadTasks.playlistId);
            await m.addColumn(downloadTasks, downloadTasks.playlistTitle);
          }
          if (from < 5) {
            await m.addColumn(downloadTasks, downloadTasks.isAppUpdate);
          }
          if (from < 6) {
            await m.addColumn(downloadTasks, downloadTasks.priority);
            await m.addColumn(downloadTasks, downloadTasks.expectedSha256);
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
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN thumbnail_url TEXT');
            } catch (e) {
              _dbLog.info('Column thumbnail_url may already exist: $e');
            }
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
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN mirror_urls TEXT');
            } catch (e) {
              _dbLog.info('Column mirror_urls may already exist: $e');
            }
          }
          if (from < 13) {
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN queue_order INTEGER NOT NULL DEFAULT 0');
            } catch (e) {
              _dbLog.info('Column queue_order may already exist: $e');
            }
            try {
              await customStatement(
                  'UPDATE download_tasks SET queue_order = (SELECT COUNT(*) FROM download_tasks t2 WHERE t2.created_at < download_tasks.created_at)');
            } catch (e) {
              _dbLog.info('Failed updating queue_order: $e');
            }
          }
          if (from < 14) {
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN video_stream_size INTEGER NOT NULL DEFAULT 0');
            } catch (e) {
              _dbLog.info('Column video_stream_size may already exist: $e');
            }
          }
          if (from < 15) {
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN audio_downloaded_bytes INTEGER NOT NULL DEFAULT 0');
            } catch (e) {
              _dbLog
                  .info('Column audio_downloaded_bytes may already exist: $e');
            }
          }
          if (from < 16) {
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN uploaded_bytes INTEGER NOT NULL DEFAULT 0');
            } catch (e) {
              _dbLog.info('Column uploaded_bytes may already exist: $e');
            }
          }
          if (from < 17) {
            try {
              await customStatement(
                  'ALTER TABLE browser_history ADD COLUMN visit_count INTEGER NOT NULL DEFAULT 1');
            } catch (e) {
              _dbLog.info('Column visit_count may already exist: $e');
            }
            try {
              await customStatement(
                  'ALTER TABLE browser_history ADD COLUMN favicon_url TEXT');
            } catch (e) {
              _dbLog.info(
                  'Column favicon_url on browser_history may already exist: $e');
            }
            try {
              await customStatement(
                  'ALTER TABLE browser_tabs ADD COLUMN last_visited_at INTEGER NOT NULL DEFAULT 0');
            } catch (e) {
              _dbLog.info('Column last_visited_at may already exist: $e');
            }
            try {
              await customStatement(
                  'ALTER TABLE browser_tabs ADD COLUMN favicon_url TEXT');
            } catch (e) {
              _dbLog.info(
                  'Column favicon_url on browser_tabs may already exist: $e');
            }
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_browser_history_url ON browser_history (url)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_bookmarks_url ON bookmarks (url)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_browser_tabs_position ON browser_tabs (position)');
          }
          if (from < 18) {
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN pause_reason TEXT');
            } catch (e) {
              _dbLog.info('Column pause_reason may already exist: $e');
            }
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN completed_pieces INTEGER');
            } catch (e) {
              _dbLog.info('Column completed_pieces may already exist: $e');
            }
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN yt_counterpart_downloaded_bytes INTEGER');
            } catch (e) {
              _dbLog.info(
                  'Column yt_counterpart_downloaded_bytes may already exist: $e');
            }
          }
          if (from < 19) {
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN cycle_state TEXT');
            } catch (e) {
              _dbLog.info('Column cycle_state may already exist: $e');
            }
          }
          if (from < 20) {
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN total_pieces INTEGER');
            } catch (e) {
              _dbLog.info('Column total_pieces may already exist: $e');
            }
          }
          if (from < 21) {
            await _createTaskSummaryView();
          }
          if (from < 22) {
            _dbLog.info('Migration v21→v22: binary packed format support for chunks and torrentFiles');
          }
          // FIX 7.2: Migration for new columns in schema v23
          if (from < 23) {
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN audio_chunks TEXT');
            } catch (e) {
              _dbLog.info('Column audio_chunks may already exist: $e');
            }
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN http_parts TEXT');
            } catch (e) {
              _dbLog.info('Column http_parts may already exist: $e');
            }
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN torrent_piece_progress REAL DEFAULT 0');
            } catch (e) {
              _dbLog.info('Column torrent_piece_progress may already exist: $e');
            }
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN audio_chunks_completed INTEGER DEFAULT 0');
            } catch (e) {
              _dbLog.info('Column audio_chunks_completed may already exist: $e');
            }
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN audio_chunks_total INTEGER DEFAULT 0');
            } catch (e) {
              _dbLog.info('Column audio_chunks_total may already exist: $e');
            }
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN http_parts_completed INTEGER DEFAULT 0');
            } catch (e) {
              _dbLog.info('Column http_parts_completed may already exist: $e');
            }
            try {
              await customStatement(
                  'ALTER TABLE download_tasks ADD COLUMN http_parts_total INTEGER DEFAULT 0');
            } catch (e) {
              _dbLog.info('Column http_parts_total may already exist: $e');
            }
          }
          if (to > 23) {
            _dbLog.warning(
                'AppDatabase: Upgrade target version $to is higher than version 23, no specific migrations defined!');
          }
        },
      );

  Future<void> _createTaskSummaryView() async {
    await customStatement('''
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
