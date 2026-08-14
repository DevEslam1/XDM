import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/bandwidth_governor.dart';

void main() {
  group('BandwidthGovernor', () {
    test('defaults to unlimited when limit is 0', () {
      final governor = BandwidthGovernor(0);
      expect(governor.isUnlimited, true);
      expect(governor.globalBytesPerSecond, 0);
      expect(governor.perConsumerBytesPerSecond, 0);
    });

    test('calculates per-consumer bandwidth share accurately', () {
      final governor = BandwidthGovernor(1000000); // 1 MB/s
      governor.registerConsumer();
      governor.registerConsumer();

      expect(governor.activeConsumers, 2);
      expect(governor.isUnlimited, false);
      expect(governor.perConsumerBytesPerSecond, 500000);
    });

    test('register and unregister consumer updates active count safely', () {
      final governor = BandwidthGovernor(500000);
      governor.registerConsumer();
      expect(governor.activeConsumers, 1);

      governor.unregisterConsumer();
      expect(governor.activeConsumers, 0);

      // Unregistering when 0 does not go negative
      governor.unregisterConsumer();
      expect(governor.activeConsumers, 0);
    });

    test('setBurstFactor clamps between 1.0 and 1.5', () {
      final governor = BandwidthGovernor(1000000);
      governor.setBurstFactor(2.0);
      expect(governor.burstFactor, 1.5);

      governor.setBurstFactor(0.5);
      expect(governor.burstFactor, 1.0);
    });

    test('setTaskLimit and removeTaskLimit manage per-task quotas', () {
      final governor = BandwidthGovernor(0);
      governor.setTaskLimit('task-1', 250000);
      governor.removeTaskLimit('task-1');
      expect(() => governor.removeTaskLimit('task-nonexistent'), returnsNormally);
    });
  });
}
