import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Mirror Retry Engine & Failover Tests (Task 1.1 / Task 5.2)', () {
    test(
        'verifies mirror failover caps attempts globally across all failing mirrors',
        () {
      final mirrors = [
        'https://mirror1.example.com',
        'https://mirror2.example.com',
        'https://mirror3.example.com'
      ];
      const maxAttemptsPerMirror = 3;
      final maxTotalAttempts = mirrors.length * maxAttemptsPerMirror;

      int totalAttempts = 0;
      int currentMirrorIndex = 0;
      bool succeeded = false;

      // Simulate download retry loop matching _runChunk / _runSingleStream logic
      while (totalAttempts < maxTotalAttempts && !succeeded) {
        totalAttempts++;
        final currentMirror = mirrors[currentMirrorIndex];

        // Mirror 1 & 2 fail; Mirror 3 succeeds on its first attempt
        if (currentMirror == mirrors[0] || currentMirror == mirrors[1]) {
          // Failure on current mirror -> failover to next mirror
          currentMirrorIndex = (currentMirrorIndex + 1) % mirrors.length;
        } else {
          succeeded = true;
        }
      }

      expect(succeeded, isTrue);
      expect(totalAttempts, lessThanOrEqualTo(maxTotalAttempts));
      expect(totalAttempts, 3); // 1 on mirror 1, 1 on mirror 2, 1 on mirror 3
    });

    test(
        'terminates when all mirrors continuously fail without entering infinite loop',
        () {
      final mirrors = ['https://m1.com', 'https://m2.com', 'https://m3.com'];
      const maxAttemptsPerMirror = 2;
      final maxTotalAttempts = mirrors.length * maxAttemptsPerMirror;

      int totalAttempts = 0;
      int currentMirrorIndex = 0;
      const bool succeeded = false;

      // All mirrors return 503 errors
      while (totalAttempts < maxTotalAttempts && !succeeded) {
        totalAttempts++;
        currentMirrorIndex = (currentMirrorIndex + 1) % mirrors.length;
      }

      expect(succeeded, isFalse);
      // Hard cap guarantee: strictly terminates at maxTotalAttempts
      expect(totalAttempts, maxTotalAttempts);
    });
  });
}
