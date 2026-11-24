import 'package:battery_plus/battery_plus.dart';
import 'package:dmx/core/services/background_gate.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void resetPower() {
    PowerMonitor.setBatteryStateForTesting(BatteryState.charging);
    PowerMonitor.setBatteryLevelForTesting(100);
    PowerMonitor.setThermalStatusForTesting(ThermalStatus.none);
    PowerMonitor.setScreenOn(true);
    DownloadEngine.markForeground();
    DownloadEngine.setActiveDownloadsCount(0);
  }

  setUp(resetPower);
  tearDown(resetPower);

  group('BackgroundGate', () {
    test('shouldAnimate falls back to allowHeavyOps without an override', () {
      expect(BackgroundGate.shouldAnimate, BackgroundGate.allowHeavyOps);
    });

    test('shouldAnimate manual override wins', () {
      BackgroundGate.shouldAnimate = false;
      expect(BackgroundGate.shouldAnimate, isFalse);
      BackgroundGate.shouldAnimate = true;
      expect(BackgroundGate.shouldAnimate, isTrue);
    });

    test('allowHeavyOps true in foreground, screen on, no battery saver', () {
      expect(BackgroundGate.allowHeavyOps, isTrue);
    });

    test('allowHeavyOps false when screen off', () {
      PowerMonitor.setScreenOn(false);
      expect(BackgroundGate.allowHeavyOps, isFalse);
    });

    test('allowHeavyOps false when backgrounded', () {
      DownloadEngine.markBackground();
      expect(BackgroundGate.allowHeavyOps, isFalse);
    });

    test('allowHeavyOps false under battery saver', () {
      PowerMonitor.setBatteryStateForTesting(BatteryState.discharging);
      PowerMonitor.setBatteryLevelForTesting(15);
      expect(BackgroundGate.allowHeavyOps, isFalse);
    });

    test('allowAnyWork follows screen off OR active downloads', () {
      expect(BackgroundGate.allowAnyWork, isTrue);
      PowerMonitor.setScreenOn(false);
      expect(BackgroundGate.allowAnyWork, isFalse);
      DownloadEngine.setActiveDownloadsCount(1);
      expect(BackgroundGate.allowAnyWork, isTrue);
    });

    test('allowLightOps requires foreground or active downloads', () {
      expect(BackgroundGate.allowLightOps, isTrue);
      DownloadEngine.markBackground();
      expect(BackgroundGate.allowLightOps, isFalse);
      DownloadEngine.setActiveDownloadsCount(1);
      expect(BackgroundGate.allowLightOps, isTrue);
      DownloadEngine.setActiveDownloadsCount(0);
      PowerMonitor.setScreenOn(false);
      expect(BackgroundGate.allowLightOps, isFalse);
    });

    test('scaleInterval scales by power context', () {
      const base = Duration(seconds: 1);
      expect(BackgroundGate.scaleInterval(base), base);

      DownloadEngine.markBackground();
      expect(BackgroundGate.scaleInterval(base), const Duration(seconds: 10));

      DownloadEngine.markForeground();
      PowerMonitor.setBatteryStateForTesting(BatteryState.discharging);
      PowerMonitor.setBatteryLevelForTesting(15);
      expect(
        BackgroundGate.scaleInterval(base),
        const Duration(seconds: 15),
      );

      PowerMonitor.setBatteryLevelForTesting(35);
      expect(BackgroundGate.scaleInterval(base), const Duration(seconds: 5));

      PowerMonitor.setBatteryStateForTesting(BatteryState.charging);
      PowerMonitor.setScreenOn(false);
      expect(BackgroundGate.scaleInterval(base), const Duration(seconds: 30));
    });

    test(
        'adaptInterval aliases scaleInterval and shouldWriteState aliases '
        'allowLightOps', () {
      expect(
        BackgroundGate.adaptInterval(const Duration(seconds: 2)),
        BackgroundGate.scaleInterval(const Duration(seconds: 2)),
      );
      expect(BackgroundGate.shouldWriteState, BackgroundGate.allowLightOps);
    });
  });
}
