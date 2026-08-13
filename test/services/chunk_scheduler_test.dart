import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/engines/http_download_engine.dart';
import 'package:dmx/core/services/download_journal.dart';

void main() {
  group('ChunkScheduler.plan', () {
    test('returns single chunk for totalSize <= 0', () {
      final chunks = ChunkScheduler.plan(totalSize: 0, threadCount: 4);
      expect(chunks.length, equals(1));
      expect(chunks.first.start, equals(0));
      expect(chunks.first.end, equals(-1));
    });

    test('returns single chunk for files smaller than 512KB', () {
      final chunks = ChunkScheduler.plan(totalSize: 100 * 1024, threadCount: 8);
      expect(chunks.length, equals(1));
      expect(chunks.first.start, equals(0));
      expect(chunks.first.end, equals(100 * 1024 - 1));
    });

    test('clamps thread count to range 1-32', () {
      final chunksMax =
          ChunkScheduler.plan(totalSize: 100 * 1024 * 1024, threadCount: 64);
      expect(chunksMax.length, equals(32));

      final chunksMin =
          ChunkScheduler.plan(totalSize: 100 * 1024 * 1024, threadCount: 0);
      expect(chunksMin.length, equals(1));
    });

    test('splits file cleanly into contiguous ranges', () {
      final chunks =
          ChunkScheduler.plan(totalSize: 10 * 1024 * 1024, threadCount: 4);
      expect(chunks.length, equals(4));
      expect(chunks[0].start, equals(0));
      expect(chunks[3].end, equals(10 * 1024 * 1024 - 1));
    });
  });

  group('ChunkScheduler.pendingWork & singleStream', () {
    test('pendingWork filters out completed chunks', () {
      final chunks = [
        ChunkState(start: 0, end: 999, downloaded: 1000), // complete
        ChunkState(start: 1000, end: 1999, downloaded: 500), // incomplete
      ];

      final pending = ChunkScheduler.pendingWork(chunks);
      expect(pending.length, equals(1));
      expect(pending.first.start, equals(1000));
    });

    test('singleStream fallback returns single open-ended chunk', () {
      final stream = ChunkScheduler.singleStream(5000);
      expect(stream.length, equals(1));
      expect(stream.first.start, equals(0));
      expect(stream.first.end, equals(4999));
    });
  });
}
