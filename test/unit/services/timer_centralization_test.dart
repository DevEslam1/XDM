import 'package:dmx/core/services/background_timer_manager.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BackgroundTimerManager manager;

  setUp(() {
    DownloadEngine.markForeground();
    PowerMonitor.setScreenOn(true);
    manager = BackgroundTimerManager();
  });

  tearDown(() {
    manager.dispose();
  });

  group('Task 4: Timer Centralization & Classification Suite', () {
    test('Classifies timers across distinct categories and tracks counts', () {
      manager.register(
        id: 'engine-timer',
        baseInterval: const Duration(seconds: 1),
        callback: () {},
        category: TimerCategory.criticalEngine,
      );

      manager.register(
        id: 'db-flush-timer',
        baseInterval: const Duration(seconds: 5),
        callback: () {},
        category: TimerCategory.persistence,
      );

      manager.register(
        id: 'ui-progress-timer',
        baseInterval: const Duration(milliseconds: 250),
        callback: () {},
        category: TimerCategory.ui,
      );

      manager.register(
        id: 'telemetry-timer',
        baseInterval: const Duration(seconds: 30),
        callback: () {},
        category: TimerCategory.telemetry,
      );

      final counts = manager.activeTimerCountByCategory;
      expect(counts[TimerCategory.criticalEngine], equals(1));
      expect(counts[TimerCategory.persistence], equals(1));
      expect(counts[TimerCategory.ui], equals(1));
      expect(counts[TimerCategory.telemetry], equals(1));
      expect(manager.totalActiveTimers, equals(4));
    });

    test('CriticalEngine timers maintain unthrottled base interval regardless of power mode', () {
      const base = Duration(milliseconds: 500);

      PowerMonitor.setScreenOn(false);
      final adapted = manager.adaptIntervalForTesting(
        base,
        category: TimerCategory.criticalEngine,
      );

      expect(adapted, equals(base),
          reason: 'Critical engine timers must not be throttled');
    });

    test('Persistence & Telemetry timers throttle when screen is off', () {
      const base = Duration(seconds: 2);

      PowerMonitor.setScreenOn(false);
      final adapted = manager.adaptIntervalForTesting(
        base,
        category: TimerCategory.persistence,
      );

      expect(adapted, equals(const Duration(seconds: 40)),
          reason: 'Persistence timers must scale by 20x when screen is off');
    });

    test('UI and Widget timers are suspended when app is backgrounded or screen is off', () {
      DownloadEngine.markBackground();

      var uiFired = false;
      final timer = manager.register(
        id: 'ui-animation-timer',
        baseInterval: const Duration(milliseconds: 100),
        callback: () {
          uiFired = true;
        },
        category: TimerCategory.ui,
      );

      expect(timer, isNull,
          reason: 'UI timers must not be registered/scheduled when app is in background');
      expect(uiFired, isFalse);
    });
  });
}
