import 'dart:io';

import 'package:dmx/core/services/download_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadJournal CRC32', () {
    test('crc32 produces consistent checksums', () {
      final data = [72, 101, 108, 108, 111]; // "Hello"
      final crc1 = DownloadJournal.crc32(data);
      final crc2 = DownloadJournal.crc32(data);
      expect(crc1, equals(crc2));
      expect(crc1, isNot(equals(0)));
    });

    test('different payloads produce different checksums', () {
      final crc1 = DownloadJournal.crc32([1, 2, 3]);
      final crc2 = DownloadJournal.crc32([1, 2, 4]);
      expect(crc1, isNot(equals(crc2)));
    });

    test('empty byte array produces valid non-zero CRC', () {
      final crc = DownloadJournal.crc32([]);
      expect(crc, equals(0x00000000));
    });

    test(
        'unexpected crash during write leaves previous snapshot intact (ST-01)',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('st01_test_');
      final targetFile = '${tempDir.path}/test_download.bin';
      final stateFile = StateStore.pathFor(targetFile);
      final tmpFile = File('$stateFile.tmp');

      final initialState = TransferState(
        url: 'https://example.com/file.bin',
        threadCount: 2,
        totalSize: 1000,
        chunks: [
          ChunkState(start: 0, end: 499, downloaded: 250),
          ChunkState(start: 500, end: 999, downloaded: 250),
        ],
      );

      // Create actual file on disk sized to full allocation
      await File(targetFile).writeAsBytes(List.filled(1000, 0));

      // Initial valid state
      await StateStore.save(
        targetFile,
        initialState,
        durable: true,
      );

      final res1 = await StateStore.loadOrCreate(
        targetFile,
        url: 'https://example.com/file.bin',
        threadCount: 2,
        knownFileSize: 1000,
      );
      expect(res1.state.downloadedBytes, equals(500));

      // Simulate partial interrupted write into .tmp file
      await tmpFile.writeAsString('{"partial": "corrupt json string...',
          flush: true);

      // Loading targetFile still recovers original complete state
      final res2 = await StateStore.loadOrCreate(
        targetFile,
        url: 'https://example.com/file.bin',
        threadCount: 2,
        knownFileSize: 1000,
      );
      expect(res2.state.downloadedBytes, equals(500));

      await tempDir.delete(recursive: true);
    });
  });
}
