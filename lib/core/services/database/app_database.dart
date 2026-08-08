import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';

import '../logging_service.dart';

part 'app_database.g.dart';

final _dbLog = LoggingService.logger('AppDatabase');

// Type Converters
class DoubleListConverter extends TypeConverter<List<double>, String> {
  const DoubleListConverter();

  static final lastConversionError = ValueNotifier<String?>(null);

  @override
  List<double> fromSql(String fromDb) {
    if (fromDb.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(fromDb);
      if (decoded is List) {
        // FIX-C5: Wrap element parsing in per-element try-catch
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
      final msg =
          'DoubleListConverter: unexpected type ${decoded.runtimeType} for input';
      _dbLog.warning(msg);
      lastConversionError.value = msg;
      return [];
    } catch (e) {
      try {
        final matches = RegExp(r'[0-9]+(?:\.[0-9]+)?').allMatches(fromDb);
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
        if (result.isNotEmpty) {
          _dbLog.info(
              'Successfully recovered ${result.length} double items from corrupted JSON');
          return result;
        }
      } catch (recEx) {
        _dbLog.warning('DoubleListConverter regex recovery failed: $recEx');
      }

      final msg = 'Error decoding DoubleList from DB: $e';
      _dbLog.warning(msg);
      lastConversionError.value = msg;
      return [];
    }
  }

  @override
  String toSql(List<double> value) => jsonEncode(value);
}

class TorrentFilesConverter
    extends TypeConverter<List<Map<String, dynamic>>, String> {
  const TorrentFilesConverter();

  static final lastConversionError = ValueNotifier<String?>(null);

  @override
  List<Map<String, dynamic>> fromSql(String fromDb) {
    if (fromDb.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(fromDb);
      if (decoded is List) {
        // FIX-C5: Wrap element parsing in per-element try-catch
        final result = <Map<String, dynamic>>[];
        for (final e in decoded) {
          try {
            if (e is Map) {
              result.add(Map<String, dynamic>.from(e));
            }
          } catch (_) {}
        }
        return result;
      }

      final msg =
          'TorrentFilesConverter: unexpected type ${decoded.runtimeType} for input';
      _dbLog.warning(msg);
      lastConversionError.value = msg;
      return [];
    } catch (e) {
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
        if (result.isNotEmpty) {
          _dbLog.info(
              'Successfully recovered ${result.length} torrent file entries from corrupted JSON');
          return result;
        }
      } catch (recEx) {
        _dbLog.warning('TorrentFilesConverter regex recovery failed: $recEx');
      }

      final msg = 'Error decoding TorrentFiles from DB: $e';
      _dbLog.warning(msg);
      lastConversionError.value = msg;
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
        'StringListConverter: unexpected type ${decoded.runtimeType} for input',
      );
      return [];
    } catch (e) {
      _dbLog.warning('Error decoding StringList from DB: $e');
      return [];
    }
  }

  @override
  String toSql(List<String> value) => jsonEncode(value);
}

// Tables
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
      integer().withDefault(const Constant(0))(); // FIX-AUDIT-01
  IntColumn get videoStreamSize =>
      integer().withDefault(const Constant(0))(); // FIX-B4
  RealColumn get audioProgress => real().withDefault(const Constant(0.0))();
  BoolColumn get pausedByUser => boolean().withDefault(const Constant(false))();
  TextColumn get youtubeQualityPreset => text().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get playlistId => text().nullable()();
  TextColumn get playlistTitle => text().nullable()();
  TextColumn get thumbnailUrl => text().nullable()();
  BoolColumn get isAppUpdate => boolean().withDefault(const Constant(false))();
  IntColumn get uploadedBytes =>
      integer().withDefault(const Constant(0))(); // FIX F5
  IntColumn get priority => integer().withDefault(const Constant(0))();
  IntColumn get queueOrder =>
      integer().withDefault(const Constant(0))(); // FIX(13)
  TextColumn get expectedSha256 => text().nullable()();
  TextColumn get mirrorUrls => text()
      .map(const NullAwareTypeConverter.wrap(StringListConverter()))
      .nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DbBookmark')
