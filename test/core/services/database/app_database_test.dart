import 'dart:io';

import 'package:dmx/core/services/database/app_database.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DoubleListConverter', () {
    const converter = DoubleListConverter();

    test('empty input yields an empty list', () {
      expect(converter.fromSql(''), isEmpty);
      expect(converter.fromSql('   '), isEmpty);
    });

    test('coerces numeric entries and neutralizes non-numeric entries', () {
      expect(
        converter.fromSql('[1, "x", 2.5, true]'),
        [1.0, 0.0, 2.5, 0.0],
      );
    });

    test('valid JSON that is not a list yields an empty list', () {
      expect(converter.fromSql('{"a": 1}'), isEmpty);
    });

    test('malformed JSON falls back to regex recovery', () {
      final recovered = converter.fromSql('[0.1, 0.2, corrupt, 0.9]');
      expect(recovered, containsAllInOrder([0.1, 0.2, 0.9]));
    });

    test('recovery cache evicts oldest entries past the limit', () {
      DoubleListConverter.clearRecoveryCache();
      for (var i = 0; i < 70; i++) {
        converter.fromSql('[$i.5, corrupt_$i]');
      }
      expect(
        DoubleListConverter.recoveryCacheLength,
        lessThanOrEqualTo(64),
      );
      DoubleListConverter.clearRecoveryCache();
    });

    test('toSql round-trips through fromSql', () {
      final encoded = converter.toSql([0.5, 1.0]);
      expect(converter.fromSql(encoded), [0.5, 1.0]);
    });
  });

  group('TorrentFilesConverter', () {
    const converter = TorrentFilesConverter();

    test('empty input yields an empty list', () {
      expect(converter.fromSql(''), isEmpty);
    });

    test('skips non-map entries in a valid list', () {
      final files = converter.fromSql('[{"name": "a"}, 5, "x"]');
      expect(files.length, 1);
      expect(files.first['name'], 'a');
    });

    test('valid JSON that is not a list yields an empty list', () {
      expect(converter.fromSql('{"a": 1}'), isEmpty);
    });

    test('malformed JSON falls back to regex recovery', () {
      final recovered = converter.fromSql('[{"name": "a"}, bad]');
      expect(recovered, isNotEmpty);
    });

    test('recovery cache evicts oldest entries past the limit', () {
      TorrentFilesConverter.clearRecoveryCache();
      for (var i = 0; i < 70; i++) {
        converter.fromSql('[{"n": $i}, corrupt_$i]');
      }
      expect(TorrentFilesConverter.recoveryCacheLength, lessThanOrEqualTo(64));
      TorrentFilesConverter.clearRecoveryCache();
    });

    test('toSql sanitizes non-encodable values instead of throwing', () {
      final encoded = converter.toSql([
        {'name': 'a', 'bad': Object()},
      ]);
      expect(encoded, contains('name'));
      expect(encoded, contains('bad'));
    });
  });

  group('StringListConverter', () {
    const converter = StringListConverter();

    test('handles empty, valid, and malformed inputs', () {
      expect(converter.fromSql(''), isEmpty);
      expect(converter.fromSql('["a", "b"]'), ['a', 'b']);
      expect(converter.fromSql('{}'), isEmpty);
      expect(converter.fromSql('not-json'), isEmpty);
    });

    test('toSql round-trips', () {
      expect(converter.fromSql(converter.toSql(['x', 'y'])), ['x', 'y']);
    });
  });

  group('AppDatabase in-memory', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('reports schema version 28', () {
      expect(db.schemaVersion, 28);
    });

    test('creates the task summary view', () async {
      final rows =
          await db.customSelect('SELECT * FROM v_download_task_summary').get();
      expect(rows, isEmpty);
    });

    test('persists and reads back a download task', () async {
      await db.into(db.downloadTasks).insert(
            DownloadTasksCompanion.insert(
              id: 'a',
              fileName: 'a.zip',
              url: 'https://example.com/a.zip',
              category: 'Archive',
              status: 'completed',
              savePath: '/s',
              localFilePath: '/s',
              tempFilePath: '/s.tmp',
              threadCount: 2,
              createdAt: 1,
              updatedAt: 2,
              torrentFiles: const drift.Value([
                {'selected': true, 'length': 10, 'downloadedBytes': 10},
              ]),
            ),
          );

      final rows = await db.select(db.downloadTasks).get();
      expect(rows.single.id, 'a');

      final summary =
          await db.customSelect('SELECT * FROM v_download_task_summary').get();
      expect(summary.single.read<int>('total_files'), 1);
      expect(summary.single.read<int>('completed_files'), 1);
    });

    test('addColumnIfMissing adds a missing column and is idempotent',
        () async {
      await db.addColumnIfMissingForTesting(
        'download_tasks',
        'runtime_added',
        'ALTER TABLE download_tasks ADD COLUMN runtime_added TEXT',
      );
      final info =
          await db.customSelect('PRAGMA table_info(download_tasks)').get();
      expect(
        info.any((r) => r.read<String>('name') == 'runtime_added'),
        isTrue,
      );

      // Second call must detect the column and skip the ALTER.
      await db.addColumnIfMissingForTesting(
        'download_tasks',
        'runtime_added',
        'ALTER TABLE download_tasks ADD COLUMN runtime_added TEXT',
      );
    });

    test('safeCustomStatement executes valid SQL and rethrows failures',
        () async {
      await db.safeCustomStatement('CREATE TABLE tmp_x (id INTEGER)');
      await expectLater(
        db.safeCustomStatement('THIS IS NOT VALID SQL'),
        throwsA(anything),
      );
    });

    test('checkpointWal returns 0 for an empty in-memory WAL', () async {
      expect(await db.checkpointWal(), 0);
    });

    test('checkpointWal in passive mode executes and returns a row value',
        () async {
      final result = await db.checkpointWal(truncate: false);
      expect(result, isA<int>());
    });

    test('cleanupStaleConnections reports a healthy connection', () async {
      expect(await db.cleanupStaleConnections(), isTrue);
    });

    test('setSynchronousFull / Normal execute without throwing', () async {
      await db.setSynchronousFull();
      await db.setSynchronousNormal();
    });

    test('getWalFileSize is zero without a file path', () {
      expect(db.getWalFileSize(), 0);
    });

    test('periodic WAL checkpointer can be started and stopped', () {
      db.startPeriodicWalCheckpointer(interval: const Duration(hours: 1));
      db.startPeriodicWalCheckpointer(interval: const Duration(hours: 2));
      db.stopPeriodicWalCheckpointer();
    });

    test('closeDatabase stops the checkpointer and closes cleanly', () async {
      db.startPeriodicWalCheckpointer();
      await db.closeDatabase();
    });
  });

  group('AppDatabase file-backed', () {
    late Directory dir;
    late AppDatabase db;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('app_db_test_');
      db = AppDatabase('${dir.path}/test.db');
    });

    tearDown(() async {
      try {
        await db.close();
      } catch (_) {}
      if (await dir.exists()) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('WAL file grows and can be checkpointed', () async {
      await db.into(db.downloadTasks).insert(
            DownloadTasksCompanion.insert(
              id: 'w',
              fileName: 'w',
              url: 'u',
              category: 'c',
              status: 'paused',
              savePath: '/s',
              localFilePath: '/s',
              tempFilePath: '/s.tmp',
              threadCount: 1,
              createdAt: 0,
              updatedAt: 0,
            ),
          );

      final result = await db.checkpointWal(truncate: true);
      expect(result, isA<int>());
      expect(db.getWalFileSize(), greaterThanOrEqualTo(0));
    });

    test('cleanupStaleConnections succeeds on a file database', () async {
      expect(await db.cleanupStaleConnections(), isTrue);
    });

    test('refuses to open a newer database and writes a backup', () async {
      final sub = await Directory.systemTemp.createTemp('app_db_downgrade_');
      final path = '${sub.path}/downgrade.db';
      final first = AppDatabase(path);
      await first.customSelect('SELECT 1').get();
      await first.customStatement('PRAGMA user_version = 99');
      await first.close();

      final second = AppDatabase(path);
      await expectLater(
        second.customSelect('SELECT 1').get(),
        throwsA(
          predicate((Object e) => e
              .toString()
              .contains('Refusing to open a newer download database')),
        ),
      );
      final backups =
          sub.listSync().where((e) => e.path.contains('.bak')).toList();
      expect(backups, isNotEmpty);
      try {
        await second.close();
      } catch (_) {}
      try {
        await sub.delete(recursive: true);
      } catch (_) {}
    });
  });
}
