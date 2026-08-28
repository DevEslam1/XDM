import 'package:dmx/core/services/database/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Drift Schema Migration Matrix (v1 through v28)', () {
    test(
        'Fresh database initializes at latest schemaVersion 28 with all views and tables',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      // Keep in sync with AppDatabase.schemaVersion (v28: auth/headers).
      expect(db.schemaVersion, equals(28));

      // Verify all tables exist and can be queried
      final tasks = await db.select(db.downloadTasks).get();
      expect(tasks, isEmpty);

      final bookmarks = await db.select(db.bookmarks).get();
      expect(bookmarks, isEmpty);

      final history = await db.select(db.browserHistory).get();
      expect(history, isEmpty);

      final tabs = await db.select(db.browserTabs).get();
      expect(tabs, isEmpty);

      final mirrorHealth = await db.select(db.mirrorHealth).get();
      expect(mirrorHealth, isEmpty);

      // Verify task summary view
      final summary =
          await db.customSelect('SELECT * FROM v_download_task_summary').get();
      expect(summary, isEmpty);

      await db.close();
    });

    test(
        'Full historical migration: v1 -> v27 with pre-populated data and schema verification',
        () async {
      // 1. Create a raw SQLite in-memory database with v1 schema directly in sqlite3
      final rawSqlite = sqlite3.openInMemory();
      rawSqlite.execute('PRAGMA user_version = 1;');

      // Create v1 raw tables
      rawSqlite.execute('''
        CREATE TABLE download_tasks (
          id TEXT PRIMARY KEY NOT NULL,
          url TEXT NOT NULL,
          file_name TEXT NOT NULL,
          save_path TEXT NOT NULL DEFAULT '',
          local_file_path TEXT NOT NULL DEFAULT '',
          temp_file_path TEXT NOT NULL DEFAULT '',
          file_size INTEGER NOT NULL DEFAULT 0,
          downloaded_bytes INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          completed_at TEXT,
          scheduled_at TEXT,
          category TEXT NOT NULL,
          thread_count INTEGER NOT NULL DEFAULT 1,
          speed REAL NOT NULL DEFAULT 0.0,
          eta INTEGER,
          supports_resume INTEGER NOT NULL DEFAULT 0,
          speed_limit_kbps INTEGER NOT NULL DEFAULT 0,
          seeding_enabled INTEGER NOT NULL DEFAULT 0,
          seeding_limited INTEGER NOT NULL DEFAULT 0,
          seeding_limit_kbps INTEGER NOT NULL DEFAULT 500,
          audio_size INTEGER NOT NULL DEFAULT 0,
          audio_progress REAL NOT NULL DEFAULT 0.0,
          paused_by_user INTEGER NOT NULL DEFAULT 0,
          etag TEXT,
          last_modified TEXT,
          error_message TEXT,
          retry_count INTEGER NOT NULL DEFAULT 0,
          is_torrent INTEGER NOT NULL DEFAULT 0,
          torrent_files TEXT,
          user_agent TEXT,
          headers TEXT
        );
      ''');

      rawSqlite.execute('''
        CREATE TABLE bookmarks (
          id TEXT PRIMARY KEY NOT NULL,
          title TEXT NOT NULL,
          url TEXT NOT NULL,
          folder TEXT,
          created_at TEXT NOT NULL
        );
      ''');

      rawSqlite.execute('''
        CREATE TABLE browser_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          url TEXT NOT NULL,
          title TEXT NOT NULL,
          visited_at TEXT NOT NULL
        );
      ''');

      // Insert dummy test rows in v1 format
      rawSqlite.execute('''
        INSERT INTO download_tasks (
          id, url, file_name, save_path, local_file_path, temp_file_path, file_size, downloaded_bytes,
          status, created_at, updated_at, completed_at, scheduled_at, category,
          thread_count, speed, eta, supports_resume, retry_count, is_torrent
        ) VALUES (
          'task-v1-1', 'https://example.com/test.iso', 'test.iso', '/downloads/test.iso', '/downloads/test.iso', '/downloads/test.iso.dmxpart',
          1048576, 524288, 'downloading', '2023-01-01T12:00:00.000Z', '2023-01-01T12:05:00.000Z',
          NULL, NULL, 'other', 4, 1024.0, 500, 1, 0, 0
        );
      ''');

      rawSqlite.execute('''
        INSERT INTO bookmarks (id, title, url, folder, created_at)
        VALUES ('bm-1', 'Home', 'https://example.com', 'default', '2023-01-01T12:00:00.000Z');
      ''');

      rawSqlite.execute('''
        INSERT INTO browser_history (url, title, visited_at)
        VALUES ('https://example.com', 'Home', '2023-01-01T12:00:00.000Z');
      ''');

      // 2. Open via Drift AppDatabase which will trigger onUpgrade(1, 27)
      final appDb = AppDatabase.forTesting(NativeDatabase.opened(rawSqlite));

      // Force database open and migration
      final rows =
          await appDb.customSelect('SELECT * FROM download_tasks').get();
      expect(rows.length, equals(1));
      expect(rows.first.read<String>('id'), equals('task-v1-1'));

      // Verify v1 -> v2 (notes added)
      final taskCols =
          await appDb.customSelect('PRAGMA table_info(download_tasks)').get();
      final colNames = taskCols.map((r) => r.read<String>('name')).toSet();
      expect(colNames.contains('notes'), isTrue);

      // Verify v2 -> v3 (date migration to epoch integer)
      final taskRow = await appDb
          .customSelect(
              "SELECT id, created_at, updated_at, is_cancelled FROM download_tasks WHERE id = 'task-v1-1'")
          .getSingle();
      expect(taskRow.read<int>('created_at'), isA<int>());
      expect(taskRow.read<int>('created_at'), isPositive);

      // Verify v4 (playlistId, playlistTitle)
      expect(colNames.contains('playlist_id'), isTrue);
      expect(colNames.contains('playlist_title'), isTrue);

      // Verify v5 (isAppUpdate)
      expect(colNames.contains('is_app_update'), isTrue);

      // Verify v6 (priority, expectedSha256)
      expect(colNames.contains('priority'), isTrue);
      expect(colNames.contains('expected_sha256'), isTrue);

      // Verify v7 (browser_tabs table)
      final tabs = await appDb.select(appDb.browserTabs).get();
      expect(tabs, isEmpty);

      // Verify v10 (thumbnail_url)
      expect(colNames.contains('thumbnail_url'), isTrue);

      // Verify v11 (bookmarks and browser_history date conversion to integer)
      final bmRow = await appDb
          .customSelect(
              "SELECT id, created_at FROM bookmarks WHERE id = 'bm-1'")
          .getSingle();
      expect(bmRow.read<int>('created_at'), isA<int>());
      expect(bmRow.read<int>('created_at'), isPositive);

      final histRow = await appDb
          .customSelect('SELECT id, visited_at FROM browser_history LIMIT 1')
          .getSingle();
      expect(histRow.read<int>('visited_at'), isA<int>());
      expect(histRow.read<int>('visited_at'), isPositive);

      // Verify v12 (mirror_urls)
      expect(colNames.contains('mirror_urls'), isTrue);

      // Verify v13 (queue_order)
      expect(colNames.contains('queue_order'), isTrue);

      // Verify v14 (video_stream_size)
      expect(colNames.contains('video_stream_size'), isTrue);

      // Verify v15 (audio_downloaded_bytes)
      expect(colNames.contains('audio_downloaded_bytes'), isTrue);

      // Verify v16 (uploaded_bytes)
      expect(colNames.contains('uploaded_bytes'), isTrue);

      // Verify v18 (pause_reason, completed_pieces, yt_counterpart_downloaded_bytes)
      expect(colNames.contains('pause_reason'), isTrue);
      expect(colNames.contains('completed_pieces'), isTrue);
      expect(colNames.contains('yt_counterpart_downloaded_bytes'), isTrue);

      // Verify v19 (cycle_state)
      expect(colNames.contains('cycle_state'), isTrue);

      // Verify v20 (total_pieces)
      expect(colNames.contains('total_pieces'), isTrue);

      // Verify v23 (audio_chunks, http_parts, progress fields)
      expect(colNames.contains('audio_chunks'), isTrue);
      expect(colNames.contains('http_parts'), isTrue);
      expect(colNames.contains('torrent_piece_progress'), isTrue);

      // Verify v24 (previous_cycle_state, mirror_health)
      expect(colNames.contains('previous_cycle_state'), isTrue);
      final healthRows = await appDb.select(appDb.mirrorHealth).get();
      expect(healthRows, isEmpty);

      // Verify v25 (info_hash)
      expect(colNames.contains('info_hash'), isTrue);

      // Verify v27 (is_cancelled)
      expect(colNames.contains('is_cancelled'), isTrue);

      // Verify summary view works on migrated data
      final summaries = await appDb
          .customSelect('SELECT * FROM v_download_task_summary')
          .get();
      expect(summaries.length, equals(1));
      expect(summaries.first.read<String>('id'), equals('task-v1-1'));

      await appDb.close();
    });

    test(
        'Sequential step migrations: iteratively upgrading v1 -> v2 -> v3 -> ... -> v28',
        () async {
      final raw = sqlite3.openInMemory();
      raw.execute('PRAGMA user_version = 1;');
      raw.execute('''
        CREATE TABLE download_tasks (
          id TEXT PRIMARY KEY NOT NULL,
          url TEXT NOT NULL,
          file_name TEXT NOT NULL,
          save_path TEXT NOT NULL DEFAULT '',
          local_file_path TEXT NOT NULL DEFAULT '',
          temp_file_path TEXT NOT NULL DEFAULT '',
          file_size INTEGER NOT NULL DEFAULT 0,
          downloaded_bytes INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          completed_at TEXT,
          scheduled_at TEXT,
          category TEXT NOT NULL,
          thread_count INTEGER NOT NULL DEFAULT 1,
          speed REAL NOT NULL DEFAULT 0.0,
          eta INTEGER,
          supports_resume INTEGER NOT NULL DEFAULT 0,
          etag TEXT,
          last_modified TEXT,
          error_message TEXT,
          retry_count INTEGER NOT NULL DEFAULT 0,
          is_torrent INTEGER NOT NULL DEFAULT 0,
          torrent_files TEXT,
          user_agent TEXT,
          headers TEXT
        );
        CREATE TABLE bookmarks (
          id TEXT PRIMARY KEY NOT NULL,
          title TEXT NOT NULL,
          url TEXT NOT NULL,
          folder TEXT,
          created_at TEXT NOT NULL
        );
        CREATE TABLE browser_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          url TEXT NOT NULL,
          title TEXT NOT NULL,
          visited_at TEXT NOT NULL
        );
      ''');

      final appDb = AppDatabase.forTesting(NativeDatabase.opened(raw));
      final migrator = appDb.createMigrator();

      // Step through every version upgrade individually
      for (int v = 1; v < 28; v++) {
        await appDb.migration.onUpgrade(migrator, v, v + 1);
      }

      final cols =
          await appDb.customSelect('PRAGMA table_info(download_tasks)').get();
      final names = cols.map((r) => r.read<String>('name')).toSet();
      expect(names.contains('is_cancelled'), isTrue);
      expect(names.contains('info_hash'), isTrue);
      expect(names.contains('notes'), isTrue);

      await appDb.close();
    });
  });
}
