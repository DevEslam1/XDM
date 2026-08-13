import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/bandwidth_governor.dart';

void main() {
  group('BandwidthGovernor', () {
    test('1. acquire() returns 0 when unlimited (limit=0)', () async {
      final governor = BandwidthGovernor(0);
      final waitMs = await governor.acquire(1024);
      expect(waitMs, equals(0));
      expect(governor.isUnlimited, isTrue);
    });

    test('2. acquire() returns wait time when over limit', () async {
      final governor = BandwidthGovernor(1000); // 1000 B/s limit
      governor.registerConsumer();
      // First acquire gets burst allowance
      await governor.acquire(1000);
      // Large acquire should ask to wait
      final waitMs = await governor.acquire(10000);
      expect(waitMs, greaterThan(0));
    });

    test('3. Task limit overrides global limit', () {
      final governor = BandwidthGovernor(100000);
      governor.setTaskLimit('task-1', 500);
      expect(governor.getTaskLimit('task-1'), equals(500));
    });

    test('4. registerConsumer/unregisterConsumer adjusts per-consumer share',
        () {
      final governor = BandwidthGovernor(10000);
      expect(governor.activeConsumers, equals(0));
      governor.registerConsumer();
      expect(governor.activeConsumers, equals(1));
      expect(governor.perConsumerBytesPerSecond, equals(10000));
      governor.registerConsumer();
      expect(governor.activeConsumers, equals(2));
      expect(governor.perConsumerBytesPerSecond, equals(5000));
      governor.unregisterConsumer();
      expect(governor.activeConsumers, equals(1));
    });

    test('5. setGlobalLimit(0) makes unlimited', () {
      final governor = BandwidthGovernor(5000);
      governor.registerConsumer();
      expect(governor.isUnlimited, isFalse);
      governor.setGlobalLimit(0);
      expect(governor.isUnlimited, isTrue);
    });

    test('6. burstFactor clamped to 1.0-4.0', () {
      final governor = BandwidthGovernor(1000, 0.5);
      expect(governor.burstFactor, equals(1.0));
      governor.setBurstFactor(10.0);
      expect(governor.burstFactor, equals(4.0));
    });
  });
}
