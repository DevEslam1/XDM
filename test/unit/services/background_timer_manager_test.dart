import 'package:battery_plus/battery_plus.dart';
import 'package:dmx/core/services/background_timer_manager.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundTimerManager Adaptive Interval Tests', () {
    setUp(() {
      DownloadEngine.appInForeground = true;
      PowerMonitor.setScreenOn(true);
      PowerMonitor.setBatteryForTesting(
        level: 100,
        state: BatteryState.charging,
      );
      PowerMonitor.setThermalForTesting(ThermalStatus.none);
      BackgroundTimerManager.instance.cancelAll();
    });

    tearDown(() {
      BackgroundTimerManager.instance.cancelAll();
      DownloadEngine.appInForeground = true;
      PowerMonitor.setScreenOn(true);
    });

    test('re-adapts interval dynamically when screen turns off', () {
      int count = 0;
      BackgroundTimerManager.instance.register(
        id: 'test_timer',
        baseInterval: const Duration(seconds: 1),
        callback: () => count++,
      );

      expect(
        BackgroundTimerManager.instance.getEffectiveInterval('test_timer'),
        equals(const Duration(seconds: 1)),
      );

      // Turn screen off
      PowerMonitor.setScreenOn(false);

      final newInterval =
          BackgroundTimerManager.instance.getEffectiveInterval('test_timer');
      expect(newInterval, isNotNull);
      expect(newInterval!.inSeconds, greaterThanOrEqualTo(18));
      expect(newInterval, equals(const Duration(seconds: 20)));
    });

    test('re-adapts interval dynamically when app enters background', () {
      BackgroundTimerManager.instance.register(
        id: 'bg_timer',
        baseInterval: const Duration(seconds: 2),
        callback: () {},
      );

      expect(
        BackgroundTimerManager.instance.getEffectiveInterval('bg_timer'),
        equals(const Duration(seconds: 2)),
      );

      DownloadEngine.appInForeground = false;

      final newInterval =
          BackgroundTimerManager.instance.getEffectiveInterval('bg_timer');
      expect(newInterval, equals(const Duration(seconds: 10))); // 2s * 5
    });

    test('cancel and cancelAll cleans up registered timers', () {
      BackgroundTimerManager.instance.register(
        id: 't1',
        baseInterval: const Duration(seconds: 1),
        callback: () {},
      );
      expect(BackgroundTimerManager.instance.getEffectiveInterval('t1'),
          isNotNull);

      BackgroundTimerManager.instance.cancel('t1');
      expect(
          BackgroundTimerManager.instance.getEffectiveInterval('t1'), isNull);
    });
  });
}
