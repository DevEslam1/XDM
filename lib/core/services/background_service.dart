import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

@pragma('vm:entry-point')
class BackgroundService {
  static const int foregroundNotificationId = 888;
  static const String _serviceChannelId = 'dmx_background_service';

  static bool get isSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

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

  /// How long without an [updateNotification] event before the service
  /// auto-stops itself. If no download progress is received within this
  /// window the service is considered stale and killed to save battery.
  /// Increased from 15s to 60s to avoid premature shutdown on slow networks.
  static const _heartbeatTimeout = Duration(minutes: 5);

  @pragma('vm:entry-point')
  static void _onStart(ServiceInstance service) {
    Timer? heartbeatTimer;
    bool isStopped = false;
    late final StreamSubscription<Map<String, dynamic>?> stopSub;
    late final StreamSubscription<Map<String, dynamic>?> updateSub;
    late final StreamSubscription<Map<String, dynamic>?> heartbeatSub;

    void cancelAll() {
      isStopped = true;
      heartbeatTimer?.cancel();
      stopSub.cancel();
      updateSub.cancel();
      heartbeatSub.cancel();
    }

    void resetHeartbeat() {
      if (isStopped) return;
      heartbeatTimer?.cancel();
      heartbeatTimer = Timer(_heartbeatTimeout, () {
        if (isStopped) return;
        cancelAll();
        service.stopSelf();
      });
    }

    stopSub = service.on('stopService').listen((_) {
      cancelAll();
      service.stopSelf();
    });

    updateSub = service.on('updateNotification').listen((event) {
      if (isStopped) return;
      resetHeartbeat();
      if (service is AndroidServiceInstance && event is Map<String, dynamic>) {
        service.setForegroundNotificationInfo(
          title: event['title'] as String? ?? 'XDM',
          content: event['content'] as String? ?? '',
        );
      }
    });

    heartbeatSub = service.on('heartbeat').listen((_) {
      if (isStopped) return;
      resetHeartbeat();
    });

    resetHeartbeat();
  }

  @pragma('vm:entry-point')
  static bool _onIosBackground(ServiceInstance service) {
    // iOS background fetch is currently a no-op because Flutter background
    // execution is severely limited on iOS. Consider using a native
    // BGTaskScheduler plugin for actual background downloads.
    return true;
  }

  static Future<void> start() async {
    if (!isSupported) return;
    try {
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint('Failed to enable WakelockPlus: $e');
    }
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }
  }

  static Future<void> stop() async {
    if (!isSupported) return;
    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('Failed to disable WakelockPlus: $e');
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
    service.invoke('updateNotification', {
      'title': title,
      'content': content,
    });
  }

  static Future<void> sendHeartbeat() async {
    if (!isSupported) return;
    final service = FlutterBackgroundService();
    service.invoke('heartbeat');
  }
}
