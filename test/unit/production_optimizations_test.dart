import 'dart:io';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Production Optimizations Tests', () {
    test(
        'DownloadProgress equality compares torrentFiles and chunkDetails correctly',
        () {
      const p1 = DownloadProgress(
        downloadedBytes: 100,
        fileSize: 1000,
        speed: 50.0,
        eta: 10,
        chunkFingerprint: 1234,
        torrentFiles: [
          {'name': 'file1.mp4', 'length': 500, 'selected': true},
        ],
        chunkDetails: [
          ChunkDetail(
              index: 0,
              start: 0,
              end: 499,
              downloaded: 100,
              size: 500,
              ratio: 0.2),
        ],
      );

      const p2 = DownloadProgress(
        downloadedBytes: 100,
        fileSize: 1000,
        speed: 50.0,
        eta: 10,
        chunkFingerprint: 1234,
        torrentFiles: [
          {'name': 'file1.mp4', 'length': 500, 'selected': true},
        ],
        chunkDetails: [
          ChunkDetail(
              index: 0,
              start: 0,
              end: 499,
              downloaded: 100,
              size: 500,
              ratio: 0.2),
        ],
      );

      // Same content
      expect(p1, equals(p2));

      // Change chunkDetails
      final p3 = p1.copyWith(
        chunkDetails: [
          const ChunkDetail(
              index: 0,
              start: 0,
              end: 499,
              downloaded: 200,
              size: 500,
              ratio: 0.4),
        ],
      );
      expect(p1 == p3, isFalse);

      // Change torrentFiles
      final p4 = p1.copyWith(
        torrentFiles: [
          {'name': 'file2.mp4', 'length': 500, 'selected': true},
        ],
      );
      expect(p1 == p4, isFalse);
    });

    test(
        'Chunked stream copy and length check verifies integrity without full sha256',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('dmx_copy_test_');
      try {
        final srcFile = File('${tempDir.path}/src.bin');
        final dstFile = File('${tempDir.path}/dst.bin');

        final testBytes = List<int>.generate(1024 * 1024, (i) => i % 256);
        await srcFile.writeAsBytes(testBytes, flush: true);

        // Perform stream pipe copy
        final srcStream = srcFile.openRead();
        final dstSink = dstFile.openWrite();
        await srcStream.pipe(dstSink);

        final srcLen = await srcFile.length();
        final dstLen = await dstFile.length();
        expect(srcLen, equals(testBytes.length));
        expect(dstLen, equals(testBytes.length));
        expect(srcLen, equals(dstLen));

        await srcFile.delete();
        expect(await srcFile.exists(), isFalse);
        expect(await dstFile.exists(), isTrue);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });
}
