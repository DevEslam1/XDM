import 'dart:async';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/widgets.dart';

import '../../shared/animation/ambient_animation_coordinator.dart';
import '../di/injection.dart';
import 'background_timer_manager.dart';
import 'database_service.dart';
import 'download_engine.dart';
import 'download_journal.dart';
import 'frame_watchdog.dart';
import 'performance_monitor.dart';
import 'power_monitor.dart';
import 'torrent_service.dart';
import 'widget_data_bridge.dart';

/// Central coordinator for application lifecycle events (BG-01/BG-02/BG-03/BG-08).
/// Ensures that when the application is backgrounded or inactive, all ambient timers,
/// frame timing callbacks, performance diagnostics, and GPU animations are suspended.
class AppLifecycleCoordinator with WidgetsBindingObserver {
  AppLifecycleCoordinator();

  static final AppLifecycleCoordinator instance = AppLifecycleCoordinator();

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

  /// Register this observer once after [WidgetsFlutterBinding.ensureInitialized].
  static void init() {
    WidgetsBinding.instance.addObserver(instance);
  }

  /// Remove the observer and clean up.
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
      unawaited(PowerMonitor.updateScreenStateFromPlatform());
      DownloadEngine.markForeground();
      // Task 2.3: use explicit markForeground() instead of inverted isInBackground setter

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
        if (getIt.isRegistered<BackgroundTimerManager>()) {
          getIt<BackgroundTimerManager>().resumeAll();
        }
        FrameWatchdog.start();
        PerformanceMonitor.instance.start();
        if (getIt.isRegistered<AmbientAnimationController>()) {
          final anim = getIt<AmbientAnimationController>();
          anim.restartIfMounted();
          anim.restartIfActive();
        }
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
      unawaited(_suspendAmbientWork());
    }
  }

  Future<void> _suspendAmbientWork() async {
    isAppForegrounded = false;
    PowerMonitor.isAppForegrounded = false;
    unawaited(PowerMonitor.updateScreenStateFromPlatform());
    DownloadEngine.markBackground();
    // Task 2.3: use explicit markBackground() instead of inverted isInBackground setter

    // Pause widget updates (NEW-02)
    WidgetDataBridge.instance.pauseWidgetUpdates();

    // STOP ALL TIMERS
    if (getIt.isRegistered<BackgroundTimerManager>()) {
      getIt<BackgroundTimerManager>().pauseAll();
    }

    // Suspend all ambient work
    FrameWatchdog.stop();
    PerformanceMonitor.instance.stop();
    if (getIt.isRegistered<AmbientAnimationController>()) {
      getIt<AmbientAnimationController>().stopAll();
    }

    // Task 4.3: Flush database saves and checkpoint WAL on backgrounding/detaching
    try {
      DownloadJournal.flushAllActive();
      DatabaseService.instance.flushPendingSaves();
      DatabaseService.instance.checkpointWal(truncate: true);
    } catch (e, st) {
      LoggingService.logger('AppLifecycleCoordinator')
          .warning('Database / Journal flush on background failed', e, st);
    }

    // Torrent & Worker Isolate Hard Deadline on Pause
    try {
      try {
        await TorrentService.saveAllResumeData()
            .timeout(const Duration(milliseconds: 1000));
      } catch (_) {
        // F29: previously this hard-killed EVERY worker isolate — including
        // actively-transferring HTTP downloads — the moment the torrent
        // resume-save deadline elapsed. On this build torrent resume is
        // unsupported, so `saveAllResumeData` always times out, which meant
        // every backgrounding killed in-flight downloads mid-write and lost
        // their progress. Never kill isolates while any download is active;
        // HTTP workers persist their own state as they go.
        if (DownloadEngine.hasActiveDownloads) {
          LoggingService.logger('AppLifecycleCoordinator').info(
            'Skipping force-kill of download isolates on background: '
            '${DownloadEngine.activeDownloadsCount} download(s) still active',
          );
          return;
        }
        DownloadEngine.forceKillAllIsolates();
      }
    } catch (_) {}
  }
}
