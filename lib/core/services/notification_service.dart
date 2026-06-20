import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../utils/localization.dart';

@pragma('vm:entry-point')
void _onBackgroundNotificationResponse(NotificationResponse response) {
  final actionId = response.actionId;
  final payload = response.payload;
  if (actionId != null && payload != null) {
    final port = IsolateNameServer.lookupPortByName('dmx_notification_port');
    if (port != null) {
      port.send({
        'action': actionId,
        'taskId': payload,
      });
    }
  }
}

class NotificationService {
  NotificationService._();
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  static bool get isSupported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isLinux);

  static const String _downloadChannelId = 'dmx_download_progress';
  static const String _downloadChannelName = 'Download Progress';
  static const String _downloadChannelDesc =
      'Real-time download transfer progress';

  StreamController<Map<String, String>> _actionStreamController =
      StreamController<Map<String, String>>.broadcast();

  Stream<Map<String, String>> get onActionTapped => _actionStreamController.stream;

  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _receivePortSub;

  Future<void> init() async {
    if (!isSupported) return;

    // Clean up any previous ReceivePort/subscription to prevent leaks on re-init
    _receivePortSub?.cancel();
    _receivePortSub = null;
    _receivePort?.close();
    _receivePort = null;
    IsolateNameServer.removePortNameMapping('dmx_notification_port');

    if (_actionStreamController.isClosed) {
      _actionStreamController = StreamController<Map<String, String>>.broadcast();
    }

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    // Register ReceivePort for background actions
    _receivePort = ReceivePort();
    IsolateNameServer.registerPortWithName(_receivePort!.sendPort, 'dmx_notification_port');

    _receivePortSub = _receivePort!.listen((message) {
      if (message is Map) {
        final action = message['action'] as String?;
        final taskId = message['taskId'] as String?;
        if (action != null && taskId != null) {
          _actionStreamController.add({
            'action': action,
            'taskId': taskId,
          });
        }
      }
    });

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) {
        final actionId = response.actionId;
        final payload = response.payload;
        if (actionId != null && payload != null) {
          _actionStreamController.add({
            'action': actionId,
            'taskId': payload,
          });
        }
      },
      onDidReceiveBackgroundNotificationResponse: _onBackgroundNotificationResponse,
    );

    // Request runtime notification permission and create channels on Android 13+
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.requestNotificationsPermission();
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _downloadChannelId,
          _downloadChannelName,
          description: _downloadChannelDesc,
          importance: Importance.low,
          playSound: false,
        ),
      );
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          'dmx_download_alerts_sound',
          'Download Alerts (Sound)',
          description: 'Notifications for completed or failed downloads with sound',
          importance: Importance.defaultImportance,
          playSound: true,
        ),
      );
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          'dmx_background_service',
          'XDM Background Service',
          description: 'Used for XDM background download service',
          importance: Importance.low,
          playSound: false,
        ),
      );
    }
    _initialized = true;
  }

  Future<void> showDownloadProgress({
    required int notificationId,
    required String title,
    required int progress,
    required int maxProgress,
    required String speed,
    required String eta,
    required String languageCode,
    required String payload,
  }) async {
    if (!_initialized) return;
    final androidDetails = AndroidNotificationDetails(
      _downloadChannelId,
      _downloadChannelName,
      channelDescription: _downloadChannelDesc,
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: 100,
      progress: maxProgress > 0
          ? ((progress / maxProgress) * 100).round().clamp(0, 100)
          : 0,
      onlyAlertOnce: true,
      ongoing: true,
      autoCancel: false,
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          'pause',
          L10n.translate(languageCode, 'pause_btn'),
          showsUserInterface: false,
        ),
        AndroidNotificationAction(
          'cancel',
          L10n.translate(languageCode, 'cancel_btn'),
          showsUserInterface: false,
        ),
      ],
    );
    final details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      id: notificationId,
      title: title,
      body: '$speed • $eta',
      notificationDetails: details,
      payload: payload,
    );
  }

  Future<void> showDownloadComplete({
    required int notificationId,
    required String title,
    bool playSound = true,
  }) async {
    if (!_initialized) return;
    final channelId = playSound ? 'dmx_download_alerts_sound' : _downloadChannelId;
    final channelName = playSound ? 'Download Alerts (Sound)' : _downloadChannelName;
    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      importance: playSound ? Importance.defaultImportance : Importance.low,
      priority: playSound ? Priority.defaultPriority : Priority.low,
      showProgress: false,
      playSound: playSound,
    );
    final details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      id: notificationId,
      title: title,
      body: 'Download complete',
      notificationDetails: details,
    );
  }

  Future<void> showDownloadFailed({
    required int notificationId,
    required String title,
    String? error,
    bool playSound = true,
  }) async {
    if (!_initialized) return;
    final channelId = playSound ? 'dmx_download_alerts_sound' : _downloadChannelId;
    final channelName = playSound ? 'Download Alerts (Sound)' : _downloadChannelName;
    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      importance: playSound ? Importance.defaultImportance : Importance.low,
      priority: playSound ? Priority.defaultPriority : Priority.low,
      showProgress: false,
      playSound: playSound,
    );
    final details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      id: notificationId,
      title: title,
      body: error ?? 'Download failed',
      notificationDetails: details,
    );
  }

  Future<void> cancelNotification(int notificationId) async {
    if (!_initialized) return;
    await _plugin.cancel(id: notificationId);
  }

  Future<void> dispose() async {
    await _receivePortSub?.cancel();
    _receivePortSub = null;
    _receivePort?.close();
    _receivePort = null;
    IsolateNameServer.removePortNameMapping('dmx_notification_port');
    if (!_actionStreamController.isClosed) {
      await _actionStreamController.close();
    }
  }
}
