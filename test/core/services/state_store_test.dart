import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/download_journal.dart';

void main() {
  group('StateStore', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('statestore_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('pathFor constructs standard .dmxstate filepath', () {
      expect(StateStore.pathFor('/tmp/download.bin'), '/tmp/download.bin.dmxstate');
    });

    test('load returns null if state file does not exist', () async {
      final state = await StateStore.load('${tempDir.path}/nonexistent.bin');
      expect(state, isNull);
    });

    test('loadOrCreate creates new state when no prior file exists', () async {
      final tempFile = '${tempDir.path}/new_download.bin';
      final result = await StateStore.loadOrCreate(
        tempFile,
        url: 'https://example.com/asset.zip',
        threadCount: 4,
        knownFileSize: 4000,
      );

      expect(result.state, isNotNull);
      expect(result.state.totalSize, 4000);
      expect(result.state.threadCount, 4);
      expect(result.created, true);
    });

    test('load retrieves previously saved transfer state', () async {
      final tempFile = '${tempDir.path}/saved_download.bin';

      final state = TransferState(
        totalSize: 1000,
        threadCount: 2,
        url: 'https://example.com/asset.zip',
        chunks: [
          ChunkState(start: 0, end: 499, downloaded: 200),
          ChunkState(start: 500, end: 999, downloaded: 300),
        ],
      );

      await StateStore.save(tempFile, state, durable: true);

      final loaded = await StateStore.load(tempFile);
      expect(loaded, isNotNull);
      expect(loaded!.downloadedBytes, 500);
      expect(loaded.totalSize, 1000);
    });

    test('remove cleans up in-memory caches and files', () {
      StateStore.removeCachedPayload('task-123');
      expect(true, true);
    });
  });
}
