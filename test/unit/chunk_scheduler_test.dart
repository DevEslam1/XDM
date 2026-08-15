import 'package:dmx/core/services/engines/http_download_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChunkScheduler.plan()', () {
    test('1. totalSize=0 returns single chunk', () {
      final chunks = ChunkScheduler.plan(totalSize: 0, threadCount: 4);
      expect(chunks.length, equals(1));
      expect(chunks.first.start, equals(0));
      expect(chunks.first.end, equals(-1));
    });

    test('2. totalSize < minSizeForMultithread returns 1 chunk', () {
      final chunks = ChunkScheduler.plan(totalSize: 256 * 1024, threadCount: 4);
      expect(chunks.length, equals(1));
    });

    test('3. threadCount=1 returns 1 chunk', () {
      final chunks =
          ChunkScheduler.plan(totalSize: 10 * 1024 * 1024, threadCount: 1);
      expect(chunks.length, equals(1));
    });

    test('4. Normal split: 10MB with 4 threads = 4 equal chunks', () {
      const totalSize = 10 * 1024 * 1024;
      final chunks = ChunkScheduler.plan(totalSize: totalSize, threadCount: 4);
      expect(chunks.length, equals(4));
    });

    test('5. Last chunk gets remainder bytes', () {
      const totalSize = 10000007; // Not evenly divisible by 4
      final chunks = ChunkScheduler.plan(totalSize: totalSize, threadCount: 4);
      expect(chunks.length, equals(4));
      expect(chunks.last.end, equals(totalSize - 1));
    });

    test('6. threadCount > totalSize returns 1 chunk', () {
      final chunks = ChunkScheduler.plan(totalSize: 100, threadCount: 8);
      expect(chunks.length, equals(1));
    });

    test('7. threadCount clamped to 1..32', () {
      final chunksHigh =
          ChunkScheduler.plan(totalSize: 50 * 1024 * 1024, threadCount: 64);
      expect(chunksHigh.length, lessThanOrEqualTo(32));

      final chunksLow =
          ChunkScheduler.plan(totalSize: 50 * 1024 * 1024, threadCount: -5);
      expect(chunksLow.length, equals(1));
    });
  });
}
