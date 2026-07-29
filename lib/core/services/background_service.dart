import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

@pragma('vm:entry-point')
class BackgroundService {
  static const int foregroundNotificationId = 888;
  static const String _serviceChannelId = 'dmx_background_service';

  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

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

    void cancelAll() {
      isStopped = true;
      stopSub?.cancel();
      updateSub?.cancel();
    }

    stopSub = service
        .on('stopService')
        .listen(
          (_) {
            try {
              cancelAll();
              service.stopSelf();
            } catch (e) {
              debugPrint('[BackgroundService] stopService error: $e');
            }
          },
          cancelOnError: false,
          onError: (e) {
            debugPrint('[BackgroundService] stopService stream error: $e');
          },
        );

    updateSub = service
        .on('updateNotification')
        .listen(
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
              debugPrint('[BackgroundService] updateNotification error: $e');
            }
          },
          cancelOnError: false,
          onError: (e) {
            debugPrint(
              '[BackgroundService] updateNotification stream error: $e',
            );
          },
        );

    // Heartbeat events are accepted but no longer trigger auto-stop.
    // The service lives until explicitly stopped via stopService — minimizing
    // the app used to pause the Flutter engine, stop heartbeats, and let the
    // service self-terminate mid-download.
    service
        .on('heartbeat')
        .listen(
          (_) {
            // Intentionally empty — kept for API compatibility.
          },
          cancelOnError: false,
          onError: (_) {},
        );
  }

  @pragma('vm:entry-point')
  static bool _onIosBackground(ServiceInstance service) {
    // iOS background execution is not supported by Flutter without a native
    // BGTaskScheduler plugin. The FlutterBackgroundService plugin does not
    // keep Dart isolates alive on iOS once the app is suspended. Without a
    // BGTaskScheduler-based native plugin, background downloads on iOS
    // cannot make progress. This callback returns true to acknowledge the
    // wake but performs no work.
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
    service.invoke('updateNotification', {'title': title, 'content': content});
  }

  static Future<void> sendHeartbeat() async {
    if (!isSupported) return;
    final service = FlutterBackgroundService();
    service.invoke('heartbeat');
  }
}
