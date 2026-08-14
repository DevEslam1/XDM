import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/engines/http_download_engine.dart';

void main() {
  group('H-1 Chunk Redistribution with Overlap Mapping', () {
    test('redistributing 4 chunks (each partially downloaded) to 8 chunks maps byte ranges accurately', () {
      // 1MB total size (> minSizeForMultithread)
      final totalSize = 1024 * 1024; // 1,048,576 bytes
      final oldChunks = ChunkScheduler.plan(totalSize: totalSize, threadCount: 4);
      expect(oldChunks.length, 4);

      // Set 50,000 bytes downloaded in each old chunk
      for (final c in oldChunks) {
        c.downloaded = 50000;
      }

      // New 8 chunks
      final newChunks = ChunkScheduler.plan(totalSize: totalSize, threadCount: 8);
      expect(newChunks.length, 8);

      for (var ni = 0; ni < newChunks.length; ni++) {
        final nc = newChunks[ni];
        int overlap = 0;
        for (final oc in oldChunks) {
          final int oStart = oc.start;
          final int oEnd = oc.start + oc.downloaded;
          final int nStart = nc.start;
          final int nEnd = nc.end >= 0 ? nc.end : nc.start + nc.size - 1;
          final int lo = max<int>(oStart, nStart);
          final int hi = min<int>(oEnd, nEnd);
          if (hi > lo) overlap += (hi - lo);
        }
        nc.downloaded = overlap;
      }

      // Even chunks (0, 2, 4, 6) start at the same offset as old chunks (0, 1, 2, 3)
      // and contain the 50,000 bytes downloaded in each span.
      expect(newChunks[0].downloaded, 50000);
      expect(newChunks[1].downloaded, 0);
      expect(newChunks[2].downloaded, 50000);
      expect(newChunks[3].downloaded, 0);
      expect(newChunks[4].downloaded, 50000);
      expect(newChunks[5].downloaded, 0);
      expect(newChunks[6].downloaded, 50000);
      expect(newChunks[7].downloaded, 0);

      // Sum matches total downloaded bytes (200,000)
      final sum = newChunks.fold<int>(0, (s, c) => s + c.downloaded);
      expect(sum, 200000);
    });
  });
}
