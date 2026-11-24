import 'package:dmx/core/services/yt_counterpart_coordinator.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('YtCounterpartCoordinator', () {
    late YtCounterpartCoordinator coordinator;

    setUp(() {
      coordinator = YtCounterpartCoordinator(enablePeriodicTimer: false);
    });

    tearDown(() => coordinator.dispose());

    test('registerCounterpart links both directions', () {
      coordinator.registerCounterpart('video', 'audio');
      expect(coordinator.getCounterpartId('video'), 'audio');
      expect(coordinator.getCounterpartId('audio'), 'video');
      expect(coordinator.getCounterpartId('missing'), isNull);
    });

    test('live bytes are stored and retrieved', () {
      expect(coordinator.getLiveBytes('t1'), isNull);
      coordinator.updateLiveBytes('t1', 1234);
      expect(coordinator.getLiveBytes('t1'), 1234);
      coordinator.updateLiveBytes('t1', 9999);
      expect(coordinator.getLiveBytes('t1'), 9999);
    });

    test('isLiveBytesStale is false for unknown or freshly touched tasks', () {
      expect(coordinator.isLiveBytesStale('unknown'), isFalse);
      coordinator.updateLiveBytes('t1', 1);
      expect(coordinator.isLiveBytesStale('t1'), isFalse);
    });

    test('markFinished and isStreamFinished reflect state', () {
      expect(coordinator.isStreamFinished('t1'), isFalse);
      coordinator.markFinished('t1');
      expect(coordinator.isStreamFinished('t1'), isTrue);
    });

    test('isCounterpartFinished requires a finished counterpart', () {
      coordinator.registerCounterpart('a', 'b');
      expect(coordinator.isCounterpartFinished('a'), isFalse);
      coordinator.markFinished('b');
      expect(coordinator.isCounterpartFinished('a'), isTrue);
      expect(coordinator.isCounterpartFinished('unregistered'), isFalse);
    });

    test('unregister removes an unpaired task immediately', () {
      coordinator.updateLiveBytes('solo', 10);
      coordinator.unregister('solo');
      expect(coordinator.getLiveBytes('solo'), isNull);
      expect(coordinator.isStreamFinished('solo'), isFalse);
    });

    test('unregister clears both legs when counterpart already finished', () {
      coordinator.registerCounterpart('a', 'b');
      coordinator.updateLiveBytes('a', 1);
      coordinator.updateLiveBytes('b', 2);
      coordinator.markFinished('a');
      coordinator.markFinished('b');

      coordinator.unregister('a');

      expect(coordinator.getCounterpartId('a'), isNull);
      expect(coordinator.getCounterpartId('b'), isNull);
      expect(coordinator.isStreamFinished('a'), isFalse);
      expect(coordinator.isStreamFinished('b'), isFalse);
      expect(coordinator.getLiveBytes('a'), isNull);
      expect(coordinator.getLiveBytes('b'), isNull);
    });

    test('unregister waits for a still-running counterpart', () {
      coordinator.registerCounterpart('a', 'b');
      coordinator.markFinished('a');

      coordinator.unregister('a');

      // Pair preserved until the 10-minute cleanup timer fires.
      expect(coordinator.getCounterpartId('a'), 'b');
      expect(coordinator.isStreamFinished('a'), isTrue);
    });

    test('dispose cancels the periodic and cleanup timers', () async {
      final withTimer = YtCounterpartCoordinator();
      withTimer.registerCounterpart('a', 'b');
      withTimer.markFinished('a');
      withTimer.unregister('a'); // schedules a cleanup timer
      withTimer.dispose();
      withTimer.dispose(); // idempotent
    });

    test('periodic purge and cleanup timers fire on schedule', () {
      fakeAsync((async) {
        final coordinator = YtCounterpartCoordinator();
        coordinator.registerCounterpart('a', 'b');
        coordinator.updateLiveBytes('a', 1);
        coordinator.markFinished('a');
        coordinator.unregister('a'); // schedules the 10-minute cleanup timer

        async.elapse(const Duration(minutes: 11));
        async.flushMicrotasks();

        expect(coordinator.getCounterpartId('a'), isNull);
        expect(coordinator.isStreamFinished('a'), isFalse);
        coordinator.dispose();
      });
    });
  });
}
