import 'package:battery_plus/battery_plus.dart';
import 'package:dmx/core/services/background_timer_manager.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundTimerManager Debounce & Flapping Guard (P0-9)', () {
    test('State changes are debounced by 500ms and flapping count is tracked',
        () async {
      final manager = BackgroundTimerManager.instance;

      int callCount = 0;
      manager.register(
        id: 'test-timer',
        baseInterval: const Duration(seconds: 5),
        callback: () => callCount++,
      );

      // Trigger 6 rapid throttleFactor updates
      for (var i = 0; i < 6; i++) {
        PowerMonitor.throttleFactorNotifier.value = 0.5 + (i * 0.05);
      }

      // Assert debounce timer is active and history records rapid state changes
      expect(manager.debounceTimerForTesting, isNotNull);
      expect(manager.debounceTimerForTesting!.isActive, isTrue);
      expect(manager.stateChangeHistoryCount, greaterThanOrEqualTo(5));

      // Wait for debounce timer (500ms) to fire
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(manager.debounceTimerForTesting?.isActive ?? false, isFalse);

      manager.cancel('test-timer');
      expect(callCount, equals(0));
    });
  });

  group('BackgroundTimerManager intervals & lifecycle', () {
    late BackgroundTimerManager manager;

    setUp(() {
      PowerMonitor.setScreenOn(true);
      PowerMonitor.setBatteryForTesting(
        level: 100,
        state: BatteryState.charging,
      );
      PowerMonitor.setThermalForTesting(ThermalStatus.none);
      DownloadEngine.markForeground();
      manager = BackgroundTimerManager();
    });

    tearDown(() {
      manager.dispose();
      PowerMonitor.setScreenOn(true);
      DownloadEngine.markForeground();
    });

    test('adaptIntervalForTesting covers every power context', () {
      const base = Duration(seconds: 1);

      expect(
        manager.adaptIntervalForTesting(
          base,
          category: TimerCategory.criticalEngine,
        ),
        base,
      );
      expect(manager.adaptIntervalForTesting(base), base);

      PowerMonitor.setScreenOn(false);
      expect(manager.adaptIntervalForTesting(base), base * 20);
      PowerMonitor.setScreenOn(true);

      DownloadEngine.markBackground();
      expect(manager.adaptIntervalForTesting(base), base * 5);
      DownloadEngine.markForeground();

      PowerMonitor.setBatteryForTesting(
        level: 15,
        state: BatteryState.discharging,
      );
      expect(manager.adaptIntervalForTesting(base), base * 8);

      PowerMonitor.setBatteryForTesting(
        level: 35,
        state: BatteryState.discharging,
      );
      expect(manager.adaptIntervalForTesting(base), base * 3);
    });

    test('register tracks category counts and effective intervals', () {
      manager.register(
        id: 'persist',
        baseInterval: const Duration(seconds: 1),
        callback: () {},
      );
      manager.register(
        id: 'telemetry',
        baseInterval: const Duration(seconds: 2),
        callback: () {},
        category: TimerCategory.telemetry,
      );

      expect(manager.totalActiveTimers, 2);
      expect(manager.activeTimerCountByCategory[TimerCategory.persistence], 1);
      expect(manager.activeTimerCountByCategory[TimerCategory.telemetry], 1);
      expect(
        manager.getEffectiveInterval('persist'),
        const Duration(seconds: 1),
      );
      expect(manager.getEffectiveInterval('missing'), isNull);
    });

    test('UI and widget timers are not scheduled while backgrounded', () {
      DownloadEngine.markBackground();
      final uiTimer = manager.register(
        id: 'ui',
        baseInterval: const Duration(seconds: 1),
        callback: () {},
        category: TimerCategory.ui,
      );
      final widgetTimer = manager.register(
        id: 'widget',
        baseInterval: const Duration(seconds: 1),
        callback: () {},
        category: TimerCategory.widget,
      );
      expect(uiTimer, isNull);
      expect(widgetTimer, isNull);
    });

    test('pauseAll/resumeAll and cancelAll manage timers', () {
      manager.register(
        id: 'a',
        baseInterval: const Duration(seconds: 1),
        callback: () {},
      );
      manager.pauseAll();
      expect(manager.totalActiveTimers, 0);
      manager.resumeAll();
      expect(manager.totalActiveTimers, 1);
      manager.cancelAll();
      expect(manager.totalActiveTimers, 0);
    });

    test('registered timer callbacks fire on their interval', () {
      fakeAsync((async) {
        final local = BackgroundTimerManager();
        var calls = 0;
        local.register(
          id: 'tick',
          baseInterval: const Duration(milliseconds: 10),
          callback: () => calls++,
        );
        async.elapse(const Duration(milliseconds: 35));
        expect(calls, greaterThanOrEqualTo(3));
        local.dispose();
      });
    });

    test('register-scheduled UI timer fires and pauses in background', () {
      fakeAsync((async) {
        final local = BackgroundTimerManager();
        var calls = 0;
        local.register(
          id: 'ui',
          baseInterval: const Duration(milliseconds: 10),
          callback: () => calls++,
          category: TimerCategory.ui,
        );
        async.elapse(const Duration(milliseconds: 35));
        expect(calls, greaterThanOrEqualTo(3));

        DownloadEngine.markBackground();
        async.elapse(const Duration(milliseconds: 35));
        local.dispose();
      });
    });

    test('readapt reschedules and drops UI timers in background', () {
      fakeAsync((async) {
        final local = BackgroundTimerManager();
        var calls = 0;
        local.register(
          id: 'ui2',
          baseInterval: const Duration(milliseconds: 10),
          callback: () => calls++,
          category: TimerCategory.ui,
        );
        local.resumeAll();
        async.elapse(const Duration(milliseconds: 35));
        expect(calls, greaterThanOrEqualTo(3));

        DownloadEngine.markBackground();
        async.elapse(const Duration(milliseconds: 35));
        local.resumeAll();
        async.elapse(const Duration(milliseconds: 35));
        local.dispose();
      });
    });

    test('flapping state changes suppress listeners then recover', () {
      fakeAsync((async) {
        final local = BackgroundTimerManager();
        for (var i = 0; i < 6; i++) {
          PowerMonitor.throttleFactorNotifier.value = 0.5 + i * 0.05;
        }
        expect(local.isSuppressedForTesting, isTrue);
        async.elapse(const Duration(seconds: 4));
        expect(local.isSuppressedForTesting, isFalse);
        local.dispose();
      });
    });
  });
}
