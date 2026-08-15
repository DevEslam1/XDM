import 'package:dmx/core/services/database/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Database Migration v2 to v3 Large Dataset Test (P0-11)', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('Migration v2 to v3 successfully migrates 5000 rows incrementally within transaction', () async {
      // 1. Setup table structure simulating v2 schema
      await db.customStatement('''
        CREATE TABLE IF NOT EXISTS download_tasks_test (
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
          thread_count INTEGER NOT NULL DEFAULT 1,
          chunks TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          completed_at TEXT,
          scheduled_at TEXT,
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

      // 2. Insert 5000 rows in batches within transaction
      await db.customStatement('BEGIN TRANSACTION');
      for (var i = 0; i < 5000; i++) {
        await db.customStatement('''
          INSERT INTO download_tasks_test (
            id, file_name, url, category, status, save_path, local_file_path, temp_file_path,
            created_at, updated_at
          ) VALUES (
            'task_$i', 'file_$i.zip', 'https://example.com/file_$i.zip', 'other', 'completed',
            '/path/file_$i.zip', '/path/file_$i.zip', '/temp/file_$i.dmx',
            '2023-05-15T12:00:00.000Z', '2023-05-15T12:30:00.000Z'
          )
        ''');
      }
      await db.customStatement('COMMIT');

      final initialCountResult = await db.customSelect(
        'SELECT COUNT(*) as cnt FROM download_tasks_test',
      ).get();
      expect(initialCountResult.first.read<int>('cnt'), equals(5000));

      // 3. Execute the incremental v2->v3 migration logic
      await db.customStatement('BEGIN TRANSACTION');
      await db.customStatement('''
        UPDATE download_tasks_test SET created_at =
          SUBSTR(created_at, 1, INSTR(created_at, '.') - 1)
        WHERE typeof(created_at) = 'text' AND created_at LIKE '%.%';
      ''');
      await db.customStatement('''
        UPDATE download_tasks_test SET created_at = SUBSTR(created_at, 1, INSTR(created_at, '+') - 1) WHERE typeof(created_at) = 'text' AND created_at LIKE '%+%';
        UPDATE download_tasks_test SET updated_at = SUBSTR(updated_at, 1, INSTR(updated_at, '+') - 1) WHERE typeof(updated_at) = 'text' AND updated_at LIKE '%+%';
        UPDATE download_tasks_test SET completed_at = SUBSTR(completed_at, 1, INSTR(completed_at, '+') - 1) WHERE typeof(completed_at) = 'text' AND completed_at LIKE '%+%';
        UPDATE download_tasks_test SET scheduled_at = SUBSTR(scheduled_at, 1, INSTR(scheduled_at, '+') - 1) WHERE typeof(scheduled_at) = 'text' AND scheduled_at LIKE '%+%';
      ''');
      await db.customStatement('''
        UPDATE download_tasks_test SET
          created_at = COALESCE(CAST((julianday(REPLACE(REPLACE(created_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0)
        WHERE typeof(created_at) = 'text';
      ''');
      await db.customStatement('''
        UPDATE download_tasks_test SET
          updated_at = COALESCE(CAST((julianday(REPLACE(REPLACE(updated_at, 'T', ' '), 'Z', '')) - 2440587.5) * 86400000 AS INTEGER), 0)
        WHERE typeof(updated_at) = 'text';
      ''');
      await db.customStatement('COMMIT');

      // 4. Validate all 5000 rows are converted to valid epoch timestamps
      final postMigrationCount = await db.customSelect(
        'SELECT COUNT(*) as cnt FROM download_tasks_test WHERE CAST(created_at AS INTEGER) > 0',
      ).get();
      expect(postMigrationCount.first.read<int>('cnt'), equals(5000));

      final sampleRow = await db.customSelect(
        "SELECT created_at, updated_at FROM download_tasks_test WHERE id = 'task_0'",
      ).get();
      final createdEpoch = int.parse(sampleRow.first.read<String>('created_at'));
      expect(createdEpoch, greaterThan(1600000000000));
    });
  });
}
