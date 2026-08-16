import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:flutter_test/flutter_test.dart';

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
      expect(
          () => governor.removeTaskLimit('task-nonexistent'), returnsNormally);
    });

    test('acquireNonBlocking calculates wait correctly for probe requests', () {
      final governor = BandwidthGovernor(0, 1.0);
      governor.setTaskLimit('task-1', 1000); // 1000 bytes/sec
      
      // First acquire of 1000 bytes immediately
      final wait1 = governor.acquireNonBlocking(1000, taskId: 'task-1');
      expect(wait1, equals(0));

      // Immediate second acquire of 1000 bytes should incur deficit wait
      final wait2 = governor.acquireNonBlocking(1000, taskId: 'task-1');
      expect(wait2, greaterThan(0));
    });

    test('token refill and burst allowance allow temporary overshoot', () async {
      final governor = BandwidthGovernor(0, 1.5);
      governor.setTaskLimit('task-burst', 1000); // 1000 B/s, burst capacity 1500 B

      // Allow 1.5s refill
      await Future.delayed(const Duration(milliseconds: 1500));

      // Can acquire up to 1500 bytes with 0 wait due to burst
      final wait1 = governor.acquireNonBlocking(1500, taskId: 'task-burst');
      expect(wait1, equals(0));

      // Next immediate acquire of 1000 bytes should exceed burst allowance and incur deficit wait
      final wait2 = governor.acquireNonBlocking(1000, taskId: 'task-burst');
      expect(wait2, greaterThan(0));
    });

    test('multi-task fairness allocates independent buckets per task', () {
      final governor = BandwidthGovernor(0, 1.0);
      governor.setTaskLimit('task-a', 5000);
      governor.setTaskLimit('task-b', 10000);

      // Task A acquiring within limit
      expect(governor.acquireNonBlocking(5000, taskId: 'task-a'), equals(0));
      // Task B acquiring within limit
      expect(governor.acquireNonBlocking(10000, taskId: 'task-b'), equals(0));

      // Immediate second acquire on task-a incurs wait without affecting task-b
      final waitA = governor.acquireNonBlocking(5000, taskId: 'task-a');
      expect(waitA, greaterThan(0));
    });
  });
}
