import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/retry_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RetryEngine CancelToken in Backoff Delay (EH-02)', () {
    test('cancelling token during backoff delay aborts immediately', () async {
      final engine = RetryEngine(
        baseDelay: const Duration(seconds: 10), // 10s delay
        maxRetries: 3,
      );

      final cancelToken = CancelToken();
      final sw = Stopwatch()..start();
      var callCount = 0;

      // Cancel token after 20ms while engine is waiting in delay
      Future.delayed(const Duration(milliseconds: 20), () {
        cancelToken.cancel('User cancelled test');
      });

      expect(
        () => engine.execute(
          () async {
            callCount++;
            // Throw retryable socket exception on first call
            throw const SocketException('Transient connection failure');
          },
          cancelToken: cancelToken,
        ),
        throwsA(isA<DioException>()),
      );

      sw.stop();
      // Should abort in less than 500ms, not waiting for 10s delay
      expect(sw.elapsedMilliseconds, lessThan(500));
      expect(callCount, equals(1));
    });
  });
}
