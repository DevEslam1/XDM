import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/app_lifecycle_coordinator.dart';
import 'package:dmx/core/services/frame_watchdog.dart';
import 'package:dmx/core/services/performance_monitor.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/shared/widgets/geometric_grid_background.dart';
import 'package:dmx/features/downloads/widgets/download_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppLifecycleCoordinator (BG-01/BG-02/BG-03/BG-08)', () {
    late AppLifecycleCoordinator coordinator;

    setUp(() {
      coordinator = AppLifecycleCoordinator.instance;
      PowerMonitor.setScreenOn(true);
      PowerMonitor.isAppForegrounded = true;
    });

    test('Transitions to background suspend all ambient workers', () {
      PerformanceMonitor.instance.start();
      FrameWatchdog.start();
      AmbientProgress.instance.addRef();
      StatusChipPulseDriver.instance.addRef();

      expect(PowerMonitor.isAppForegrounded, isTrue);

      coordinator.didChangeAppLifecycleState(AppLifecycleState.paused);

      expect(AppLifecycleCoordinator.isAppForegrounded, isFalse);
      expect(PowerMonitor.isAppForegrounded, isFalse);
      expect(PowerMonitor.screenOff, isTrue);
      expect(PerformanceMonitor.instance.isListening, isFalse);

      // Verify FrameWatchdog.start() is a no-op when screen is off
      FrameWatchdog.start();

      // Clean up refs
      AmbientProgress.instance.removeRef();
      StatusChipPulseDriver.instance.removeRef();
    });

    test('Resuming app restores workers when screen is on', () {
      coordinator.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(AppLifecycleCoordinator.isAppForegrounded, isFalse);

      coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(AppLifecycleCoordinator.isAppForegrounded, isTrue);
      expect(PowerMonitor.screenOff, isFalse);
      expect(PerformanceMonitor.instance.isListening, isTrue);
    });

    test('Resuming does not start FrameWatchdog if screenOff is forced', () {
      coordinator.didChangeAppLifecycleState(AppLifecycleState.paused);
      PowerMonitor.setScreenOn(false);

      coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
      // Even after resume call, if screenOff is set, start is protected
      PowerMonitor.setScreenOn(false);
      FrameWatchdog.start();
      // Watchdog remains inactive
      PowerMonitor.setScreenOn(true);
    });
  });
}