class Bookmarks extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get url => text()();
  TextColumn get folder => text().nullable()();
  // FIX(4): INTEGER ms-epoch since v11. Storing ISO strings in TEXT made
  // "created_at DESC" ordering lexicographic and inconsistent.
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DbBrowserHistory')
class BrowserHistory extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get url => text()();
  TextColumn get title => text()();
  // FIX(5): INTEGER ms-epoch since v11 (was TEXT ISO8601).
  IntColumn get visitedAt => integer()();
  // FIX-BH-01: Track visit count for deduplication — repeated visits
  // to the same URL increment this instead of creating duplicate rows.
  IntColumn get visitCount => integer().withDefault(const Constant(1))();
  // FIX-BH-02: Store favicon URL for history UI display.
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
  // FIX-BT-01: Track last visited time for tab restoration ordering.
  IntColumn get lastVisitedAt => integer().withDefault(const Constant(0))();
  // FIX-BT-02: Store favicon URL for tab bar display.
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
        database.execute('PRAGMA foreign_keys=ON;');
        database.execute('PRAGMA busy_timeout=5000;');
      },
    );
  });
}

@DriftDatabase(tables: [DownloadTasks, Bookmarks, BrowserHistory, BrowserTabs])
class AppDatabase extends _$AppDatabase {
  AppDatabase(String path) : super(_openConnection(path));
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 17; // FIX F5 + FIX-BH/BT

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // Create indexes on fresh database
          await customStatement(
            'CREATE INDEX idx_download_tasks_status ON download_tasks (status)',
          );
          await customStatement(
            'CREATE INDEX idx_download_tasks_category ON download_tasks (category)',
          );
          await customStatement(
            'CREATE INDEX idx_download_tasks_created_at ON download_tasks (created_at)',
          );
          await customStatement(
            'CREATE INDEX idx_download_tasks_playlist_id ON download_tasks (playlist_id)',
          );
          await customStatement(
            'CREATE INDEX idx_browser_history_visited_at ON browser_history (visited_at)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_bookmarks_created_at ON bookmarks (created_at)',
          );
          // FIX-BH-03: Index on browser_history.url for deduplication lookups.
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_browser_history_url ON browser_history (url)',
          );
          // FIX-BM-01: Index on bookmarks.url for duplicate checks.
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_bookmarks_url ON bookmarks (url)',
          );
          // FIX-BT-03: Index on browser_tabs.position for ordered loading.
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_browser_tabs_position ON browser_tabs (position)',
          );
        },
        onUpgrade: (m, from, to) async {
          debugPrint('AppDatabase: Upgrading schema from $from to $to');
          if (from < 2) {
            // Migration 1 -> 2: Add notes column
            await m.addColumn(downloadTasks, downloadTasks.notes);
          }
          if (from < 3) {
            // Migration 2 -> 3: Convert timestamp columns from text to integer
            // and add indexes.

            // Pre-migration: normalize date strings that julianday can't handle
            await customStatement('''
          UPDATE download_tasks SET created_at =
            SUBSTR(created_at, 1, INSTR(created_at, '.') - 1)
          WHERE created_at LIKE '%.%';
        ''');

            // Step 1: Create a temporary table with the new schema
            await customStatement('''
              CREATE TABLE download_tasks_new (
                id TEXT PRIMARY KEY NOT NULL,
                file_name TEXT NOT NULL,
                url TEXT NOT NULL,
                file_size INTEGER NOT NULL DEFAULT 0,
                downloaded_bytes INTEGER NOT NULL DEFAULT 0,
                speed REAL NOT NULL DEFAULT 0.0,
                eta INTEGER,
                category TEXT NOT NULL,
                status TEXT NOT NULL,
                save_path TEXT NOT NULL,
                local_file_path TEXT NOT NULL,
                temp_file_path TEXT NOT NULL,
                error_message TEXT,
                thread_count INTEGER NOT NULL,
                chunks TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                completed_at INTEGER,
                scheduled_at INTEGER,
                supports_resume INTEGER NOT NULL DEFAULT 0,
                speed_limit_kbps INTEGER NOT NULL DEFAULT 0,
                seeding_enabled INTEGER NOT NULL DEFAULT 0,
                seeding_limited INTEGER NOT NULL DEFAULT 0,
                seeding_limit_kbps INTEGER NOT NULL DEFAULT 500,
                torrent_files TEXT,
                download_page_url TEXT,
                merged_audio_url TEXT,
                audio_size INTEGER NOT NULL DEFAULT 0,
                audio_progress REAL NOT NULL DEFAULT 0.0,
                paused_by_user INTEGER NOT NULL DEFAULT 0,
                youtube_quality_preset TEXT,
                notes TEXT
              )
            ''');

            // Step 2: Copy data with date conversion
            // ISO8601 string dates are converted to milliseconds since epoch.
            // We use REPLACE to handle ISO8601 'T' and 'Z' which julianday doesn't parse natively.
            await customStatement('''
              INSERT INTO download_tasks_new (
                id, file_name, url, file_size, downloaded_bytes, speed, eta,
                category, status, save_path, local_file_path, temp_file_path,
                error_message, thread_count, chunks,
                created_at, updated_at, completed_at, scheduled_at,
                supports_resume, speed_limit_kbps, seeding_enabled,
                seeding_limited, seeding_limit_kbps, torrent_files,
                download_page_url, merged_audio_url, audio_size, audio_progress,
                paused_by_user, youtube_quality_preset, notes
              )
              SELECT
                id, file_name, url, file_size, downloaded_bytes, speed, eta,
                category, status, save_path, local_file_path, temp_file_path,
                error_message, thread_count, chunks,
                COALESCE(CAST((julianday(REPLACE(REPLACE(created_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0) as created_at,
                COALESCE(CAST((julianday(REPLACE(REPLACE(updated_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0) as updated_at,
                CASE WHEN completed_at IS NOT NULL THEN COALESCE(CAST((julianday(REPLACE(REPLACE(completed_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0) ELSE NULL END as completed_at,
                CASE WHEN scheduled_at IS NOT NULL THEN COALESCE(CAST((julianday(REPLACE(REPLACE(scheduled_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0) ELSE NULL END as scheduled_at,
                supports_resume, speed_limit_kbps, seeding_enabled,
                seeding_limited, seeding_limit_kbps, torrent_files,
                download_page_url, merged_audio_url, audio_size, audio_progress,
                paused_by_user, youtube_quality_preset, notes
              FROM download_tasks
            ''');

            // Step 3: Drop old table
            await customStatement('DROP TABLE download_tasks');

            // Step 4: Rename new table
            await customStatement(
              'ALTER TABLE download_tasks_new RENAME TO download_tasks',
            );

            // Step 5: Create indexes
            await customStatement(
              'CREATE INDEX idx_download_tasks_status ON download_tasks (status)',
            );
            await customStatement(
              'CREATE INDEX idx_download_tasks_category ON download_tasks (category)',
            );
            await customStatement(
              'CREATE INDEX idx_download_tasks_created_at ON download_tasks (created_at)',
            );

            // Recovery: fix negative epochs resulting from julianday timezone / pre-1970 dates
            await customStatement(
              'UPDATE download_tasks SET created_at = 0 WHERE created_at < 0',
            );
            await customStatement(
              'UPDATE download_tasks SET updated_at = 0 WHERE updated_at < 0',
            );

            // Post-migration: validate no dates are stuck at epoch
            final badDates = await customSelect(
              'SELECT COUNT(*) as cnt FROM download_tasks WHERE created_at = 0',
            ).get();
            final badCount = badDates.first.read<int>('cnt');
            if (badCount > 0) {
              debugPrint(
                'WARNING: $badCount tasks have epoch (0) created_at after migration',
              );
            }

            // Recovery: fix rows where created_at = 0 but updated_at > 0
            final recoveredFromUpdated = await customSelect(
              'SELECT COUNT(*) as cnt FROM download_tasks WHERE created_at = 0 AND updated_at > 0',
            ).get();
            final recoverFromUpdatedCount =
                recoveredFromUpdated.first.read<int>(
              'cnt',
            );
            if (recoverFromUpdatedCount > 0) {
              await customStatement(
                'UPDATE download_tasks SET created_at = updated_at WHERE created_at = 0 AND updated_at > 0',
              );
              debugPrint(
                '[DMX] Migration v2→v3: recovered $recoverFromUpdatedCount rows (created_at = updated_at)',
              );
            }

            // Recovery: fix rows where BOTH created_at and updated_at are 0
            final recoveredFromNow = await customSelect(
              'SELECT COUNT(*) as cnt FROM download_tasks WHERE created_at = 0 AND updated_at = 0',
            ).get();
            final recoverFromNowCount = recoveredFromNow.first.read<int>('cnt');
            if (recoverFromNowCount > 0) {
              await customStatement(
                "UPDATE download_tasks SET created_at = CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER) WHERE created_at = 0 AND updated_at = 0",
              );
              debugPrint(
                '[DMX] Migration v2→v3: recovered $recoverFromNowCount rows (created_at = now)',
              );
            }
          }
          if (from < 4) {
            // Migration 3 -> 4: Add playlistId and playlistTitle columns
            await m.addColumn(downloadTasks, downloadTasks.playlistId);
            await m.addColumn(downloadTasks, downloadTasks.playlistTitle);
          }
          if (from < 5) {
            // Migration 4 -> 5: Add isAppUpdate column
            await m.addColumn(downloadTasks, downloadTasks.isAppUpdate);
          }
          if (from < 6) {
            // Migration 5 -> 6: Add priority and expectedSha256 columns
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
            // Migration 7 -> 8: Change browser_history PK from text to auto-increment int
            await customStatement('''
          CREATE TABLE browser_history_new (
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
              'ALTER TABLE browser_history_new RENAME TO browser_history',
            );
          }
          if (from < 9) {
            // Migration 8 -> 9: Add indexes for playlist_id and visited_at
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_download_tasks_playlist_id ON download_tasks (playlist_id)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_browser_history_visited_at ON browser_history (visited_at)',
            );
          }
          if (from < 10) {
            // Migration 9 -> 10: Add thumbnail_url for YouTube playlist items
            await customStatement(
              'ALTER TABLE download_tasks ADD COLUMN thumbnail_url TEXT',
            );
          }
          if (from < 11) {
            // FIX(4)/FIX(5): Migration 10 -> 11. Convert bookmarks.created_at and
            // browser_history.visited_at from TEXT (ISO8601) to INTEGER (ms since
            // epoch), matching download_tasks and restoring correct numeric
            // ordering. ISO8601 strings are converted with the same julianday
            // formula used by the earlier download_tasks migration.

            // --- bookmarks ---
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
              'ALTER TABLE bookmarks_new RENAME TO bookmarks',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_bookmarks_created_at ON bookmarks (created_at)',
            );

            // --- browser_history ---
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
              'DROP INDEX IF EXISTS idx_browser_history_visited_at',
            );
            await customStatement('DROP TABLE browser_history');
            await customStatement(
              'ALTER TABLE browser_history_new RENAME TO browser_history',
            );
            await customStatement(
              'CREATE INDEX idx_browser_history_visited_at ON browser_history (visited_at)',
            );

            // Post-migration recovery for bookmarks: fix rows stuck at 0 or negative timestamps
            final badBookmarks = await customSelect(
              'SELECT COUNT(*) as cnt FROM bookmarks WHERE created_at <= 0',
            ).get();
            final badBookmarksCount = badBookmarks.first.read<int>('cnt');
            if (badBookmarksCount > 0) {
              await customStatement(
                "UPDATE bookmarks SET created_at = CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER) WHERE created_at <= 0",
              );
              _dbLog.warning(
                'Migration v10→v11: recovered $badBookmarksCount bookmarks stuck at invalid created_at',
              );
            }

            // Post-migration recovery for browser_history: fix rows stuck at 0 or negative timestamps
            final badHistory = await customSelect(
              'SELECT COUNT(*) as cnt FROM browser_history WHERE visited_at <= 0',
            ).get();
            final badHistoryCount = badHistory.first.read<int>('cnt');
            if (badHistoryCount > 0) {
              await customStatement(
                "UPDATE browser_history SET visited_at = CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER) WHERE visited_at <= 0",
              );
              _dbLog.warning(
                'Migration v10→v11: recovered $badHistoryCount browser history rows stuck at invalid visited_at',
              );
            }
          }
          if (from < 12) {
            // Migration 11 -> 12: Add mirrorUrls column
            await customStatement(
              'ALTER TABLE download_tasks ADD COLUMN mirror_urls TEXT',
            );
          }
          if (from < 13) {
            // Migration 12 -> 13: Add queueOrder column
            await customStatement(
              'ALTER TABLE download_tasks ADD COLUMN queue_order INTEGER NOT NULL DEFAULT 0',
            );
            // Backfill: assign order based on created_at
            await customStatement(
              'UPDATE download_tasks SET queue_order = (SELECT COUNT(*) FROM download_tasks t2 WHERE t2.created_at < download_tasks.created_at)',
            );
          }
          if (from < 14) {
            // Migration 13 -> 14: Add videoStreamSize column
            await customStatement(
              'ALTER TABLE download_tasks ADD COLUMN video_stream_size INTEGER NOT NULL DEFAULT 0',
            ); // FIX-B4
          }
          if (from < 15) {
            // Migration 14 -> 15: Add audioDownloadedBytes column (FIX-AUDIT-01)
            await customStatement(
              'ALTER TABLE download_tasks ADD COLUMN audio_downloaded_bytes INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (from < 16) {
            // Migration 15 -> 16: Add uploadedBytes column (FIX F5)
            await customStatement(
              'ALTER TABLE download_tasks ADD COLUMN uploaded_bytes INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (from < 17) {
            // Migration 16 -> 17: Browser history deduplication + favicon
            // support; tab favicon + last-visited; URL indexes for fast
            // duplicate lookups.
            await customStatement(
              'ALTER TABLE browser_history ADD COLUMN visit_count INTEGER NOT NULL DEFAULT 1',
            );
            await customStatement(
              'ALTER TABLE browser_history ADD COLUMN favicon_url TEXT',
            );
            await customStatement(
              'ALTER TABLE browser_tabs ADD COLUMN last_visited_at INTEGER NOT NULL DEFAULT 0',
            );
            await customStatement(
              'ALTER TABLE browser_tabs ADD COLUMN favicon_url TEXT',
            );
            // FIX-BH-03: Index on browser_history.url for deduplication lookups.
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_browser_history_url ON browser_history (url)',
            );
            // FIX-BM-01: Index on bookmarks.url for duplicate checks.
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_bookmarks_url ON bookmarks (url)',
            );
            // FIX-BT-03: Index on browser_tabs.position for ordered loading.
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_browser_tabs_position ON browser_tabs (position)',
            );
          }
          if (to > 17) {
            _dbLog.warning(
              'AppDatabase: Upgrade target version $to is higher than version 17, no specific migrations defined!',
            );
          }
        },
      );
}
