import 'package:battery_plus/battery_plus.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PowerMonitor Tests', () {
    tearDown(() {
      PowerMonitor.setBatteryStateForTesting(BatteryState.unknown);
      PowerMonitor.setBatteryLevelForTesting(100);
      PowerMonitor.setThermalStatusForTesting(ThermalStatus.none);
      PowerMonitor.setScreenOn(true);
    });

    test('throttleFactor default returns valid range [0.3, 1.0]', () {
      final factor = PowerMonitor.throttleFactor;
      expect(factor, greaterThanOrEqualTo(0.3));
      expect(factor, lessThanOrEqualTo(1.0));
    });

    test('screenOff respects setScreenOn toggle', () {
      PowerMonitor.setScreenOn(false);
      expect(PowerMonitor.screenOff, isTrue);

      PowerMonitor.setScreenOn(true);
      expect(PowerMonitor.screenOff, isFalse);
    });

    test('Battery at 15% -> BatterySaverMode.aggressive', () {
      PowerMonitor.setBatteryStateForTesting(BatteryState.discharging);
      PowerMonitor.setBatteryLevelForTesting(15);
      expect(PowerMonitor.batterySaverMode, BatterySaverMode.aggressive);
    });

    test('Battery at 35% -> BatterySaverMode.moderate', () {
      PowerMonitor.setBatteryStateForTesting(BatteryState.discharging);
      PowerMonitor.setBatteryLevelForTesting(35);
      expect(PowerMonitor.batterySaverMode, BatterySaverMode.moderate);
    });

    test('Battery at 80% -> BatterySaverMode.off', () {
      PowerMonitor.setBatteryStateForTesting(BatteryState.discharging);
      PowerMonitor.setBatteryLevelForTesting(80);
      expect(PowerMonitor.batterySaverMode, BatterySaverMode.off);
    });

    test('Thermal SEVERE -> maxAllowedThreads = 2', () {
      PowerMonitor.setThermalStatusForTesting(ThermalStatus.severe);
      expect(PowerMonitor.maxAllowedThreads, 2);
    });

    test('Battery 80% + Thermal CRITICAL -> maxAllowedThreads = 2', () {
      PowerMonitor.setBatteryStateForTesting(BatteryState.discharging);
      PowerMonitor.setBatteryLevelForTesting(80);
      PowerMonitor.setThermalStatusForTesting(ThermalStatus.critical);
      expect(PowerMonitor.maxAllowedThreads, 2);
    });
  });
}
