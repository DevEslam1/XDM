import 'package:dmx/core/services/database/app_database.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v_download_task_summary SQL view', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('view exists after schema creation', () async {
      final rows = await db
          .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'view' AND name = 'v_download_task_summary'")
          .get();
      expect(rows, hasLength(1));
      expect(rows.first.read<String>('name'),
          equals('v_download_task_summary'));
    });

    test('view computes torrent file aggregates from JSON', () async {
      const torrentFiles = [
        {
          'name': 'a.bin',
          'length': 100,
          'downloadedBytes': 100,
          'selected': true,
        },
        {
          'name': 'b.bin',
          'length': 200,
          'downloadedBytes': 50,
          'selected': true,
        },
        {
          'name': 'c.bin',
          'length': 300,
          'downloadedBytes': 0,
          'selected': false,
        },
      ];
await db.into(db.downloadTasks).insert(DownloadTasksCompanion.insert(
            id: 'view-test-1',
            fileName: 'bundle',
            url: 'https://example.com/bundle',
            fileSize: const drift.Value(1000),
            downloadedBytes: const drift.Value(150),
            speed: const drift.Value(0.0),
            category: 'Archive',
            savePath: '/dl/bundle',
            localFilePath: '/dl/bundle',
            tempFilePath: '/dl/bundle.part',
            status: 'downloading',
            threadCount: 2,
            createdAt: 0,
            updatedAt: 0,
            torrentFiles: const drift.Value(torrentFiles),
          ));

      final row = await db
          .customSelect(
              'SELECT * FROM v_download_task_summary WHERE id = \'view-test-1\'')
          .getSingle();
      // selected files only: a (len 100) + b (len 200) = 2 files, 300 bytes.
      expect(row.read<int>('total_files'), equals(2));
      expect(row.read<int>('completed_files'), equals(1)); // a is complete
      expect(row.read<int>('total_file_bytes'), equals(300));
      // downloaded: a fully (100) + b clamped (50) = 150.
      expect(row.read<int>('downloaded_file_bytes'), equals(150));
    });

    test('view handles rows without torrent files', () async {
      await db.into(db.downloadTasks).insert(DownloadTasksCompanion.insert(
            id: 'view-test-2',
            fileName: 'plain',
            url: 'https://example.com/plain',
            fileSize: const drift.Value(1000),
            downloadedBytes: const drift.Value(500),
            speed: const drift.Value(0.0),
            category: 'Document',
            savePath: '/dl/plain',
            localFilePath: '/dl/plain',
            tempFilePath: '/dl/plain.part',
            status: 'downloading',
            threadCount: 1,
            createdAt: 0,
            updatedAt: 0,
          ));

      final row = await db
          .customSelect(
              'SELECT * FROM v_download_task_summary WHERE id = \'view-test-2\'')
          .getSingle();
      expect(row.read<int>('total_files'), equals(0));
      expect(row.read<int>('completed_files'), equals(0));
      expect(row.read<int>('total_file_bytes'), equals(0));
      expect(row.read<int>('downloaded_file_bytes'), equals(0));
    });
  });
}