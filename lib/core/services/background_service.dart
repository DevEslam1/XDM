// FIX: P0-03 & P0-04 — Guard BackgroundService.stop() and WakeLock auto-release against active downloads
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostic_service.dart';
import 'ios_background_service.dart';
import 'logging_service.dart';
import 'notification_service.dart';
import 'power_monitor.dart';

final _log = LoggingService.logger('BackgroundService');

/// ═══════════════════════════════════════════════════════════════════════════
/// iOS Background Download Limitation
/// ═══════════════════════════════════════════════════════════════════════════
/// iOS does NOT support persistent background downloads from a Dart isolate.
/// The `flutter_background_service` plugin cannot keep Dart code alive after
/// the app is suspended (iOS lifecycle rules). To support background
/// downloads on iOS, a native BGTaskScheduler implementation is needed.
/// ═══════════════════════════════════════════════════════════════════════════

@pragma('vm:entry-point')
class BackgroundService {
  static const int foregroundNotificationId = 888;
  static const String _serviceChannelId = 'dmx_background_service';
  static const MethodChannel _wakeLockChannel = MethodChannel(
    'com.dmx.app/wakelock',
  );
  static bool _wakeLockHeld = false;
  static Timer? _wakeLockRenewalTimer;
  static Timer? _wakeLockSafetyTimer;
  static Timer? _heartbeatTimer;
  static const Duration _maxWakeLockHold = Duration(hours: 2);
  static DateTime? _lastHeartbeatTime;
  static bool _hasActiveDownloads = false;
  static int Function()? _activeDownloadCountQuery;

  /// Consecutive wake-lock renewal failures (escalate after 3).
  static int _wakeLockRenewalFailures = 0;
  static bool _wakeLockEscalated = false;

  /// Injected query callback to determine active download count from DownloadProvider
  static void setActiveDownloadCountQuery(int Function()? query) {
    _activeDownloadCountQuery = query;
  }

  static Future<int> _checkActiveDownloadCount() async {
    if (_activeDownloadCountQuery != null) {
      return _activeDownloadCountQuery!();
    }
    return _hasActiveDownloads ? 1 : 0;
  }

  /// Callback invoked when background execution is requested on iOS where it is unsupported.
  static VoidCallback? onIosBackgroundUnavailable;

