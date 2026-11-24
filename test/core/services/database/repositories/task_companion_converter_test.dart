import 'dart:convert';

import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/repositories/task_companion_converter.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  DownloadTask task({
    String id = 't1',
    String status = 'downloading',
    CycleState? cycleState,
    PauseReason? pauseReason,
    List<Map<String, dynamic>>? torrentFiles,
    Map<String, String>? customHeaders,
    String? playlistId,
  }) {
    final now = DateTime(2025, 1, 1, 12);
    return DownloadTask(
      id: id,
      fileName: 'file.zip',
      url: 'https://example.com/file.zip',
      fileSize: 1024,
      downloadedBytes: 512,
      category: 'Archive',
      status: DownloadStatus.values.firstWhere(
        (s) => s.name == status,
        orElse: () => DownloadStatus.paused,
      ),
      cycleState: cycleState,
      savePath: '/tmp/file.zip',
      localFilePath: '/tmp/file.zip',
      tempFilePath: '/tmp/file.zip.dmx',
      threadCount: 4,
      chunks: const [0.5, 0.25],
      createdAt: now,
      updatedAt: now,
      completedAt: now,
      scheduledAt: now,
      supportsResume: true,
      seedingEnabled: true,
      seedingLimited: true,
      seedingLimitKbps: 750,
      torrentFiles: torrentFiles,
      pauseReason: pauseReason,
      playlistId: playlistId,
      customHeaders: customHeaders,
    );
  }

  Future<DbDownloadTask> readRow(String id) =>
      (db.select(db.downloadTasks)..where((t) => t.id.equals(id))).getSingle();

  group('taskToCompanion', () {
    test('maps core and optional fields', () {
      final companion = TaskCompanionConverter.taskToCompanion(task());
      expect(companion.id.value, 't1');
      expect(companion.status.value, 'downloading');
      expect(companion.chunks.value, [0.5, 0.25]);
      expect(companion.supportsResume.value, isTrue);
      expect(companion.seedingLimitKbps.value, 750);
      expect(companion.completedAt.value, isNotNull);
      expect(companion.scheduledAt.value, isNotNull);
      expect(companion.cycleState.value, isNull);
    });

    test('encodes custom headers to JSON and drops empty maps', () {
      final withHeaders = TaskCompanionConverter.taskToCompanion(
        task(customHeaders: {'X-Test': '1'}),
      );
      expect(withHeaders.customHeaders.value, jsonEncode({'X-Test': '1'}));

      final empty = TaskCompanionConverter.taskToCompanion(
        task(customHeaders: {}),
      );
      expect(empty.customHeaders.value, isNull);
    });
  });

  group('rowToTask', () {
    test('round-trips a standard task', () async {
      final original = task(status: 'completed');
      await db
          .into(db.downloadTasks)
          .insert(TaskCompanionConverter.taskToCompanion(original));

      final row = await readRow('t1');
      final restored = TaskCompanionConverter.rowToTask(row);

      expect(restored.id, original.id);
      expect(restored.fileName, original.fileName);
      expect(restored.status, original.status);
      expect(restored.chunks, original.chunks);
      expect(restored.supportsResume, isTrue);
      expect(restored.completedAt, isNotNull);
    });

    test('defaults an unrecognized status to paused', () async {
      await db.into(db.downloadTasks).insert(
            DownloadTasksCompanion.insert(
              id: 'bad',
              fileName: 'f',
              url: 'u',
              category: 'c',
              status: 'totally_unknown',
              savePath: '/s',
              localFilePath: '/s',
              tempFilePath: '/s.tmp',
              threadCount: 1,
              createdAt: 0,
              updatedAt: 0,
            ),
          );

      final restored = TaskCompanionConverter.rowToTask(await readRow('bad'));
      expect(restored.status, DownloadStatus.paused);
    });

    test('marks interrupted active rows paused with appRestarted reason',
        () async {
      await db.into(db.downloadTasks).insert(
            DownloadTasksCompanion.insert(
              id: 'interrupted',
              fileName: 'f',
              url: 'u',
              category: 'c',
              status: 'downloading',
              cycleState: const drift.Value('starting'),
              savePath: '/s',
              localFilePath: '/s',
              tempFilePath: '/s.tmp',
              threadCount: 1,
              createdAt: 0,
              updatedAt: 0,
            ),
          );

      final restored =
          TaskCompanionConverter.rowToTask(await readRow('interrupted'));
      expect(restored.status, DownloadStatus.paused);
      expect(restored.cycleState, CycleState.paused);
      expect(restored.pauseReason, PauseReason.appRestarted);
      expect(restored.previousCycleState, CycleState.starting);
    });

    test('updatingLinks rows get the urlExpired pause reason', () async {
      await db.into(db.downloadTasks).insert(
            DownloadTasksCompanion.insert(
              id: 'links',
              fileName: 'f',
              url: 'u',
              category: 'c',
              status: 'downloading',
              cycleState: const drift.Value('updatingLinks'),
              savePath: '/s',
              localFilePath: '/s',
              tempFilePath: '/s.tmp',
              threadCount: 1,
              createdAt: 0,
              updatedAt: 0,
            ),
          );

      final restored = TaskCompanionConverter.rowToTask(await readRow('links'));
      expect(restored.status, DownloadStatus.paused);
      expect(restored.pauseReason, PauseReason.urlExpired);
    });

    test('computes torrent file aggregates from selected files', () async {
      final files = [
        {'selected': true, 'length': 100, 'downloadedBytes': 100},
        {'selected': true, 'length': 200, 'downloadedBytes': 50},
        {'selected': false, 'length': 999, 'downloadedBytes': 0},
      ];
      await db.into(db.downloadTasks).insert(
          TaskCompanionConverter.taskToCompanion(task(torrentFiles: files)));

      final restored = TaskCompanionConverter.rowToTask(await readRow('t1'));
      expect(restored.totalFiles, 2);
      expect(restored.completedFiles, 1);
      expect(restored.totalFileBytes, 300);
      expect(restored.downloadedFileBytes, 150);
    });

    test('treats an unresolved zero length as incomplete unless lengthKnown',
        () async {
      final files = [
        {'selected': true, 'length': 0, 'downloadedBytes': 0},
        {
          'selected': true,
          'length': 0,
          'downloadedBytes': 0,
          'lengthKnown': true
        },
      ];
      await db.into(db.downloadTasks).insert(
          TaskCompanionConverter.taskToCompanion(task(torrentFiles: files)));

      final restored = TaskCompanionConverter.rowToTask(await readRow('t1'));
      expect(restored.totalFiles, 2);
      // Only the lengthKnown row counts as complete (0 >= 0).
      expect(restored.completedFiles, 1);
    });

    test('decodes valid custom headers and ignores malformed ones', () async {
      await db.into(db.downloadTasks).insert(
            DownloadTasksCompanion.insert(
              id: 'hdr',
              fileName: 'f',
              url: 'u',
              category: 'c',
              status: 'paused',
              savePath: '/s',
              localFilePath: '/s',
              tempFilePath: '/s.tmp',
              threadCount: 1,
              createdAt: 0,
              updatedAt: 0,
              customHeaders: const drift.Value('{"X-A":"1"}'),
            ),
          );

      final restored = TaskCompanionConverter.rowToTask(await readRow('hdr'));
      expect(restored.customHeaders, {'X-A': '1'});
    });

    test('returns null headers for empty / malformed payloads', () async {
      await db.into(db.downloadTasks).insert(
            DownloadTasksCompanion.insert(
              id: 'hdr2',
              fileName: 'f',
              url: 'u',
              category: 'c',
              status: 'paused',
              savePath: '/s',
              localFilePath: '/s',
              tempFilePath: '/s.tmp',
              threadCount: 1,
              createdAt: 0,
              updatedAt: 0,
              customHeaders: const drift.Value('not-json'),
            ),
          );

      final restored = TaskCompanionConverter.rowToTask(await readRow('hdr2'));
      expect(restored.customHeaders, isNull);
    });

    test('falls back to epoch for out-of-range timestamps', () async {
      await db.into(db.downloadTasks).insert(
            DownloadTasksCompanion.insert(
              id: 'huge',
              fileName: 'f',
              url: 'u',
              category: 'c',
              status: 'paused',
              savePath: '/s',
              localFilePath: '/s',
              tempFilePath: '/s.tmp',
              threadCount: 1,
              createdAt: 1000000000000000000,
              updatedAt: 1000000000000000000,
              completedAt: const drift.Value(1000000000000000000),
            ),
          );

      final restored = TaskCompanionConverter.rowToTask(await readRow('huge'));
      expect(restored.createdAt, DateTime.fromMillisecondsSinceEpoch(0));
      expect(restored.completedAt, isNull);
    });

    test('restores a previous cycle state when present', () async {
      await db.into(db.downloadTasks).insert(
            DownloadTasksCompanion.insert(
              id: 'prev',
              fileName: 'f',
              url: 'u',
              category: 'c',
              status: 'paused',
              cycleState: const drift.Value('paused'),
              previousCycleState: const drift.Value('merging'),
              savePath: '/s',
              localFilePath: '/s',
              tempFilePath: '/s.tmp',
              threadCount: 1,
              createdAt: 0,
              updatedAt: 0,
            ),
          );

      final restored = TaskCompanionConverter.rowToTask(await readRow('prev'));
      expect(restored.previousCycleState, CycleState.merging);
    });

    test('drops empty playlist id and title', () async {
      await db.into(db.downloadTasks).insert(
            DownloadTasksCompanion.insert(
              id: 'pl',
              fileName: 'f',
              url: 'u',
              category: 'c',
              status: 'paused',
              savePath: '/s',
              localFilePath: '/s',
              tempFilePath: '/s.tmp',
              threadCount: 1,
              createdAt: 0,
              updatedAt: 0,
              playlistId: const drift.Value(''),
              playlistTitle: const drift.Value(''),
            ),
          );

      final restored = TaskCompanionConverter.rowToTask(await readRow('pl'));
      expect(restored.playlistId, isNull);
      expect(restored.playlistTitle, isNull);
    });
  });

  group('isInterruptedActiveRow', () {
    test('recognises each interrupted cycle state', () async {
      const states = [
        'starting',
        'resuming',
        'retrying',
        'fetchingMetadata',
        'merging',
        'verifying',
        'updatingLinks',
        'allocating',
        'stalled',
      ];
      for (final state in states) {
        await db.into(db.downloadTasks).insert(
              DownloadTasksCompanion.insert(
                id: state,
                fileName: 'f',
                url: 'u',
                category: 'c',
                status: 'paused',
                cycleState: drift.Value(state),
                savePath: '/s',
                localFilePath: '/s',
                tempFilePath: '/s.tmp',
                threadCount: 1,
                createdAt: 0,
                updatedAt: 0,
              ),
            );
        expect(
          TaskCompanionConverter.isInterruptedActiveRow(await readRow(state)),
          isTrue,
          reason: '$state should be considered interrupted',
        );
      }
    });

    test('idle rows are not interrupted', () async {
      await db.into(db.downloadTasks).insert(
            DownloadTasksCompanion.insert(
              id: 'idle',
              fileName: 'f',
              url: 'u',
              category: 'c',
              status: 'completed',
              savePath: '/s',
              localFilePath: '/s',
              tempFilePath: '/s.tmp',
              threadCount: 1,
              createdAt: 0,
              updatedAt: 0,
            ),
          );
      expect(
        TaskCompanionConverter.isInterruptedActiveRow(await readRow('idle')),
        isFalse,
      );
    });
  });
}
