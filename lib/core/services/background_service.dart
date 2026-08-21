// FIX: P0-03 & P0-04 — Guard BackgroundService.stop() and WakeLock auto-release against active downloads
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

import '../../features/downloads/models/download_task.dart';
import '../../features/downloads/services/torrent_session_manager.dart';
import '../di/injection.dart';
import 'background_scheduler.dart';
import 'database_service.dart';
import 'diagnostic_service.dart';
import 'download_engine.dart';
import 'ios_background_service.dart';
import 'logging_service.dart';
import 'notification_service.dart';
import 'power_monitor.dart';
import 'torrent_service.dart';

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
  static Duration get _maxWakeLockHold => Platform.isIOS
      ? const Duration(seconds: 30)
      : const Duration(minutes: 10);
  static DateTime? _lastHeartbeatTime;
  static final Lock _activeLock = Lock();
  static final Set<String> _activeTaskIds = <String>{};
  static int _activeDownloadCount = 0;
  static int Function()? _activeDownloadCountQuery;

  @visibleForTesting
  static int get activeDownloadCountForTesting => _activeDownloadCount;

  @visibleForTesting
  static Set<String> get activeTaskIdsForTesting =>
      Set.unmodifiable(_activeTaskIds);

  @visibleForTesting
  static void resetActiveDownloadCountForTesting() {
    _activeDownloadCount = 0;
    _activeTaskIds.clear();
  }

  /// Consecutive wake-lock renewal failures (escalate after 2).
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
    return _activeDownloadCount;
  }

  /// Callback invoked when background execution is requested on iOS where it is unsupported.
  static VoidCallback? onIosBackgroundUnavailable;

  static Future<void> setDownloadActive(bool active, String taskId) async {
    await _activeLock.synchronized(() async {
      if (active) {
        if (_activeTaskIds.add(taskId)) {
          _activeDownloadCount = _activeTaskIds.length;
        }
      } else {
        if (_activeTaskIds.remove(taskId)) {
          _activeDownloadCount = _activeTaskIds.length;
        }
      }
      assert(
        _activeTaskIds.length == _activeDownloadCount,
        'activeTaskIds ($_activeTaskIds) out of sync with count '
        '($_activeDownloadCount) after setDownloadActive($active, $taskId)',
      );
      await _afterActiveCountChanged();
    });
  }

  /// Reconciles the internally tracked active task set to exactly
  /// [activeTaskIds]. This is the aggregate form used by callers that compute
  /// the full set of active downloads (e.g. the provider widget timer).
  static Future<void> reconcileActiveTaskIds(Set<String> activeTaskIds) async {
    await _activeLock.synchronized(() async {
      _activeTaskIds
        ..removeWhere((id) => !activeTaskIds.contains(id))
        ..addAll(activeTaskIds);
      _activeDownloadCount = _activeTaskIds.length;
      assert(
        _activeTaskIds.length == _activeDownloadCount,
        'activeTaskIds ($_activeTaskIds) out of sync with count '
        '($_activeDownloadCount) after reconcileActiveTaskIds',
      );
      await _afterActiveCountChanged();
    });
  }

  /// Shared post-update logic: maintain the heartbeat timer and wake lock
  /// based on the (possibly task-tracked) active download count.
  static Future<void> _afterActiveCountChanged() async {
    if (_activeDownloadCount <= 0) {
      final queryCount = _activeDownloadCountQuery?.call() ?? 0;
      if (queryCount <= 0) {
        _heartbeatTimer?.cancel();
        _heartbeatTimer = null;
        await releaseWakeLock();
      }
    } else {
      if (!kIsWeb && Platform.isAndroid) {
        final isRunning =
            _testMode || await FlutterBackgroundService().isRunning();
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
    try {
      final prefs = await SharedPreferences.getInstance();
      final cooldownMs = prefs.getInt(_iosBgCooldownKey);
      if (cooldownMs != null) {
        final cooldownUntil = DateTime.fromMillisecondsSinceEpoch(cooldownMs);
        if (DateTime.now().isBefore(cooldownUntil)) {
          _iosBgCooldownUntil = cooldownUntil;
        } else {
          await prefs.remove(_iosBgCooldownKey);
          _iosBgCooldownUntil = null;
        }
      }
    } catch (e, st) {
      _log.fine('Failed to load iOS background cooldown', e, st);
    }
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
  static StreamSubscription<Map<String, dynamic>?>?
      get onStartStopSubForTesting => onStartStopSub;

  @visibleForTesting
  static StreamSubscription<Map<String, dynamic>?>?
      get onStartUpdateSubForTesting => onStartUpdateSub;

  @visibleForTesting
  static StreamSubscription<Map<String, dynamic>?>?
      get onStartHeartbeatSubForTesting => onStartHeartbeatSub;

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
  static DateTime? _iosBgCooldownUntil;

  static const String _iosBgCooldownKey = 'ios_bg_cooldown_until_ms';

  static const List<Duration> _bgBackoffSchedule = [
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 10),
    Duration(hours: 1),
  ];

  static const String _bgFailuresKey = 'bg_consecutive_failures';
  static const String _bgNextAllowedTimeKey = 'bg_next_allowed_attempt_ms';

  /// Returns true if background attempts should be throttled due to repeated failures.
  static Future<bool> shouldThrottleForBackoff() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final nextAllowedMs = prefs.getInt(_bgNextAllowedTimeKey) ?? 0;
      return DateTime.now().millisecondsSinceEpoch < nextAllowedMs;
    } catch (_) {
      return false;
    }
  }

  /// Records a background failure and advances exponential backoff schedule.
  static Future<void> recordBackgroundFailure() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final failures = (prefs.getInt(_bgFailuresKey) ?? 0) + 1;
      await prefs.setInt(_bgFailuresKey, failures);
      final idx = (failures - 1).clamp(0, _bgBackoffSchedule.length - 1);
      final backoff = _bgBackoffSchedule[idx];
      final nextAllowed = DateTime.now().add(backoff).millisecondsSinceEpoch;
      await prefs.setInt(_bgNextAllowedTimeKey, nextAllowed);
      _log.warning(
        'Recorded background failure #$failures. Backoff for ${backoff.inSeconds}s.',
      );
    } catch (e, st) {
      _log.fine('Failed to persist background failure backoff', e, st);
    }
  }

  /// Clears consecutive background failure count after a successful execution.
  static Future<void> recordBackgroundSuccess() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_bgFailuresKey);
      await prefs.remove(_bgNextAllowedTimeKey);
    } catch (e, st) {
      _log.fine('Failed to reset background failure backoff', e, st);
    }
  }

  @visibleForTesting
  static DateTime? get iosBgCooldownUntilForTesting => _iosBgCooldownUntil;

  @visibleForTesting
  static set iosBgCooldownUntilForTesting(DateTime? val) =>
      _iosBgCooldownUntil = val;

  @visibleForTesting
  static bool get iosBgCallInFlightForTesting => _iosBgCallInFlight;

  @visibleForTesting
  static set iosBgCallInFlightForTesting(bool val) => _iosBgCallInFlight = val;

  @visibleForTesting
  static Timer? get iosBgWatchdogTimerForTesting => _iosBgWatchdogTimer;

  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground([ServiceInstance? service]) async {
    _log.info(
      'iOS background callback invoked. Bridging to native BackgroundDownloadController.',
    );
    if (_iosBgCooldownUntil != null) {
      if (DateTime.now().isBefore(_iosBgCooldownUntil!)) {
        _log.warning(
          'iOS background callback invoked during 60s cooldown; skipping execution.',
        );
        return false;
      } else {
        _iosBgCooldownUntil = null;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove(_iosBgCooldownKey);
        } catch (e, st) {
          _log.fine('Failed to clear expired iOS background cooldown', e, st);
        }
      }
    }
    if (_iosBgCallInFlight) {
      _log.warning(
          'iOS background callback already in flight, ignoring duplicate call');
      return false;
    }
    _iosBgCallInFlight = true;
    final result = Completer<bool>();

    _iosBgWatchdogTimer?.cancel();
    _iosBgWatchdogTimer = Timer(const Duration(seconds: 25), () async {
      if (!result.isCompleted) {
        _log.warning(
            '[iOS BG Watchdog] iOS background call wedged for 25s; force-resetting and allowing next schedule.');
        try {
          DownloadEngine.markBackground();
          await Future.wait([
            DatabaseService.instance.flushPendingSaves(),
            DatabaseService.instance.checkpointWal(truncate: false),
          ]).timeout(const Duration(seconds: 3));
        } catch (e, st) {
          _log.warning(
              'Failed to flush/checkpoint DB during iOS background watchdog reset: $e',
              e,
              st);
        }
        result.complete(false);
      }
    });

    Future<void> runNativeCall() async {
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
        final nativeStart = DateTime.now();
        final rawResult = await channel.invokeMethod<bool>('scheduleDownload');
        final nativeDuration = DateTime.now().difference(nativeStart);
        if (nativeDuration.inSeconds > 10) {
          _log.warning(
              '[iOS BG] Native scheduleDownload took ${nativeDuration.inSeconds}s — approaching limit');
        }

        if (result.isCompleted) {
          _log.warning(
              '[iOS BG] Native call finished after watchdog completed; discarding result.');
          return;
        }

        final success = rawResult ?? false;
        if (success) {
          await recordBackgroundSuccess();
        } else {
          await recordBackgroundFailure();
          final cooldown = DateTime.now().add(const Duration(seconds: 60));
          _iosBgCooldownUntil = cooldown;
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setInt(
                _iosBgCooldownKey, cooldown.millisecondsSinceEpoch);
          } catch (e, st) {
            _log.fine(
                'Failed to persist iOS background failure cooldown', e, st);
          }
        }
        _log.info('iOS background schedule completed. Success: $success');
        result.complete(success);
      } catch (e, st) {
        if (!result.isCompleted) {
          await recordBackgroundFailure();
          final cooldown = DateTime.now().add(const Duration(seconds: 60));
          _iosBgCooldownUntil = cooldown;
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setInt(
                _iosBgCooldownKey, cooldown.millisecondsSinceEpoch);
          } catch (e2, st2) {
            _log.fine(
                'Failed to persist iOS background error cooldown', e2, st2);
          }
          _log.fine(
              'Failed to bridge to iOS background download controller', e, st);
          result.complete(false);
        }
      }
    }

    try {
      await Future.any([runNativeCall(), result.future]);
      return await result.future;
    } finally {
      _iosBgWatchdogTimer?.cancel();
      _iosBgWatchdogTimer = null;
      _iosBgCallInFlight = false;
    }
  }

  @visibleForTesting
  static void resetIosCooldownForTesting() {
    _iosBgCooldownUntil = null;
  }

  @visibleForTesting
  static Future<bool> onIosBackgroundForTesting([ServiceInstance? service]) =>
      _onIosBackground(service);

  /// Android 15 (API 35) dataSync foreground service 6-hour runtime timeout watchdog
  static DateTime? _dataSyncSessionStartTime;
  static Timer? _dataSyncTimeoutTimer;
  static const Duration _maxDataSyncDuration = Duration(hours: 5, minutes: 55);

  /// Callback to pause active tasks when the 6-hour dataSync limit is hit.
  static Future<void> Function()? onDataSyncTimeout;

  @visibleForTesting
  static DateTime? get dataSyncSessionStartTimeForTesting =>
      _dataSyncSessionStartTime;

  @visibleForTesting
  static Future<void> triggerDataSyncTimeoutForTesting() =>
      _handleDataSyncTimeout();

  static Future<void> _handleDataSyncTimeout() async {
    _log.warning(
      'Android 15 dataSync 6-hour foreground service timeout reached. '
      'Pausing tasks, flushing state, and scheduling background retry.',
    );
    _dataSyncTimeoutTimer?.cancel();
    _dataSyncTimeoutTimer = null;
    _dataSyncSessionStartTime = null;

    try {
      if (onDataSyncTimeout != null) {
        await onDataSyncTimeout!();
      }
      DownloadEngine.markBackground();
      await Future.wait([
        DatabaseService.instance.flushPendingSaves(),
        DatabaseService.instance.checkpointWal(truncate: false),
      ]).timeout(const Duration(seconds: 3));
    } catch (e, st) {
      _log.warning('Error pausing tasks or flushing DB during dataSync timeout', e, st);
    }

    try {
      await releaseWakeLock();
    } catch (e, st) {
      _log.warning('Error releasing wakelock during dataSync timeout', e, st);
    }

    try {
      BackgroundScheduler.instance.scheduleBackgroundSync();
    } catch (e, st) {
      _log.warning(
          'Error scheduling background sync on dataSync timeout', e, st);
    }

    try {
      final service = FlutterBackgroundService();
      service.invoke('stopService');
    } catch (_) {}
  }

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

    _dataSyncSessionStartTime ??= DateTime.now();
    _dataSyncTimeoutTimer?.cancel();
    _dataSyncTimeoutTimer = Timer(_maxDataSyncDuration, () {
      _handleDataSyncTimeout();
    });

    if (_testMode) return;

    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }
  }

  static Future<void> stop({bool force = false}) async {
    if (!isSupported) {
      _log.fine('BackgroundService.stop() skipped (unsupported platform)');
      return;
    }

    // FIX: P0-04 — never stop while downloads are running unless force=true
    if (!force) {
      final activeCount = await _checkActiveDownloadCount();
      if (activeCount > 0) {
        _log.info('Not stopping: downloads still active ($activeCount running)');
        return;
      }
    }

    await releaseWakeLock();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _dataSyncTimeoutTimer?.cancel();
    _dataSyncTimeoutTimer = null;
    _dataSyncSessionStartTime = null;
    BackgroundScheduler.instance.stopTimer();

    if (!kIsWeb && Platform.isIOS) {
      _log.info('Cancelling native iOS BGTaskScheduler background task');
      try {
        await IosBackgroundService.cancelBackgroundDownload();
      } catch (e, st) {
        _log.warning('Error cancelling iOS background download', e, st);
      }
      return;
    }

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final service = FlutterBackgroundService();
        service.invoke('stopService');
      } catch (e, st) {
        _log.warning('Error invoking stopService on Android', e, st);
      }
    }
    _log.info('Background service fully stopped');
  }

  void dispose() {
    stop();
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
    if (_activeDownloadCount <= 0) {
      final queryCount = _activeDownloadCountQuery?.call() ?? 0;
      if (queryCount <= 0) return;
    }
    // Battery gate: if battery is <20% and not charging, do not hold wake lock to avoid rapid battery drain
    try {
      if (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive) {
        _log.fine('Wake lock skipped due to aggressive battery saver mode');
        return;
      }
    } catch (e, st) {
      LoggingService.logger('BackgroundService')
          .warning('Operation failed', e, st);
    }

    try {
      await _wakeLockChannel.invokeMethod<void>('acquire');
      _wakeLockHeld = true;
      _wakeLockRenewalFailures = 0;
      _wakeLockEscalated = false;
      _log.fine('Wake lock acquired');

      // Safety net: auto-release or renew if downloads still active
      _scheduleWakeLockSafetyCheck();

      // Start periodic renewal every 15 minutes to prevent native timeout expiry.
      _wakeLockRenewalTimer?.cancel();
      _wakeLockRenewalTimer = Timer.periodic(const Duration(minutes: 15), (
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
          if (_wakeLockRenewalFailures >= 2 && !_wakeLockEscalated) {
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
      '[BackgroundService] Wake lock renewal failed 2× consecutively — escalating',
    );
    try {
      await NotificationService().showServiceNotification(
        title: 'XDM',
        content: 'Background downloads may pause: the system blocked wake-lock '
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
        _log.info(
            'Wake lock safety timer fired but downloads active. Renewing.');
        try {
          await _wakeLockChannel.invokeMethod<void>('acquire');
        } catch (e, st) {
          LoggingService.logger('BackgroundService')
              .warning('Operation failed', e, st);
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

  /// Restores interrupted downloads after unexpected OS kill or reboot (E8).
  static Future<List<DownloadTask>> restoreInterruptedTasks(
    DatabaseService dbService,
  ) async {
    try {
      final tasks = await dbService.loadTasks();
      final restored = <DownloadTask>[];
      // FIX-F: Reconcile session torrent mappings before resuming torrent tasks.
      try {
        await getIt<TorrentSessionManager>().reconcileWithDatabase(dbService);
      } catch (e) {
        _log.warning('Failed to reconcile torrent session on restore: $e');
      }
      for (final task in tasks) {
        if (task.pauseReason == PauseReason.appRestarted ||
            task.status == DownloadStatus.downloading ||
            task.cycleState == CycleState.downloading ||
            task.cycleState == CycleState.starting) {
          final resumingTask = task.copyWith(
            status: DownloadStatus.downloading,
            cycleState: CycleState.resuming,
            speed: 0.0,
            pauseReason: null,
          );
          // FIX-F: For torrents, resume the live handle so the engine actually
          // keeps transferring after the OS-kill/reboot restore.
          if (resumingTask.isTorrent && TorrentService.isInitialized) {
            final tid =
                getIt<TorrentSessionManager>().getTorrentId(resumingTask.id);
            if (tid != null && TorrentService.isTorrentAlive(tid)) {
              try {
                TorrentService.resumeTorrent(tid);
              } catch (e) {
                _log.warning('Failed to resume restored torrent $tid: $e');
              }
            }
          }
          await dbService.saveTask(resumingTask);
          restored.add(resumingTask);
        }
      }
      return restored;
    } catch (e, st) {
      _log.warning('Failed to restore interrupted tasks', e, st);
      return [];
    }
  }

  /// Terminates all background processing when all downloads complete.
  static void onAllDownloadsComplete() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    releaseWakeLock();
    BackgroundScheduler.instance.stopTimer();

    if (!kIsWeb && Platform.isAndroid) {
      try {
        FlutterBackgroundService().invoke('stopService');
      } catch (e, st) {
        _log.warning(
            'Failed to invoke stopService on all downloads complete', e, st);
      }
    }
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
