import 'package:battery_plus/battery_plus.dart';
import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PowerMonitor.setBatteryStateForTesting(BatteryState.charging);
    PowerMonitor.setBatteryLevelForTesting(100);
    PowerMonitor.setThermalStatusForTesting(ThermalStatus.none);
  });

  tearDown(() {
    PowerMonitor.setBatteryStateForTesting(BatteryState.charging);
    PowerMonitor.setBatteryLevelForTesting(100);
    PowerMonitor.setThermalStatusForTesting(ThermalStatus.none);
  });

  group('BandwidthGovernor Hardening (Sprint 1)', () {
    test('Token bucket preserves deficit on negative balance without zeroing',
        () {
      final governor = BandwidthGovernor(1000, 1.0);
      governor.registerConsumer();

      // Acquire more than 1 second of bandwidth (1500 bytes on 1000 B/s share)
      final waitMs = governor.acquireNonBlocking(1500);
      expect(waitMs, greaterThan(0));

      // Immediate second acquire should account for existing deficit
      final secondWaitMs = governor.acquireNonBlocking(500);
      expect(secondWaitMs, greaterThan(0));
      governor.dispose();
    });

    test('throttleFactor dynamically reflects PowerMonitor.throttleFactor', () {
      final governor = BandwidthGovernor(10000);
      governor.registerConsumer();

      expect(governor.throttleFactor, equals(1.0));
      expect(governor.powerThrottleActive, isFalse);

      // Set aggressive power throttle (discharging & <20% level)
      PowerMonitor.setBatteryStateForTesting(BatteryState.discharging);
      PowerMonitor.setBatteryLevelForTesting(15);

      expect(governor.throttleFactor, equals(0.5));
      expect(governor.powerThrottleActive, isTrue);
      expect(governor.perConsumerBytesPerSecond, equals(5000));

      governor.dispose();
    });

    test('onPowerStateChanged is notified when PowerMonitor changes', () {
      final governor = BandwidthGovernor(10000);
      governor.registerConsumer();

      // Set critical thermal
      PowerMonitor.setThermalStatusForTesting(ThermalStatus.critical);
      expect(governor.perConsumerBytesPerSecond, equals(3000));

      governor.dispose();
    });
  });
}
