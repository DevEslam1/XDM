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
  if (actionId != null) {
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

  // Buffered event queue: events emitted before the UI subscribes are held
  // here and replayed on first listen, so pause/resume/cancel actions are
  // never silently lost during app startup.
  final List<Map<String, String>> _pendingActions = [];

  static StreamController<Map<String, String>> _createActionStreamController(
    List<Map<String, String>> pending,
  ) {
    StreamController<Map<String, String>>? c;
    c = StreamController<Map<String, String>>.broadcast(
      sync: true,
      onListen: () {
        while (pending.isNotEmpty) {
          c!.add(pending.removeAt(0));
        }
      },
    );
    return c;
  }

  late StreamController<Map<String, String>> _actionStreamController =
      _createActionStreamController(_pendingActions);

  Stream<Map<String, String>> get onActionTapped =>
      _actionStreamController.stream;

  void _addAction(Map<String, String> event) {
    if (!_actionStreamController.isClosed &&
        _actionStreamController.hasListener) {
      _actionStreamController.add(event);
    } else {
      _pendingActions.add(event);
    }
  }

  /// Validates that a task ID has a plausible UUID or native format.
  /// Provides basic injection protection for notification payloads.
  static bool _isValidTaskId(String id) {
    if (id.isEmpty || id.length > 128) return false;
    // Matches standard UUID format (e.g. 550e8400-e29b-41d4-a716-446655440000)
    if (RegExp(
      r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
    ).hasMatch(id)) {
      return true;
    }
    // Native format: <microseconds>_<random>
    if (RegExp(r'^\d{10,20}_\d{1,10}$').hasMatch(id)) {
      return true;
    }
    return false;
  }

  /// Request notification runtime permission (Android 13+).
  /// Safe to call multiple times; returns `true` if granted.
  Future<bool> requestNotificationPermission() async {
    if (!isSupported) return true;
    try {
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        final granted = await androidPlugin.requestNotificationsPermission();
        return granted ?? false;
      }
    } catch (_) {}
    return false;
  }

  static const Set<String> _groupActions = {'pause_all', 'resume_all'};

  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _receivePortSub;
  Future<void>? _initFuture;

  Future<void> init({bool requestPermission = true}) async {
    if (!isSupported) return;

    // If init is already in progress or completed successfully, reuse it
    if (_initFuture != null) {
      // Only reset if the port is genuinely missing (crash recovery)
      if (_receivePort != null &&
          IsolateNameServer.lookupPortByName('dmx_notification_port') != null) {
        return _initFuture!;
      }
      // Port is missing — need to re-init, but wait for any in-flight init first
      try {
        await _initFuture;
      } catch (_) {
        // Previous init failed, proceed with fresh init
      }
    }

    final completer = Completer<void>();
    _initFuture = completer.future;
    try {
      IsolateNameServer.removePortNameMapping('dmx_notification_port');
      _receivePortSub?.cancel();
      _receivePortSub = null;
      _receivePort?.close();
      _receivePort = null;

      if (_actionStreamController.isClosed) {
        _actionStreamController = _createActionStreamController(_pendingActions);
      }

      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      const settings = InitializationSettings(android: androidSettings, iOS: iosSettings);

      _receivePort = ReceivePort();
      IsolateNameServer.registerPortWithName(_receivePort!.sendPort, 'dmx_notification_port');

      _receivePortSub = _receivePort!.listen((message) {
        if (message is Map) {
          final action = message['action'] as String?;
          final taskId = message['taskId'] as String?;
          if (action != null) {
            if (_groupActions.contains(action)) {
              _addAction({'action': action});
            } else if (taskId != null && _isValidTaskId(taskId)) {
              _addAction({'action': action, 'taskId': taskId});
            }
          }
        }
      });

      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (response) {
          final actionId = response.actionId ?? 'tap';
          final payload = response.payload;
          if (_groupActions.contains(actionId)) {
            _addAction({'action': actionId});
          } else if (payload != null && _isValidTaskId(payload)) {
            _addAction({'action': actionId, 'taskId': payload});
          }
        },
        onDidReceiveBackgroundNotificationResponse: _onBackgroundNotificationResponse,
      );

      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        if (requestPermission) {
          await androidPlugin.requestNotificationsPermission();
        }
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
      completer.complete();
    } catch (e) {
      completer.completeError(e);
      rethrow;
    }
  }

  void resetInit() {
    _initFuture = null;
  }

  Future<void> showDownloadProgress({
    required int notificationId,
    required String title,
    required int progressPercent,
    required String speed,
    required String eta,
    required String languageCode,
    required String payload,
    bool isPaused = false,
    bool hasMultipleActive = false,
  }) async {
    if (!_initialized) return;

    final actions = <AndroidNotificationAction>[
      AndroidNotificationAction(
        isPaused ? 'resume' : 'pause',
        isPaused
            ? L10n.translate(languageCode, 'resume_btn')
            : L10n.translate(languageCode, 'pause_btn'),
        showsUserInterface: false,
      ),
      AndroidNotificationAction(
        'cancel',
        L10n.translate(languageCode, 'cancel_btn'),
        showsUserInterface: false,
      ),
    ];

    if (hasMultipleActive) {
      actions.addAll([
        AndroidNotificationAction(
          'pause_all',
          L10n.translate(languageCode, 'pause_all_btn'),
          showsUserInterface: false,
        ),
        AndroidNotificationAction(
          'resume_all',
          L10n.translate(languageCode, 'resume_all_btn'),
          showsUserInterface: false,
        ),
      ]);
    }

    final androidDetails = AndroidNotificationDetails(
      _downloadChannelId,
      _downloadChannelName,
      channelDescription: _downloadChannelDesc,
      importance: Importance.low,
      priority: Priority.low,
      showProgress: !isPaused,
      maxProgress: 100,
      progress: progressPercent.clamp(0, 100),
      onlyAlertOnce: true,
      ongoing: !isPaused,
      autoCancel: false,
      actions: actions,
    );
    final iosDetails = DarwinNotificationDetails(
      presentAlert: !isPaused,
      interruptionLevel: InterruptionLevel.passive,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    await _plugin.show(
      id: notificationId,
      title: title,
      body: isPaused
          ? (languageCode == 'ar' ? 'متوقف مؤقتاً' : 'Paused')
          : (eta.isNotEmpty ? '$speed | $eta' : speed),
      notificationDetails: details,
      payload: payload,
    );
  }

  Future<void> showDownloadComplete({
    required int notificationId,
    required String title,
    String body = 'Download complete',
    bool playSound = true,
    String? payload,
    List<AndroidNotificationAction>? actions,
  }) async {
    if (!_initialized) return;
    final channelId = playSound ? 'dmx_download_alerts_sound' : _downloadChannelId;
    final channelName = playSound ? 'Download Alerts (Sound)' : _downloadChannelName;
    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      importance: playSound ? Importance.defaultImportance : Importance.high,
      priority: playSound ? Priority.defaultPriority : Priority.high,
      showProgress: false,
      playSound: playSound,
      actions: actions,
    );
    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      interruptionLevel: playSound
          ? InterruptionLevel.timeSensitive
          : InterruptionLevel.passive,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    await _plugin.show(
      id: notificationId,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
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
    final iosDetails = const DarwinNotificationDetails(
      presentAlert: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
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

  /// Cancels all stale notifications from previous sessions
  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _plugin.cancelAll();
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
