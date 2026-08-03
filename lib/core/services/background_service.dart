import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'logging_service.dart';

final _log = LoggingService.logger('BackgroundService');

/// ═══════════════════════════════════════════════════════════════════════════
/// iOS Background Download Limitation
/// ═══════════════════════════════════════════════════════════════════════════
/// iOS does NOT support persistent background downloads from a Dart isolate.
/// The `flutter_background_service` plugin cannot keep Dart code alive after
/// the app is suspended (iOS lifecycle rules). To support background
/// downloads on iOS, a native BGTaskScheduler implementation is needed:
///
///   1. Create a native Swift/ObjC class that conforms to `BGTaskScheduler`.
///   2. Register the background task identifier in Info.plist.
///   3. From Dart, schedule the task via a MethodChannel.
///   4. The native code performs or resumes the URLSession download.
///   5. When the download completes, the native code calls back to Dart.
///
/// Until that is implemented:
///   - [start] is a no-op on iOS.
///   - [stop] is a no-op on iOS.
///   - [isSupported] returns `false` on iOS so the app never pretends to
///     run background downloads.
///   - UI should display a warning when the user opens the app on iOS:
///     "Downloads only run while the app is in the foreground on iOS."
///
/// The setting `iosBackgroundDownloadsEnabled` defaults to `false`.
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
  static const Duration _maxWakeLockHold = Duration(hours: 4);

  /// Returns true only on Android. On iOS, background Dart execution is not
  /// supported without a native BGTaskScheduler plugin.
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static Future<void> initialize() async {
    if (!isSupported) return;
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

  @pragma('vm:entry-point')
  static void _onStart(ServiceInstance service) {
    bool isStopped = false;
    StreamSubscription<Map<String, dynamic>?>? stopSub;
    StreamSubscription<Map<String, dynamic>?>? updateSub;
    StreamSubscription<dynamic>? heartbeatSub;

    void cancelAll() {
      isStopped = true;
      stopSub?.cancel();
      updateSub?.cancel();
      heartbeatSub?.cancel();
    }

    stopSub = service.on('stopService').listen(
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

    updateSub = service.on('updateNotification').listen(
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

    heartbeatSub = service
        .on('heartbeat')
        .listen((_) {}, cancelOnError: false, onError: (_) {});
  }

  @pragma('vm:entry-point')
  static bool _onIosBackground(ServiceInstance service) {
    _log.warning(
      'iOS background callback invoked but background Dart execution is '
      'not supported. See BackgroundService docs.',
    );
    return true;
  }

  static Future<void> start() async {
    if (!isSupported) {
      if (Platform.isIOS) {
        _log.warning(
          'iOS does not support background Dart execution. '
          'Downloads will pause when the app is backgrounded. '
          'A native BGTaskScheduler implementation is required.',
        );
      } else {
        _log.fine('BackgroundService.start() skipped (iOS or unsupported)');
      }
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
      _log.fine('BackgroundService.stop() skipped (iOS or unsupported)');
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
    final service = FlutterBackgroundService();
    service.invoke('heartbeat');
  }

  /// Acquires a partial wake lock to keep the CPU awake during active
  /// downloads. Safe to call multiple times; only the first call invokes
  /// the platform channel. The lock is automatically renewed every 15 minutes
  /// to prevent the native 30-minute timeout from expiring.
  static Future<void> acquireWakeLock() async {
    if (!isSupported || _wakeLockHeld) return;
    try {
      await _wakeLockChannel.invokeMethod<void>('acquire');
      _wakeLockHeld = true;
      _log.fine('Wake lock acquired');

      // Safety net: auto-release after max hold duration
      _wakeLockSafetyTimer?.cancel();
      _wakeLockSafetyTimer = Timer(_maxWakeLockHold, () async {
        if (_wakeLockHeld) {
          _log.warning(
              'Wake lock held for ${_maxWakeLockHold.inHours}h. Auto-releasing.');
          await releaseWakeLock();
        }
      });

      // Start periodic renewal every 15 minutes to prevent native timeout expiry
      _wakeLockRenewalTimer?.cancel();
      _wakeLockRenewalTimer = Timer.periodic(const Duration(minutes: 15), (
        _,
      ) async {
        if (_wakeLockHeld && isSupported) {
          try {
            await _wakeLockChannel.invokeMethod<void>('acquire');
            _log.fine('Wake lock renewed');
          } catch (e) {
            _log.warning('Failed to renew wake lock', e);
          }
        }
      });
    } catch (e) {
      _log.warning('Failed to acquire wake lock', e);
    }
  }

  /// Releases the partial wake lock. Safe to call even if no lock is held.
  /// FIX(H6): Always attempt native release regardless of _wakeLockHeld,
  /// since static state is per-isolate and may be stale if the lock was
  /// acquired from a different isolate.
  static Future<void> releaseWakeLock() async {
    if (!isSupported) return;
    try {
      _wakeLockRenewalTimer?.cancel();
      _wakeLockRenewalTimer = null;
      _wakeLockSafetyTimer?.cancel();
      _wakeLockSafetyTimer = null;
      await _wakeLockChannel.invokeMethod<void>('release');
      _wakeLockHeld = false;
      _log.fine('Wake lock released');
    } catch (e) {
      _log.warning('Failed to release wake lock', e);
    }
  }
}
