import 'package:dmx/core/di/injection.dart';
import 'package:dmx/core/services/app_lifecycle_coordinator.dart';
import 'package:dmx/core/services/background_timer_manager.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/frame_watchdog.dart';
import 'package:dmx/core/services/performance_monitor.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/widget_data_bridge.dart';
import 'package:dmx/shared/animation/ambient_animation_coordinator.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PowerMonitor.setScreenOn(true);
    PowerMonitor.isAppForegrounded = true;
    DownloadEngine.markForeground();
    DownloadEngine.setActiveDownloadsCount(0);
    AppLifecycleCoordinator.init();
  });

  tearDown(() {
    AppLifecycleCoordinator.dispose();
    WidgetDataBridge.instance.resumeWidgetUpdates();
    PerformanceMonitor.instance.stop();
    FrameWatchdog.stop();
    PowerMonitor.setScreenOn(true);
    DownloadEngine.markForeground();
    DownloadEngine.setActiveDownloadsCount(0);
  });

  tearDown(() {
    if (getIt.isRegistered<BackgroundTimerManager>()) {
      getIt.unregister<BackgroundTimerManager>();
    }
    if (getIt.isRegistered<AmbientAnimationController>()) {
      getIt.unregister<AmbientAnimationController>();
    }
  });

  group('AppLifecycleCoordinator', () {
    test('inactive schedules ambient suspension after the delay', () async {
      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(AppLifecycleCoordinator.inactiveTimerForTesting, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(AppLifecycleCoordinator.isAppForegrounded, isFalse);
    });

    test('repeated inactive states cancel the previous delay timer', () {
      final coordinator = AppLifecycleCoordinator.instance;
      coordinator.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(AppLifecycleCoordinator.inactiveTimerForTesting, isNotNull);

      coordinator.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(AppLifecycleCoordinator.inactiveTimerForTesting, isNotNull);

      coordinator.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(AppLifecycleCoordinator.inactiveTimerForTesting, isNull);
    });

    test('resuming cancels the inactive timer', () {
      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(AppLifecycleCoordinator.inactiveTimerForTesting, isNotNull);

      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(AppLifecycleCoordinator.inactiveTimerForTesting, isNull);
      expect(AppLifecycleCoordinator.isAppForegrounded, isTrue);
    });

    test('hidden and detached suspend ambient work', () {
      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(AppLifecycleCoordinator.isAppForegrounded, isFalse);

      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.detached);
      expect(AppLifecycleCoordinator.isAppForegrounded, isFalse);
    });

    test('registered onResumed callbacks fire once and can be removed', () {
      var calls = 0;
      void callback() => calls++;

      AppLifecycleCoordinator.addOnResumedCallback(callback);
      AppLifecycleCoordinator.addOnResumedCallback(callback); // deduped
      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(calls, 1);

      AppLifecycleCoordinator.removeOnResumedCallback(callback);
      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(calls, 1);
    });

    test('throwing onResumed callbacks are isolated', () {
      AppLifecycleCoordinator.addOnResumedCallback(
        () => throw StateError('boom'),
      );
      expect(
        () => AppLifecycleCoordinator.instance
            .didChangeAppLifecycleState(AppLifecycleState.resumed),
        returnsNormally,
      );
    });

    test('resuming restarts timers and ambient animations when registered', () {
      final manager = BackgroundTimerManager();
      getIt.registerSingleton<BackgroundTimerManager>(manager);
      getIt.registerSingleton<AmbientAnimationController>(
        const NoOpAmbientAnimationController(),
      );
      addTearDown(manager.dispose);

      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(AppLifecycleCoordinator.isAppForegrounded, isTrue);
    });

    test('resuming with the screen off skips restarting workers', () {
      PowerMonitor.setScreenOn(false);
      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(AppLifecycleCoordinator.isAppForegrounded, isTrue);
    });

    test('suspending pauses registered timers and animations', () {
      final manager = BackgroundTimerManager();
      getIt.registerSingleton<BackgroundTimerManager>(manager);
      getIt.registerSingleton<AmbientAnimationController>(
        const NoOpAmbientAnimationController(),
      );
      addTearDown(() {
        if (getIt.isRegistered<BackgroundTimerManager>()) {
          getIt.unregister<BackgroundTimerManager>();
        }
        if (getIt.isRegistered<AmbientAnimationController>()) {
          getIt.unregister<AmbientAnimationController>();
        }
        manager.dispose();
      });

      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(WidgetDataBridge.instance.isPaused, isTrue);
    });
  });
}
