import 'package:battery_plus/battery_plus.dart';
import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:fake_async/fake_async.dart';
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

    test('token refill and burst allowance allow temporary overshoot',
        () async {
      final governor = BandwidthGovernor(0, 1.5);
      governor.setTaskLimit(
          'task-burst', 1000); // 1000 B/s, burst capacity 1500 B

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

    test('global refill is throttled to at most once per 50ms', () {
      final governor = BandwidthGovernor(1000, 1.0);
      governor.registerConsumer();

      // Warm up: first call must perform a refill.
      governor.acquireNonBlocking(1);
      expect(governor.lastRefillMsForTesting, isNonZero);

      // Capture the timestamp from the previous refill.
      final before = governor.lastRefillMsForTesting;

      // A burst of immediate acquires must NOT trigger recomputation
      // (nowMs - lastRefillMs stays well below the 50ms threshold).
      for (int i = 0; i < 100; i++) {
        governor.acquireNonBlocking(1);
      }

      // No refill ran, so the recorded timestamp must be unchanged.
      expect(governor.lastRefillMsForTesting, equals(before));
    });

    test('rapid acquire() calls do not permanently zero out tokens', () async {
      final governor = BandwidthGovernor(100000, 1.0); // 100 KB/s
      governor.registerConsumer();

      // Drain all initial tokens
      governor.acquireNonBlocking(150000);

      // Perform a rapid succession of acquire calls with tiny delays spanning > 100ms
      for (int i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 5));
        governor.acquireNonBlocking(10);
      }

      // After 100ms+, tokens must have refilled despite rapid calls
      final wait = governor.acquireNonBlocking(1000);
      expect(wait, lessThan(1000));
    });

    test('acquireBlocking awaits the computed delay', () async {
      final governor = BandwidthGovernor(1000, 1.0);
      governor.registerConsumer();
      final wait = await governor.acquireBlocking(2000);
      expect(wait, greaterThan(0));
      governor.dispose();
    });

    test('acquire delegates to the locked non-blocking path', () async {
      final governor = BandwidthGovernor(0);
      expect(await governor.acquire(10), 0);
      expect(await governor.acquire(0), 0);
      governor.dispose();
    });

    test('dispose cancels cleanup and blocks new consumers', () {
      final governor = BandwidthGovernor(1000);
      governor.registerConsumer();
      expect(governor.domainCleanupTimerForTesting, isNotNull);

      governor.dispose();
      expect(governor.isDisposed, isTrue);
      expect(governor.domainCleanupTimerForTesting, isNull);

      // Guarded: registering after dispose is a no-op.
      final countAfterDispose = governor.activeConsumers;
      governor.registerConsumer();
      expect(governor.activeConsumers, countAfterDispose);
      governor.dispose();
    });

    test('unregistering the last consumer stops the cleanup timer', () {
      final governor = BandwidthGovernor(1000);
      governor.registerConsumer();
      governor.registerConsumer();
      governor.unregisterConsumer();
      expect(governor.domainCleanupTimerForTesting, isNotNull);
      governor.unregisterConsumer();
      expect(governor.domainCleanupTimerForTesting, isNull);
      governor.dispose();
    });

    test('setLimit and updateLimit aliases update the global limit', () {
      final governor = BandwidthGovernor(0);
      governor.setLimit(5000);
      expect(governor.globalBytesPerSecond, 5000);
      governor.updateLimit(-1);
      expect(governor.globalBytesPerSecond, 0);
      governor.dispose();
    });

    test('onPowerStateChanged refills without error', () {
      final governor = BandwidthGovernor(1000);
      governor.registerConsumer();
      governor.onPowerStateChanged();
      expect(governor.lastRefillMsForTesting, isNonNegative);
      governor.dispose();
    });

    test('unknown task ids fall back to the global share', () async {
      final governor = BandwidthGovernor(0);
      expect(governor.getTaskLimit('missing'), isNull);
      expect(await governor.acquire(10, taskId: 'missing'), 0);
      governor.dispose();
    });

    test('domain cleanup timer runs on its interval', () {
      fakeAsync((async) {
        final governor = BandwidthGovernor(0);
        governor.registerConsumer();
        governor.reportDomainSpeed('idle.example', 10);
        async.elapse(const Duration(minutes: 5));
        expect(governor.getAverageSpeedForDomain('idle.example'), 10);
        governor.dispose();
      });
    });

    test('BandwidthArbiter handles torrent-only and idle branches', () {
      final arbiter = BandwidthArbiter();
      final (httpOnly, torrentOnly) = arbiter.arbitrate(
        httpActiveCount: 0,
        torrentActiveCount: 2,
        totalLimitBps: 1000,
      );
      expect(httpOnly, 0);
      expect(torrentOnly, 1000);

      final (idleHttp, idleTorrent) = arbiter.arbitrate(
        httpActiveCount: 0,
        torrentActiveCount: 0,
        totalLimitBps: 1000,
      );
      expect(idleHttp, 0);
      expect(idleTorrent, 0);

      final (zeroHttp, zeroTorrent) = arbiter.arbitrate(
        httpActiveCount: 1,
        torrentActiveCount: 1,
        totalLimitBps: 0,
      );
      expect(zeroHttp, 0);
      expect(zeroTorrent, 0);
      arbiter.httpGovernor.dispose();
    });

    test('powerThrottleActive reflects the live power state', () {
      PowerMonitor.setBatteryStateForTesting(BatteryState.discharging);
      PowerMonitor.setBatteryLevelForTesting(35);
      final governor = BandwidthGovernor(10000);
      expect(governor.throttleFactor, lessThan(1.0));
      expect(governor.powerThrottleActive, isTrue);
      governor.dispose();
      PowerMonitor.setBatteryLevelForTesting(100);
      PowerMonitor.setBatteryStateForTesting(BatteryState.unknown);
    });

    test('domain speed history rotates past 20 samples', () {
      final governor = BandwidthGovernor(0);
      for (var i = 0; i < 25; i++) {
        governor.reportDomainSpeed('cdn.example', 10);
      }
      expect(governor.getAverageSpeedForDomain('cdn.example'), 10);
      governor.dispose();
    });

    test('refill with no consumers resets tokens without error', () {
      final governor = BandwidthGovernor(1000);
      governor.onPowerStateChanged();
      expect(governor.lastRefillMsForTesting, isNonNegative);
      governor.dispose();
    });

    test('BandwidthArbiter dynamically splits 70/30 when both are active', () {
      final arbiter = BandwidthArbiter();
      final (httpShare, torrentShare) = arbiter.arbitrate(
        httpActiveCount: 2,
        torrentActiveCount: 1,
        totalLimitBps: 1000000,
      );
      expect(httpShare, 700000);
      expect(torrentShare, 300000);
      expect(arbiter.httpGovernor.globalBytesPerSecond, 700000);
      arbiter.httpGovernor.dispose();
    });
  });
}
