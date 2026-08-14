import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/background_gate.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/power_monitor.dart';

void main() {
  group('Background Download & Power Gate Unit Test (FIX-35)', () {
    setUp(() {
      PowerMonitor.setScreenOn(true);
      PowerMonitor.setBatteryStateForTesting(BatteryState.charging);
      PowerMonitor.setBatteryLevelForTesting(100);
      DownloadEngine.appInForeground = true;
      DownloadEngine.isInBackground = false;
    });

    test('BackgroundGate allows heavy operations in foreground with screen on and charging', () {
      expect(BackgroundGate.allowHeavyOps, isTrue);
      expect(BackgroundGate.allowLightOps, isTrue);
      expect(BackgroundGate.scaleInterval(const Duration(seconds: 1)), equals(const Duration(seconds: 1)));
    });

    test('BackgroundGate scales interval when screen is off', () {
      PowerMonitor.setScreenOn(false);

      expect(BackgroundGate.allowHeavyOps, isFalse);
      expect(BackgroundGate.allowLightOps, isFalse);
      // Screen off scales base interval by 20x
      expect(
        BackgroundGate.scaleInterval(const Duration(seconds: 1)),
        equals(const Duration(seconds: 20)),
      );
    });

    test('BackgroundGate scales interval under aggressive battery saver', () {
      PowerMonitor.setScreenOn(true);
      PowerMonitor.setBatteryStateForTesting(BatteryState.discharging);
      PowerMonitor.setBatteryLevelForTesting(15); // < 20 triggers aggressive battery saver

      expect(PowerMonitor.batterySaverMode, equals(BatterySaverMode.aggressive));
      expect(BackgroundGate.allowHeavyOps, isFalse);
      // Aggressive battery saver scales base interval by 8x
      expect(
        BackgroundGate.scaleInterval(const Duration(seconds: 1)),
        equals(const Duration(seconds: 8)),
      );
    });
  });
}
