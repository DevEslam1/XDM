import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/mirror/mirror_selector.dart';

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

    test(
        'raceMirrors cancels slower mirrors immediately upon winning response (M-01/M-02)',
        () async {
      final mirrors = ['https://fast.com/file', 'https://slow.com/file'];
      bool slowCancelled = false;

      final winner = await MirrorParallelEngine.raceMirrors<String>(
        mirrors,
        (url, cancelToken) async {
          if (url.contains('fast')) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return 'fast_content';
          } else {
            cancelToken.whenCancel.then((_) {
              slowCancelled = true;
            });
            await Future<void>.delayed(const Duration(milliseconds: 500));
            return 'slow_content';
          }
        },
      );

      expect(winner, equals('fast_content'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(slowCancelled, isTrue);
    });
  });
}
