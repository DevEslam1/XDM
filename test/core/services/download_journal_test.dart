import 'dart:convert';
import 'dart:io';

import 'package:dmx/core/services/download_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadJournal & TransferState', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('journal_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('ChunkState computes ratio and clamped progress correctly', () {
      final chunk = ChunkState(start: 0, end: 99, downloaded: 50);
      expect(chunk.size, 100);
      expect(chunk.ratio, 0.5);
      expect(chunk.isComplete, false);

      final fullChunk = ChunkState(start: 0, end: 99, downloaded: 100);
      expect(fullChunk.isComplete, true);
      expect(fullChunk.ratio, 1.0);
    });

    test(
        'TransferState serialization round-trip V3 preserves chunks and totals',
        () {
      final state = TransferState(
        totalSize: 1000,
        threadCount: 2,
        url: 'https://example.com/file.bin',
        chunks: [
          ChunkState(start: 0, end: 499, downloaded: 250),
          ChunkState(start: 500, end: 999, downloaded: 500),
        ],
      );

      final json = state.toJson();
      final parsed = TransferState.tryParseV3(json);

      expect(parsed, isNotNull);
      expect(parsed!.totalSize, 1000);
      expect(parsed.threadCount, 2);
      expect(parsed.downloadedBytes, 750);
      expect(parsed.chunks.length, 2);
      expect(parsed.chunks[0].downloaded, 250);
      expect(parsed.chunks[1].downloaded, 500);
    });

    test('TransferState cloned instance is deeply decoupled', () {
      final state = TransferState(
        totalSize: 500,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 499, downloaded: 100)],
      );

      final clone = state.clone();
      clone.chunks[0].downloaded = 300;

      expect(state.chunks[0].downloaded, 100);
      expect(clone.chunks[0].downloaded, 300);
    });

    test('DownloadJournal state save and atomic tmp persistence', () async {
      final tempFile = '${tempDir.path}/test_download.bin';
      final state = TransferState(
        totalSize: 2000,
        threadCount: 2,
        chunks: [
          ChunkState(start: 0, end: 999, downloaded: 400),
          ChunkState(start: 1000, end: 1999, downloaded: 600),
        ],
      );

      await StateStore.save(tempFile, state, durable: true);
      final file = File(StateStore.pathFor(tempFile));
      expect(await file.exists(), true);

      final loadedState = await StateStore.load(tempFile);
      expect(loadedState, isNotNull);
      expect(loadedState!.totalSize, 2000);
      expect(loadedState.downloadedBytes, 1000);
    });

    test('DownloadJournal recovery when file is missing', () async {
      final recovered =
          await DownloadJournal.recover('${tempDir.path}/nonexistent.journal');
      expect(recovered, isNull);
    });

    test('pathFor and journalPathFor honor the task scope', () {
      final store = StateStoreInstance();
      expect(store.pathFor('/t/file.bin'), '/t/file.bin.dmxstate');
      expect(
          store.pathFor('/t/file.bin', taskId: 'a'), '/t/file.bin.a.dmxstate');
      expect(store.journalPathFor('/t/file.bin'), '/t/file.bin.journal');
      expect(store.journalPathFor('/t/file.bin', taskId: 'a'),
          '/t/file.bin.a.journal');
    });

    test('computeFingerprint changes with state and is stable for clones', () {
      final store = StateStoreInstance();
      final state = TransferState(
        totalSize: 100,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 99, downloaded: 10)],
      );
      final clone = state.clone();
      expect(store.computeFingerprint(state), store.computeFingerprint(clone));
      clone.chunks[0].downloaded = 50;
      expect(store.computeFingerprint(clone),
          isNot(store.computeFingerprint(state)));
    });

    test('StateStoreFactory returns stable per-name instances', () {
      final factory = StateStoreFactory();
      final a = factory.getOrCreate();
      expect(identical(a, factory.defaultStore), isTrue);
      final b = factory.getOrCreate(name: 'other');
      expect(identical(a, b), isFalse);
    });

    test('loadOrCreate creates a fresh state when nothing exists', () async {
      final store = StateStoreInstance();
      final result = await store.loadOrCreate(
        '${tempDir.path}/fresh.dmxpart',
        url: 'https://example.com/fresh.bin',
        threadCount: 4,
        knownFileSize: 4096,
      );
      expect(result.created, isTrue);
      expect(result.state.totalSize, 4096);
      expect(result.state.chunks, isEmpty);
    });

    test('loadOrCreate migrates a V2 progress snapshot', () async {
      final store = StateStoreInstance();
      await File('${tempDir.path}/v2.dmxpart')
          .writeAsBytes(List<int>.filled(100, 0), flush: true);
      final path = store.pathFor('${tempDir.path}/v2.dmxpart', taskId: 'v2');
      await File(path).writeAsString(jsonEncode({
        'v': 2,
        'totalSize': 100,
        'threadCount': 2,
        'progress': [10, 20],
        'url': 'https://example.com/v2.bin',
      }));

      final result = await store.loadOrCreate(
        '${tempDir.path}/v2.dmxpart',
        url: 'https://example.com/v2.bin',
        threadCount: 2,
        knownFileSize: 100,
        taskId: 'v2',
      );
      expect(result.state.downloadedBytes, 30);
      expect(result.migratedFrom, 'v2');
    });

    test('loadOrCreate tolerates a V3 snapshot with empty chunks', () async {
      final store = StateStoreInstance();
      final path = store.pathFor('${tempDir.path}/empty.dmxpart', taskId: 'e');
      await File(path).writeAsString(jsonEncode({
        'v': TransferState.currentVersion,
        'totalSize': 500,
        'threadCount': 2,
        'chunks': <dynamic>[],
        'url': 'https://example.com/empty.bin',
      }));

      final result = await store.loadOrCreate(
        '${tempDir.path}/empty.dmxpart',
        url: 'https://example.com/empty.bin',
        threadCount: 2,
        knownFileSize: 500,
        taskId: 'e',
      );
      expect(result.state.totalSize, 500);
      expect(result.state.chunks, isEmpty);
    });

    test('loadOrCreate credits an orphan temp file for multi-thread', () async {
      final store = StateStoreInstance();
      final tempFile = '${tempDir.path}/orphan.dmxpart';
      await File(tempFile).writeAsBytes(List<int>.filled(500, 0xAB));

      final result = await store.loadOrCreate(
        tempFile,
        url: 'https://example.com/orphan.bin',
        threadCount: 4,
        knownFileSize: 4096,
      );
      expect(result.state.downloadedBytes, 500);
      expect(result.state.migrationNote, contains('orphan'));
    });

    test('save then load round-trips through the task-scoped path', () async {
      final store = StateStoreInstance();
      final tempFile = '${tempDir.path}/roundtrip.dmxpart';
      final state = TransferState(
        totalSize: 1000,
        threadCount: 2,
        chunks: [
          ChunkState(start: 0, end: 499, downloaded: 100),
          ChunkState(start: 500, end: 999, downloaded: 200),
        ],
        url: 'https://example.com/rt.bin',
      );

      await store.save(tempFile, state, durable: true, taskId: 'rt');
      final loaded = await store.load(tempFile, taskId: 'rt');
      expect(loaded, isNotNull);
      expect(loaded!.downloadedBytes, 300);
    });

    test('resetTransferState wipes snapshot, journal and temp payload',
        () async {
      final store = StateStoreInstance();
      final tempFile = '${tempDir.path}/reset.dmxpart';
      await File(tempFile).writeAsBytes([1, 2, 3]);
      final state = TransferState(
        totalSize: 10,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 9, downloaded: 5)],
      );
      await store.save(tempFile, state, durable: true);
      final journal = DownloadJournal('$tempFile.journal');
      await journal.open();
      await journal.writeInit(1, 10);
      await journal.close();

      await store.resetTransferState(
        tempFile,
        state: state,
        deleteTempFile: true,
      );

      expect(state.chunks[0].downloaded, 0);
      expect(await File(store.pathFor(tempFile)).exists(), isFalse);
      expect(await File(tempFile).exists(), isFalse);
      expect(await File('$tempFile.journal').exists(), isFalse);
    });

    test('isPermanentWriteFailure only flags non-transient errors', () {
      expect(
        StateStore.isPermanentWriteFailure(
          const FileSystemException(
            'denied',
            '/p',
            OSError('Permission denied', 13),
          ),
        ),
        isTrue,
      );
      expect(StateStore.isPermanentWriteFailure(StateError('x')), isFalse);
      expect(
        StateStore.isPermanentWriteFailure(
          const FileSystemException('io', '/p', OSError('EIO', 5)),
        ),
        isFalse,
      );
    });

    test('hasPermanentSaveFailure is false without a recorded failure', () {
      final store = StateStoreInstance();
      expect(store.hasPermanentSaveFailure('${tempDir.path}/x'), isFalse);
      expect(store.lastSaveErrorsForTesting, isEmpty);
    });

    test('removeCachedPayload and removeTaskState are safe', () {
      final store = StateStoreInstance();
      store.removeCachedPayload('/tmp/x.dmxstate');
      store.removeTaskState('/tmp/y.dmxstate');
    });

    test('DownloadJournal records and recovers chunk progress', () async {
      final journalPath = '${tempDir.path}/progress.journal';
      final journal = DownloadJournal(journalPath);
      await journal.open();
      await journal.writeInit(2, 1000);
      await journal.recordChunkProgress(0, 100, force: true);
      await journal.recordChunkProgress(1, 50, force: true);
      await journal.writeCheckpoint([100, 50], 1000);
      await journal.close();

      final details = await DownloadJournal.recoverWithDetails(journalPath);
      expect(details, isNotNull);
      expect(details!.chunkBytes, [100, 50]);
      expect(details.totalSize, 1000);
      expect(details.threadCount, 2);

      expect(await DownloadJournal.recover(journalPath), [100, 50]);
      expect(await DownloadJournal.replay(journalPath), [100, 50]);
    });

    test('DownloadJournal skips corrupt lines during recovery', () async {
      final journalPath = '${tempDir.path}/corrupt.journal';
      final journal = DownloadJournal(journalPath);
      await journal.open();
      await journal.writeInit(2, 1000);
      await journal.close();

      await File(journalPath).writeAsString(
        'not-json\n{"t":"chunk","i":0,"b":5,"c":999}\n',
        mode: FileMode.append,
      );

      final recovered = await DownloadJournal.recover(journalPath);
      expect(recovered, [0, 0]);
    });

    test('DownloadJournal flush helpers handle active and file journals',
        () async {
      final tempFile = '${tempDir.path}/flush.dmxpart';
      final journal = DownloadJournal('$tempFile.journal');
      await journal.open();
      await journal.writeInit(1, 100);
      await DownloadJournal.flushAllActive();
      await DownloadJournal.flushAndSyncForFile(tempFile);
      await journal.flushAndSync();
      await journal.close();
    });

    test('DownloadJournal deleteJournalFor and clearJournalFor remove files',
        () async {
      final tempFile = '${tempDir.path}/del.dmxpart';
      final journal = DownloadJournal('$tempFile.journal');
      await journal.open();
      await journal.writeInit(1, 10);
      await journal.close();
      expect(await File('$tempFile.journal').exists(), isTrue);

      await DownloadJournal.clearJournalFor(tempFile);
      expect(await File('$tempFile.journal').exists(), isFalse);

      final journal2 = DownloadJournal('$tempFile.journal');
      await journal2.open();
      await journal2.writeInit(1, 10);
      await journal2.close();
      await DownloadJournal.deleteJournalFor(tempFile);
      expect(await File('$tempFile.journal').exists(), isFalse);
    });

    test('DownloadJournal dispose is safe before open', () {
      final journal = DownloadJournal('${tempDir.path}/unopened.journal');
      journal.dispose();
    });

    test('non-durable save dedups repeated identical writes', () async {
      final store = StateStoreInstance();
      final tempFile = '${tempDir.path}/dedup.dmxpart';
      await File(tempFile).writeAsBytes(List<int>.filled(200, 0), flush: true);
      final state = TransferState(
        totalSize: 200,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 199, downloaded: 50)],
      );

      await store.save(tempFile, state, taskId: 'd');
      await store.save(tempFile, state, taskId: 'd');
      expect(await File(store.pathFor(tempFile, taskId: 'd')).exists(), isTrue);
    });

    test('durable save refuses to regress recorded progress', () async {
      final store = StateStoreInstance();
      final tempFile = '${tempDir.path}/stale.dmxpart';
      final advanced = TransferState(
        totalSize: 200,
        threadCount: 2,
        chunks: [
          ChunkState(start: 0, end: 99, downloaded: 100),
          ChunkState(start: 100, end: 199, downloaded: 100),
        ],
      );
      await store.save(tempFile, advanced, durable: true, taskId: 's');

      final regressed = TransferState(
        totalSize: 200,
        threadCount: 2,
        chunks: [
          ChunkState(start: 0, end: 99, downloaded: 10),
          ChunkState(start: 100, end: 199, downloaded: 10),
        ],
      );
      await store.save(tempFile, regressed, durable: true, taskId: 's');

      final loaded = await store.load(tempFile, taskId: 's');
      expect(loaded!.downloadedBytes, 200);
    });

    test('resetTransferState with taskId clears the scoped legacy files',
        () async {
      final store = StateStoreInstance();
      final tempFile = '${tempDir.path}/scoped.dmxpart';
      final state = TransferState(
        totalSize: 100,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 99, downloaded: 10)],
      );
      await store.save(tempFile, state, durable: true, taskId: 't');
      expect(await File(store.pathFor(tempFile, taskId: 't')).exists(), isTrue);

      await store.resetTransferState(tempFile, taskId: 't');
      expect(
          await File(store.pathFor(tempFile, taskId: 't')).exists(), isFalse);
      await store.remove(tempFile, taskId: 't');
    });

    test('writeCheckpoint persists chunk hashes', () async {
      final path = '${tempDir.path}/hashes.journal';
      final journal = DownloadJournal(path);
      await journal.open();
      await journal.writeInit(2, 1000);
      await journal.writeCheckpoint(
        [100, 50],
        1000,
        hashes: {0: 'deadbeef', 1: 'cafebabe'},
        truncateDeltas: false,
      );
      await journal.close();

      final details = await DownloadJournal.recoverWithDetails(path);
      expect(details, isNotNull);
      expect(details!.chunkHashes[0], 'deadbeef');
      expect(details.chunkHashes[1], 'cafebabe');
    });
  });
}
