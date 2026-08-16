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
  });
}
