import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BandwidthGovernor', () {
    test(
        'isUnlimited returns true when global limit is <= 0 or activeConsumers == 0',
        () {
      final governor = BandwidthGovernor(0);
      expect(governor.isUnlimited, isTrue);

      governor.registerConsumer();
      expect(governor.isUnlimited, isTrue);

      governor.setGlobalLimit(1024 * 1024);
      expect(governor.isUnlimited, isFalse);

      governor.unregisterConsumer();
      expect(governor.isUnlimited, isTrue);
    });

    test('registerConsumer and unregisterConsumer update activeConsumers', () {
      final governor = BandwidthGovernor(1000);
      expect(governor.activeConsumers, equals(0));

      governor.registerConsumer();
      governor.registerConsumer();
      expect(governor.activeConsumers, equals(2));

      governor.unregisterConsumer();
      expect(governor.activeConsumers, equals(1));
    });

    test('perConsumerBytesPerSecond divides global limit among consumers', () {
      final governor = BandwidthGovernor(10000);
      governor.registerConsumer();
      governor.registerConsumer();

      expect(governor.perConsumerBytesPerSecond, equals(5000));
    });

    test('setBurstFactor clamps between 1.0 and 1.5', () {
      final governor = BandwidthGovernor(1000, 0.5);
      expect(governor.burstFactor, equals(1.0));

      governor.setBurstFactor(10.0);
      expect(governor.burstFactor, equals(1.5));
    });

    test('task-specific limits can be set and removed', () {
      final governor = BandwidthGovernor();
      governor.setTaskLimit('task-1', 2048);
      expect(governor.getTaskLimit('task-1'), equals(2048));

      governor.removeTaskLimit('task-1');
      expect(governor.getTaskLimit('task-1'), isNull);
    });
  });
}