  static Future<void> setDownloadActive(bool active) async {
    _hasActiveDownloads = active;
    if (!active) {
      final activeCount = await _checkActiveDownloadCount();
      if (activeCount <= 0) {
        _heartbeatTimer?.cancel();
        _heartbeatTimer = null;
        await releaseWakeLock();
      }
    } else {
      if (!kIsWeb && Platform.isAndroid) {
        final isRunning = _testMode || await FlutterBackgroundService().isRunning();
        if (isRunning) {
          _heartbeatTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
            sendHeartbeat();
          });
        }
      }
      await acquireWakeLock();
    }
  }

  static bool _testMode = false;

  @visibleForTesting
  static set testMode(bool val) => _testMode = val;

  /// Returns true on Android and iOS (non-web) or in test mode. On Android, uses
  /// flutter_background_service; on iOS, uses native BGTaskScheduler & URLSession.
  static bool get isSupported =>
      _testMode || (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  static Future<void> initialize() async {
    if (!isSupported) return;
    if (Platform.isIOS) {
      return; // Native BGTaskScheduler registered in AppDelegate
    }
    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        notificationChannelId: _serviceChannelId,
        initialNotificationTitle: 'XDM',
        initialNotificationContent: 'Downloads active',
        foregroundServiceNotificationId: foregroundNotificationId,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
        onBackground: _onIosBackground,
      ),
    );
  }

  static StreamSubscription<Map<String, dynamic>?>? onStartStopSub;
  static StreamSubscription<Map<String, dynamic>?>? onStartUpdateSub;
  static StreamSubscription<Map<String, dynamic>?>? onStartHeartbeatSub;

  @visibleForTesting
  static StreamSubscription<Map<String, dynamic>?>? get onStartStopSubForTesting =>
      onStartStopSub;

  @visibleForTesting
  static StreamSubscription<Map<String, dynamic>?>? get onStartUpdateSubForTesting =>
      onStartUpdateSub;

  @visibleForTesting
  static StreamSubscription<Map<String, dynamic>?>? get onStartHeartbeatSubForTesting =>
      onStartHeartbeatSub;

  @pragma('vm:entry-point')
  static void _onStart(ServiceInstance service) {
    bool isStopped = false;

    void cancelAll() {
      isStopped = true;
      onStartStopSub?.cancel();
      onStartUpdateSub?.cancel();
      onStartHeartbeatSub?.cancel();
      onStartStopSub = null;
      onStartUpdateSub = null;
      onStartHeartbeatSub = null;
    }

    onStartStopSub = service.on('stopService').listen(
          (_) {
            try {
              cancelAll();
              service.stopSelf();
            } catch (e) {
              _log.warning('stopService error', e);
            }
          },
          cancelOnError: false,
          onError: (e) {
            _log.warning('stopService stream error', e);
          },
        );

    onStartUpdateSub = service.on('updateNotification').listen(
          (event) {
            try {
              if (isStopped) return;
              if (service is AndroidServiceInstance &&
                  event is Map<String, dynamic>) {
                service.setForegroundNotificationInfo(
                  title: event['title'] as String? ?? 'XDM',
                  content: event['content'] as String? ?? '',
                );
              }
            } catch (e) {
              _log.warning('updateNotification error', e);
            }
          },
          cancelOnError: false,
          onError: (e) {
            _log.warning('updateNotification stream error', e);
          },
        );

    onStartHeartbeatSub = service.on('heartbeat').listen(
          (_) {
            _log.finest('Heartbeat received');
          },
          cancelOnError: false,
          onError: (e) {
            _log.warning('heartbeat stream error', e);
          },
        );
  }

  static bool _iosBgCallInFlight = false;
  static Timer? _iosBgWatchdogTimer;

  @visibleForTesting
  static bool get iosBgCallInFlightForTesting => _iosBgCallInFlight;

  @visibleForTesting
  static set iosBgCallInFlightForTesting(bool val) => _iosBgCallInFlight = val;

  @visibleForTesting
  static Timer? get iosBgWatchdogTimerForTesting => _iosBgWatchdogTimer;

  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    _log.info(
      'iOS background callback invoked. Bridging to native BackgroundDownloadController.',
    );
    if (_iosBgCallInFlight) {
      _log.warning('iOS background callback already in flight, ignoring duplicate call');
      return false;
    }
    _iosBgCallInFlight = true;
    _iosBgWatchdogTimer?.cancel();
    _iosBgWatchdogTimer = Timer(const Duration(seconds: 60), () {
      if (_iosBgCallInFlight) {
        _log.warning('[iOS BG Watchdog] iOS background call wedged for 60s; force-resetting in-flight flag.');
        _iosBgCallInFlight = false;
      }
    });

    try {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(
          'lastScheduleAttemptAt',
          DateTime.now().millisecondsSinceEpoch,
        );
      } catch (e, st) {
        _log.fine('Failed to persist lastScheduleAttemptAt', e, st);
      }

      const channel = MethodChannel('com.dmx.app/background_download');
      try {
        final result = await channel
            .invokeMethod<bool>('scheduleDownload')
            .timeout(const Duration(seconds: 5));
        final success = result ?? false;
        _log.info('iOS background schedule completed. Success: $success');
        return success;
      } catch (e, st) {
        _log.fine('Failed to bridge to iOS background download controller', e, st);
        return false;
      }
    } finally {
      _iosBgWatchdogTimer?.cancel();
      _iosBgWatchdogTimer = null;
      _iosBgCallInFlight = false;
    }
  }

  @visibleForTesting
  static Future<bool> onIosBackgroundForTesting(ServiceInstance service) =>
      _onIosBackground(service);

  static Future<void> start() async {
    if (!isSupported) {
      final platformName = kIsWeb ? 'web' : Platform.operatingSystem;
      _log.fine(
        'BackgroundService.start() skipped '
        '(unsupported platform: $platformName)',
      );
      return;
    }

    if (!kIsWeb && Platform.isIOS) {
      _log.info('Scheduling native iOS BGTaskScheduler background task');
      await IosBackgroundService.scheduleBackgroundDownload();
      return;
    }

    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }
  }

  static Future<void> stop() async {
    if (!isSupported) {
      _log.fine('BackgroundService.stop() skipped (unsupported platform)');
      return;
    }

    // FIX: P0-04 — never stop while downloads are running
    final activeCount = await _checkActiveDownloadCount();
    if (activeCount > 0) {
      _log.info('Not stopping: downloads still active ($activeCount running)');
      return;
    }

    if (!kIsWeb && Platform.isIOS) {
      _log.info('Cancelling native iOS BGTaskScheduler background task');
      await IosBackgroundService.cancelBackgroundDownload();
      return;
    }

    final service = FlutterBackgroundService();
    service.invoke('stopService');
  }

  static Future<void> updateNotification({
    required String title,
    required String content,
  }) async {
    if (!isSupported) return;
    final service = FlutterBackgroundService();
    service.invoke('updateNotification', {'title': title, 'content': content});
  }

  static Future<void> sendHeartbeat() async {
    if (!isSupported) return;
    final activeCount = await _checkActiveDownloadCount();
    if (activeCount <= 0) return;
    final now = DateTime.now();
    if (_lastHeartbeatTime != null &&
        now.difference(_lastHeartbeatTime!) < const Duration(seconds: 60)) {
      return;
    }
    _lastHeartbeatTime = now;
    final service = FlutterBackgroundService();
    service.invoke('heartbeat');
  }

  /// Acquires a partial wake lock to keep the CPU awake during active
  /// downloads. Safe to call multiple times; only the first call invokes
  /// the platform channel. The lock is automatically renewed every 15 minutes
  /// to prevent the native 30-minute timeout from expiring.
  static Future<void> acquireWakeLock() async {
    if (!isSupported || _wakeLockHeld) return;
    // Battery gate: if battery is <20% and not charging, do not hold wake lock to avoid rapid battery drain
    try {
      if (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive) {
        _log.fine('Wake lock skipped due to aggressive battery saver mode');
        return;
      }
    } catch (e, st) {
      LoggingService.logger('BackgroundService').warning('Operation failed', e, st);
    }

    try {
      await _wakeLockChannel.invokeMethod<void>('acquire');
      _wakeLockHeld = true;
      _wakeLockRenewalFailures = 0;
      _wakeLockEscalated = false;
      _log.fine('Wake lock acquired');

      // Safety net: auto-release or renew if downloads still active
      _scheduleWakeLockSafetyCheck();

      // Start periodic renewal every 30 minutes to prevent native timeout expiry.
      _wakeLockRenewalTimer?.cancel();
      _wakeLockRenewalTimer = Timer.periodic(const Duration(minutes: 30), (
        _,
      ) async {
        if (!isSupported) return;
        final activeCount = await _checkActiveDownloadCount();
        if (activeCount == 0) {
          _log.fine('Releasing wake lock during renewal: no active downloads');
          await releaseWakeLock();
          return;
        }
        if (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive) {
          _log.fine('Releasing wake lock during renewal due to low battery');
          await releaseWakeLock();
          return;
        }
        try {
          await _wakeLockChannel.invokeMethod<void>('acquire');
          _wakeLockHeld = true;
          _wakeLockRenewalFailures = 0;
          _wakeLockEscalated = false;
          _log.fine('Wake lock renewed');
          DiagnosticService.instance.record('WakeLock', 'renewed successfully');
        } catch (e) {
          _log.warning('Failed to renew wake lock', e);
          _wakeLockHeld = false;
          _wakeLockRenewalFailures++;
          DiagnosticService.instance.record(
            'WakeLock',
            'renewal failed',
            error: e,
            details: 'Consecutive failures: $_wakeLockRenewalFailures',
          );
          if (_wakeLockRenewalFailures >= 3 && !_wakeLockEscalated) {
            _wakeLockEscalated = true;
            unawaited(_escalateWakeLockFailure());
          }
        }
      });
    } catch (e) {
      _log.warning('Failed to acquire wake lock', e);
      DiagnosticService.instance.record(
        'WakeLock',
        'acquire failed',
        error: e,
      );
    }
  }

  /// Escalates a repeated wake-lock renewal failure to the user: a service
  /// notification plus a battery-optimization exemption prompt (Android).
  static Future<void> _escalateWakeLockFailure() async {
    _log.warning(
      '[BackgroundService] Wake lock renewal failed 3× consecutively — escalating',
    );
    try {
      await NotificationService().showServiceNotification(
        title: 'XDM',
        content:
            'Background downloads may pause: the system blocked wake-lock '
            'renewal. Disable battery optimization for XDM to keep downloads '
            'running.',
      );
    } catch (e) {
      _log.warning('Failed to show wake-lock escalation notification', e);
    }
    try {
      await PowerMonitor.requestIgnoreBatteryOptimizations();
    } catch (e) {
      _log.warning('Failed to prompt battery-optimization exemption', e);
    }
  }

  static void _scheduleWakeLockSafetyCheck() {
    _wakeLockSafetyTimer?.cancel();
    _wakeLockSafetyTimer = Timer(_maxWakeLockHold, () async {
      // FIX: P0-03 — check active downloads before releasing
      final hasActive = await _checkActiveDownloadCount();
      if (hasActive > 0) {
        _log.info('Wake lock safety timer fired but downloads active. Renewing.');
        try {
          await _wakeLockChannel.invokeMethod<void>('acquire');
        } catch (e, st) {
      LoggingService.logger('BackgroundService').warning('Operation failed', e, st);
    }
        // Restart the safety timer for another cycle
        _scheduleWakeLockSafetyCheck();
        return;
      }
      await releaseWakeLock();
    });
  }

  /// Releases the partial wake lock. Safe to call even if no lock is held.
  static Future<void> releaseWakeLock() async {
    if (!isSupported) return;
    try {
      _wakeLockRenewalTimer?.cancel();
      _wakeLockRenewalTimer = null;
      _wakeLockSafetyTimer?.cancel();
      _wakeLockSafetyTimer = null;
      await _wakeLockChannel.invokeMethod<void>('release');
      _wakeLockHeld = false;
      _wakeLockRenewalFailures = 0;
      _wakeLockEscalated = false;
      _log.fine('Wake lock released');
    } catch (e) {
      _log.warning('Failed to release wake lock', e);
    }
  }

  /// Resets all internal timer states and releases the wake lock safely.
  static Future<void> resetWakeLockState() async {
    _wakeLockRenewalTimer?.cancel();
    _wakeLockRenewalTimer = null;
    _wakeLockSafetyTimer?.cancel();
    _wakeLockSafetyTimer = null;
    await releaseWakeLock();
  }
}

/// RAII guard for wake lock management ensuring auto-release on dispose or error
class WakeLockGuard {
  bool _released = false;

  static Future<WakeLockGuard> acquire() async {
    final guard = WakeLockGuard._();
    await BackgroundService.acquireWakeLock();
    return guard;
  }

  WakeLockGuard._();

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await BackgroundService.releaseWakeLock();
  }

  void dispose() {
    if (!_released) {
      release();
    }
  }
}
