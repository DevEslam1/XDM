import 'package:flutter_test/flutter_test.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Background Download Performance Integration Tests', () {
    test('PowerMonitor broadcasts screen state changes cleanly', () async {
      bool lastEvent = true;
      final sub = PowerMonitor.screenStateStream.listen((state) {
        lastEvent = state;
      });

      PowerMonitor.setScreenOn(false);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(PowerMonitor.screenOff, isTrue);
      expect(lastEvent, isFalse);

      PowerMonitor.setScreenOn(true);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(PowerMonitor.screenOff, isFalse);
      expect(lastEvent, isTrue);

      await sub.cancel();
    });

    test(
        'DownloadIsolatePool scales effective max size when battery low or screen off',
        () {
      PowerMonitor.setBatteryStateForTesting(BatteryState.discharging);
      PowerMonitor.setBatteryLevelForTesting(15);
      expect(PowerMonitor.batteryLevel, equals(15));
      expect(PowerMonitor.isCharging, isFalse);

      final pool = DownloadIsolatePool(size: 4, powerAware: true);
      expect(pool.effectiveMaxSize, lessThanOrEqualTo(2));
    });

    test('DatabaseService flushPendingSaves completes without throwing',
        () async {
      await DatabaseService.instance.flushPendingSaves();
    });
  });
}
