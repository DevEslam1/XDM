import 'dart:async';
import 'package:flutter/widgets.dart';
import 'download_engine.dart';
import 'frame_watchdog.dart';
import 'performance_monitor.dart';
import 'power_monitor.dart';
import 'widget_data_bridge.dart';
import '../../shared/widgets/geometric_grid_background.dart';
import '../../features/downloads/widgets/download_card.dart';

/// Central coordinator for application lifecycle events (BG-01/BG-02/BG-03/BG-08).
/// Ensures that when the application is backgrounded or inactive, all ambient timers,
/// frame timing callbacks, performance diagnostics, and GPU animations are suspended.
class AppLifecycleCoordinator with WidgetsBindingObserver {
  static final AppLifecycleCoordinator instance = AppLifecycleCoordinator._();
  factory AppLifecycleCoordinator() => instance;
  AppLifecycleCoordinator._();

  static bool isAppForegrounded = true;
  static Timer? _inactiveTimer;
  static final List<VoidCallback> _onResumedCallbacks = [];

  static void addOnResumedCallback(VoidCallback cb) {
    if (!_onResumedCallbacks.contains(cb)) {
      _onResumedCallbacks.add(cb);
    }
  }

  static void removeOnResumedCallback(VoidCallback cb) {
    _onResumedCallbacks.remove(cb);
  }

  @visibleForTesting
  static Timer? get inactiveTimerForTesting => _inactiveTimer;

  /// Register this observer once in `main.dart` after [WidgetsFlutterBinding.ensureInitialized].
  static void init() {
    WidgetsBinding.instance.addObserver(instance);
  }

  /// Manually dispose / remove the observer (useful for testing).
  static void dispose() {
    _inactiveTimer?.cancel();
    _inactiveTimer = null;
    _onResumedCallbacks.clear();
    WidgetsBinding.instance.removeObserver(instance);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _inactiveTimer?.cancel();
      _inactiveTimer = null;
      isAppForegrounded = true;
      PowerMonitor.isAppForegrounded = true;
      PowerMonitor.setScreenOn(true);
      DownloadEngine.appInForeground = true;
      DownloadEngine.isInBackground = false;

      // Resume widget updates (NEW-02)
      WidgetDataBridge.instance.resumeWidgetUpdates();

      // Trigger all registered onResumed callbacks immediately (e.g. force progress emission)
      for (final cb in List.of(_onResumedCallbacks)) {
        try {
          cb();
        } catch (e) {
          debugPrint('[AppLifecycleCoordinator] onResumedCallback error: $e');
        }
      }

      // Restart ONLY if screen is on
      if (!PowerMonitor.screenOff) {
        FrameWatchdog.start();
        PerformanceMonitor.instance.start();
        AmbientProgress.instance.restartIfMounted();
        StatusChipPulseDriver.instance.restartIfActive();
      }
    } else if (state == AppLifecycleState.inactive) {
      // 500ms delay timer before ambient suspension (NEW-04)
      _inactiveTimer?.cancel();
      _inactiveTimer = Timer(const Duration(milliseconds: 500), () {
        _suspendAmbientWork();
      });
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _inactiveTimer?.cancel();
      _inactiveTimer = null;
      _suspendAmbientWork();
    }
  }

  void _suspendAmbientWork() {
    isAppForegrounded = false;
    PowerMonitor.isAppForegrounded = false;
    PowerMonitor.setScreenOn(false);
    DownloadEngine.appInForeground = false;
    DownloadEngine.isInBackground = true;

    // Pause widget updates (NEW-02)
    WidgetDataBridge.instance.pauseWidgetUpdates();

    // Suspend all ambient work
    FrameWatchdog.stop();
    PerformanceMonitor.instance.stop();
    AmbientProgress.instance.stopAll();
    StatusChipPulseDriver.instance.stop();
    StatusChipPulseDriver.stopAll();
  }
}
