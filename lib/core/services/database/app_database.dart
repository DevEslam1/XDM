import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';

part 'app_database.g.dart';

// Type Converters
class DoubleListConverter extends TypeConverter<List<double>, String> {
  const DoubleListConverter();
  @override
  List<double> fromSql(String fromDb) {
    if (fromDb.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(fromDb);
      if (decoded is List) {
        return decoded.map((e) => (e as num).toDouble()).toList();
      }
      return [];
    } catch (e) {
      debugPrint('[DMX] Error decoding DoubleList from DB: $e');
      return [];
    }
  }

  @override
  String toSql(List<double> value) => jsonEncode(value);
}

class TorrentFilesConverter
    extends TypeConverter<List<Map<String, dynamic>>, String> {
  const TorrentFilesConverter();
  @override
  List<Map<String, dynamic>> fromSql(String fromDb) {
    if (fromDb.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(fromDb);
      if (decoded is List) {
        return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
      return [];
    } catch (e) {
      debugPrint('[DMX] Error decoding TorrentFiles from DB: $e');
      return [];
    }
  }

  @override
  String toSql(List<Map<String, dynamic>> value) {
    return jsonEncode(value);
  }
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
  RealColumn get audioProgress => real().withDefault(const Constant(0.0))();
  BoolColumn get pausedByUser => boolean().withDefault(const Constant(false))();
  TextColumn get youtubeQualityPreset => text().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get playlistId => text().nullable()();
  TextColumn get playlistTitle => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DbBookmark')
class Bookmarks extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get url => text()();
  TextColumn get folder => text().nullable()();
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DbBrowserHistory')
class BrowserHistory extends Table {
  TextColumn get id => text()();
  TextColumn get url => text()();
  TextColumn get title => text()();
  TextColumn get visitedAt => text()();

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
      },
    );
  });
}

@DriftDatabase(tables: [DownloadTasks, Bookmarks, BrowserHistory])
class AppDatabase extends _$AppDatabase {
  AppDatabase(String path) : super(_openConnection(path));
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 4;

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
                CAST((julianday(REPLACE(REPLACE(created_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER) as created_at,
                CAST((julianday(REPLACE(REPLACE(updated_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER) as updated_at,
                CASE WHEN completed_at IS NOT NULL THEN CAST((julianday(REPLACE(REPLACE(completed_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER) ELSE NULL END as completed_at,
                CASE WHEN scheduled_at IS NOT NULL THEN CAST((julianday(REPLACE(REPLACE(scheduled_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER) ELSE NULL END as scheduled_at,
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
      }
      if (from < 4) {
        // Migration 3 -> 4: Add playlistId and playlistTitle columns
        await m.addColumn(downloadTasks, downloadTasks.playlistId);
        await m.addColumn(downloadTasks, downloadTasks.playlistTitle);
      }
    },
  );
}
