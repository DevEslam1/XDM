import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BandwidthGovernor Tests', () {
    test('initialization and burst factor clamping', () {
      final gov1 = BandwidthGovernor(1000, 0.5);
      expect(gov1.burstFactor, 1.0); // clamped to 1.0

      final gov2 = BandwidthGovernor(1000, 5.0);
      expect(gov2.burstFactor, 4.0); // clamped to 4.0

      final gov3 = BandwidthGovernor(1000, 2.5);
      expect(gov3.burstFactor, 2.5);
    });

    test('setBurstFactor clamping', () {
      final gov = BandwidthGovernor(1000, 2.0);
      gov.setBurstFactor(0.1);
      expect(gov.burstFactor, 1.0);

      gov.setBurstFactor(10.0);
      expect(gov.burstFactor, 4.0);
    });

    test('isUnlimited behavior', () {
      final gov = BandwidthGovernor(0);
      expect(gov.isUnlimited, isTrue);

      gov.setGlobalLimit(1000);
      expect(gov.isUnlimited, isTrue); // no consumers

      gov.registerConsumer();
      expect(gov.isUnlimited, isFalse);

      gov.unregisterConsumer();
      expect(gov.isUnlimited, isTrue);
    });

    test('perConsumerBytesPerSecond calculates correctly', () {
      final gov = BandwidthGovernor(10000);
      expect(gov.perConsumerBytesPerSecond, 0);

      gov.registerConsumer();
      expect(gov.perConsumerBytesPerSecond, greaterThan(0));

      gov.registerConsumer();
      expect(gov.perConsumerBytesPerSecond, greaterThan(0));
    });

    test('acquire returns 0 immediately if unlimited or non-positive bytes',
        () async {
      final gov = BandwidthGovernor(0);
      expect(await gov.acquire(0), 0);
      expect(await gov.acquire(-10), 0);
      expect(await gov.acquire(100), 0);
    });

    test('acquire limits bandwidth and returns expected wait time', () async {
      final gov = BandwidthGovernor(1000);
      gov.registerConsumer();

      // Acquire 2000 bytes. With 1000 bytes/sec limit, we should expect a delay.
      final waitMs = await gov.acquire(2000);
      expect(waitMs, greaterThan(0));
    });

    test('domain speed reporting and average calculations', () {
      final gov = BandwidthGovernor(0);
      expect(gov.getAverageSpeedForDomain('example.com'), 0.0);

      gov.reportDomainSpeed('example.com', 100.0);
      gov.reportDomainSpeed('example.com', 200.0);
      expect(gov.getAverageSpeedForDomain('example.com'), 150.0);

      gov.reportDomainSpeed('', 300.0); // empty domain should be ignored
      expect(gov.getAverageSpeedForDomain(''), 0.0);

      // Verify rotation after 20 entries
      for (int i = 0; i < 25; i++) {
        gov.reportDomainSpeed('example.com', 10.0);
      }
      expect(gov.getAverageSpeedForDomain('example.com'), 10.0);
    });

    test('task-level limits isolate and bypass global share', () async {
      final gov = BandwidthGovernor(1000);
      gov.registerConsumer();

      final normalWait = await gov.acquire(2000);
      expect(normalWait, greaterThan(0));

      gov.setTaskLimit('task1', 0);
      expect(await gov.acquire(2000, taskId: 'task1'), 0);

      gov.setTaskLimit('task2', 5000);
      final taskWait = await gov.acquire(2000, taskId: 'task2');
      expect(taskWait, lessThan(normalWait));

      gov.removeTaskLimit('task2');
      final fallbackWait = await gov.acquire(2000, taskId: 'task2');
      expect(fallbackWait, greaterThan(0));
    });
  });
}
