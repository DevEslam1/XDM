import 'dart:async';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/engine/cancellable_delayer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CancellableDelayer', () {
    test('completes normal delay if not cancelled', () async {
      final delayer = CancellableDelayer();
      final stopwatch = Stopwatch()..start();
      await delayer.delay(const Duration(milliseconds: 50));
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds >= 40, isTrue);
    });

    test('cancels delay immediately when CancelToken triggers', () async {
      final cancelToken = CancelToken();
      final delayer = CancellableDelayer(cancelToken);

      final future = delayer.delay(const Duration(seconds: 10));

      // Cancel token after 20ms
      Timer(const Duration(milliseconds: 20), () {
        cancelToken.cancel('cancelled for test');
      });

      final stopwatch = Stopwatch()..start();
      await future;
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds < 500, isTrue);
    });

    test('returns immediately if CancelToken was already cancelled', () async {
      final cancelToken = CancelToken()..cancel('already cancelled');
      final delayer = CancellableDelayer(cancelToken);

      final stopwatch = Stopwatch()..start();
      await delayer.delay(const Duration(seconds: 10));
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds < 50, isTrue);
    });
  });
}
