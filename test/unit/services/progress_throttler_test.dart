import 'package:dmx/core/services/engine/progress_throttler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProgressThrottler', () {
    test('emits first report immediately and throttles rapid subsequent reports',
        () async {
      final emitted = <Map<String, dynamic>>[];
      final throttler = ProgressThrottler(
        getForegroundInterval: () => const Duration(milliseconds: 100),
        getBackgroundInterval: () => const Duration(milliseconds: 500),
        onEmit: (data) => emitted.add(data),
      );

      // Rapidly report 10 updates
      for (int i = 0; i < 10; i++) {
        throttler.report({'progress': i});
      }

      // First report should be emitted immediately
      expect(emitted.length, 1);
      expect(emitted.first['progress'], 0);

      // Wait for throttle timer to fire
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // After throttle interval, trailing progress (9) should have emitted
      expect(emitted.length, 2);
      expect(emitted.last['progress'], 9);

      throttler.dispose();
    });

    test('isTerminal forces immediate emit regardless of throttle interval', () {
      final emitted = <Map<String, dynamic>>[];
      final throttler = ProgressThrottler(
        getForegroundInterval: () => const Duration(seconds: 10),
        getBackgroundInterval: () => const Duration(seconds: 30),
        onEmit: (data) => emitted.add(data),
      );

      throttler.report({'progress': 1});
      expect(emitted.length, 1);

      // Terminal emit right after
      throttler.report({'progress': 100, 'done': true}, isTerminal: true);
      expect(emitted.length, 2);
      expect(emitted.last['progress'], 100);

      throttler.dispose();
    });
  });
}
