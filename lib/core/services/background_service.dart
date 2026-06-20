import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

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
  static const _heartbeatTimeout = Duration(seconds: 15);

  @pragma('vm:entry-point')
  static void _onStart(ServiceInstance service) {
    if (service is AndroidServiceInstance) {
      Timer? heartbeatTimer;

      void resetHeartbeat() {
        heartbeatTimer?.cancel();
        heartbeatTimer = Timer(_heartbeatTimeout, () {
          service.stopSelf();
        });
      }

      resetHeartbeat();

      service.on('stopService').listen((_) {
        heartbeatTimer?.cancel();
        service.stopSelf();
      });

      service.on('updateNotification').listen((event) {
        resetHeartbeat();
        if (event is Map<String, dynamic>) {
          service.setForegroundNotificationInfo(
            title: event['title'] as String? ?? 'XDM',
            content: event['content'] as String? ?? '',
          );
        }
      });

      service.on('heartbeat').listen((_) {
        resetHeartbeat();
      });
    }
  }

  @pragma('vm:entry-point')
  static bool _onIosBackground(ServiceInstance service) {
    return true;
  }

  static Future<void> start() async {
    if (!isSupported) return;
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }
  }

  static Future<void> stop() async {
    if (!isSupported) return;
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
