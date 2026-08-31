import 'package:dmx/core/services/engines/mirror_parallel_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MirrorParallelEngine', () {
    test('distributeThreads distributes threads evenly across mirrors', () {
      final mirrors = ['https://m1.com/file', 'https://m2.com/file'];
      final engine = MirrorParallelEngine(mirrors);

      final dist = engine.distributeThreads(8);
      expect(dist.length, 2);
      expect(dist['https://m1.com/file'], [0, 1, 2, 3]);
      expect(dist['https://m2.com/file'], [4, 5, 6, 7]);
    });

    test('distributeThreads handles odd numbers with remainder', () {
      final mirrors = ['https://m1.com', 'https://m2.com', 'https://m3.com'];
      final engine = MirrorParallelEngine(mirrors);

      final dist = engine.distributeThreads(7);
      expect(dist['https://m1.com']!.length, 3);
      expect(dist['https://m2.com']!.length, 2);
      expect(dist['https://m3.com']!.length, 2);
    });

    test('reportMirrorSpeed records speed', () {
      final engine = MirrorParallelEngine(['https://m1.com', 'https://m2.com']);
      engine.reportMirrorSpeed('https://m1.com', 500000);
      engine.reportMirrorSpeed('https://m2.com', 100000);
    });
  });
}
