import 'dart:io';

import 'package:dmx/core/services/download_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('statestore_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('StateStore', () {
    test('1. loadOrCreate creates new state when no file exists', () async {
      final tempFilePath = '${tempDir.path}/file.tmp';
      final res = await StateStore.loadOrCreate(
        tempFilePath,
        url: 'https://example.com/test.bin',
        threadCount: 4,
        knownFileSize: 10000,
      );

      expect(res.state, isNotNull);
      expect(res.state.totalSize, equals(10000));
      expect(res.created, isTrue);
    });

    test('2. loadOrCreate reads valid v3 state', () async {
      final tempFilePath = '${tempDir.path}/test2.tmp';
      await File(tempFilePath).writeAsBytes(List.filled(20000, 0));
      final state = TransferState(
        totalSize: 20000,
        threadCount: 2,
        chunks: [
          ChunkState(start: 0, end: 9999, downloaded: 5000),
          ChunkState(start: 10000, end: 19999, downloaded: 5000),
        ],
        url: 'https://example.com/file2.bin',
      );
      await StateStore.save(tempFilePath, state);

      final res = await StateStore.loadOrCreate(
        tempFilePath,
        url: 'https://example.com/file2.bin',
        threadCount: 2,
        knownFileSize: 20000,
      );

      expect(res.created, isFalse);
      expect(res.state.totalSize, equals(20000));
      expect(res.state.downloadedBytes, equals(10000));
    });

    test('3. loadOrCreate migrates v2 state to v3', () async {
      final tempFilePath = '${tempDir.path}/test_v2.tmp';
      final statePath = StateStore.pathFor(tempFilePath);
      const v2Json =
          '{"totalSize":10000,"progress":[2000,3000],"threadCount":2,"url":"https://example.com/v2.bin"}';
      await File(statePath).writeAsString(v2Json);

      final res = await StateStore.loadOrCreate(
        tempFilePath,
        url: 'https://example.com/v2.bin',
        threadCount: 2,
        knownFileSize: 10000,
      );

      expect(res.state, isNotNull);
      expect(res.migratedFrom, equals('v2'));
    });

    test('4. loadOrCreate recovers from journal when state corrupt', () async {
      final tempFilePath = '${tempDir.path}/test_corrupt.tmp';
      final statePath = StateStore.pathFor(tempFilePath);
      await File(statePath).writeAsString('CORRUPT_JSON_DATA');

      final journalPath = '$tempFilePath.journal';
      final journal = DownloadJournal(journalPath);
      await journal.open();
      await journal.writeInit(2, 5000);
      await journal.writeCheckpoint([2500, 2500], 5000);
      await journal.close();

      final res = await StateStore.loadOrCreate(
        tempFilePath,
        url: 'https://example.com/corrupt.bin',
        threadCount: 2,
        knownFileSize: 5000,
      );

      expect(res.state, isNotNull);
      expect(res.migratedFrom, equals('journal'));
    });

    test('5. save() writes atomically (tmp + rename)', () async {
      final tempFilePath = '${tempDir.path}/atomic.tmp';
      final state = TransferState(
        totalSize: 5000,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 4999, downloaded: 1000)],
        url: 'https://example.com/atomic',
      );
      await StateStore.save(tempFilePath, state);

      final statePath = StateStore.pathFor(tempFilePath);
      expect(await File(statePath).exists(), isTrue);
      expect(await File('$statePath.tmp').exists(), isFalse);
    });

    test('6. save() skips identical payload (dedup)', () async {
      final tempFilePath = '${tempDir.path}/dedup.tmp';
      final state = TransferState(
        totalSize: 5000,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 4999, downloaded: 1000)],
        url: 'https://example.com/dedup',
      );
      await StateStore.save(tempFilePath, state);
      final stat1 = await File(StateStore.pathFor(tempFilePath)).stat();

      await StateStore.save(tempFilePath, state);
      final stat2 = await File(StateStore.pathFor(tempFilePath)).stat();

      expect(stat2.modified, equals(stat1.modified));
    });

    test('7. remove() deletes state file', () async {
      final tempFilePath = '${tempDir.path}/remove.tmp';
      final state = TransferState(
        totalSize: 5000,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 4999, downloaded: 1000)],
        url: 'https://example.com/remove',
      );
      final store = StateStoreInstance();
      await store.save(tempFilePath, state);
      final statePath = StateStore.pathFor(tempFilePath);
      expect(await File(statePath).exists(), isTrue);

      await store.remove(tempFilePath);
      expect(await File(statePath).exists(), isFalse);
    });

    test('8. StateStoreFactory creates and isolates instances', () async {
      final factory = StateStoreFactory();
      final defaultStore = factory.defaultStore;
      final customStore = factory.getOrCreate(name: 'worker-1');

      expect(defaultStore, isNotNull);
      expect(customStore, isNotNull);
      expect(identical(defaultStore, customStore), isFalse);
      expect(identical(factory.getOrCreate(name: 'worker-1'), customStore), isTrue);

      final tempFilePath = '${tempDir.path}/factory_test.tmp';
      final state = TransferState(
        totalSize: 3000,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 2999, downloaded: 1500)],
        url: 'https://example.com/factory',
      );
      await customStore.save(tempFilePath, state);
      final loaded = await customStore.load(tempFilePath);
      expect(loaded, isNotNull);
      expect(loaded!.downloadedBytes, 1500);
      await customStore.remove(tempFilePath);
    });
  });
}
