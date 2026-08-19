import 'dart:async';
import 'package:dmx/core/utils/timer_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TimerRegistry', () {
    tearDown(() {
      TimerRegistry.cancelAll();
    });

    test('register and unregister timers', () {
      expect(TimerRegistry.activeCount, 0);

      final timer1 = Timer(const Duration(hours: 1), () {});
      TimerRegistry.register('t1', timer1);

      expect(TimerRegistry.activeCount, 1);
      expect(TimerRegistry.activeTimers.contains('t1'), isTrue);

      TimerRegistry.unregister('t1');
      expect(TimerRegistry.activeCount, 0);
      expect(timer1.isActive, isFalse);
    });

    test('cancelAll cancels all registered timers', () {
      final t1 = Timer(const Duration(hours: 1), () {});
      final t2 = Timer(const Duration(hours: 1), () {});

      TimerRegistry.register('timer_1', t1);
      TimerRegistry.register('timer_2', t2);

      expect(TimerRegistry.activeCount, 2);

      TimerRegistry.cancelAll();

      expect(TimerRegistry.activeCount, 0);
      expect(t1.isActive, isFalse);
      expect(t2.isActive, isFalse);
    });
  });
}
