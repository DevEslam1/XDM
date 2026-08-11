import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/localization.dart';
import 'package:dmx/core/services/logging_service.dart';

const String _nonceKey = 'dmx_notification_nonce';
const String _pendingActionsKey = 'dmx_pending_notification_actions';

@pragma('vm:entry-point')
void _onBackgroundNotificationResponse(NotificationResponse response) {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  var actionId = response.actionId ?? 'tap';
  var payload = response.payload;

  if (actionId.contains(':')) {
    final parts = actionId.split(':');
    actionId = parts[0];
    payload = parts[1];
  }

  unawaited(_forwardBackgroundAction(actionId, payload));
}

Future<void> _forwardBackgroundAction(String actionId, String? payload) async {
  try {
    if (payload == null || payload.isEmpty) {
      debugPrint(
          '[NotificationService] WARNING: null or empty payload for action $actionId');
    }

    final prefs = await SharedPreferences.getInstance();
    final nonce = prefs.getString(_nonceKey);
    final rawList = prefs.getStringList(_pendingActionsKey) ?? <String>[];

    final actionJson = jsonEncode({
      'action': actionId,
      'taskId': payload,
      'nonce': nonce,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    rawList.add(actionJson);
    await prefs.setStringList(_pendingActionsKey, rawList);

    final port = IsolateNameServer.lookupPortByName('dmx_notification_port');
    if (port != null) {
      try {
        port.send({'action': actionId, 'taskId': payload, 'nonce': nonce});
      } catch (e) {
        debugPrint('[NotificationService] Port send failed: $e');
      }
    }
  } catch (e) {
    debugPrint('[NotificationService] Background action forward failed: $e');
  }
}

String? _nonce;

class NotificationService {
  NotificationService._() {
    unawaited(_ensureNoncePersisted());
  }

  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;

  Future<void> _ensureNoncePersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var persistedNonce = prefs.getString(_nonceKey);
      if (persistedNonce == null || persistedNonce.isEmpty) {
        final rand = Random.secure();
        persistedNonce = base64Encode(
          List<int>.generate(16, (_) => rand.nextInt(256)),
        );
        await prefs.setString(_nonceKey, persistedNonce);
      }
      _nonce = persistedNonce;
    } catch (e) {
      debugPrint('[NotificationService] Failed to ensure nonce: $e');
    }
  }

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

  final List<Map<String, String>> _pendingActions = [];
  static const int _maxPendingActions = 100;

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
    _pendingActions.add(event);
    if (_pendingActions.length > _maxPendingActions) {
      final dropped = _pendingActions.length - _maxPendingActions;
      _pendingActions.removeRange(0, dropped);
      debugPrint(
        '[NotificationService] Dropped $dropped queued action(s); '
        'buffer exceeded $_maxPendingActions.',
      );
    }
    if (!_actionStreamController.isClosed &&
        _actionStreamController.hasListener) {
      while (_pendingActions.isNotEmpty) {
        _actionStreamController.add(_pendingActions.removeAt(0));
      }
    }
  }

  static bool _isValidTaskId(String id) {
    if (id.isEmpty || id.length > 128) return false;
    return RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id);
  }

  Future<bool> requestNotificationPermission() async {
    if (!isSupported) return true;
    try {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        final granted = await androidPlugin.requestNotificationsPermission();
        return granted ?? false;
      }
    } catch (e, st) {
      LoggingService.logger('NotificationService').warning(
        '[NotificationService] notification permission request failed',
        e,
        st,
      );
    }
    return false;
  }

  static const Set<String> _groupActions = {
    'pause_all',
    'resume_all',
    'stop_all',
    'start_all',
    'exit_app',
  };

  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _receivePortSub;
  Future<void>? _initFuture;
  Timer? _pollTimer;

  Future<void> _clearPendingActions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingActionsKey);
    } catch (e) {
      debugPrint('[NotificationService] Failed to clear pending actions: $e');
    }
  }

  Future<void> processPendingBackgroundActions() async {
    if (!isSupported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawList = prefs.getStringList(_pendingActionsKey);
      if (rawList == null || rawList.isEmpty) return;

      for (final rawJson in rawList) {
        try {
          final map = jsonDecode(rawJson) as Map<String, dynamic>;
          final action = map['action'] as String?;
          final taskId = map['taskId'] as String?;
          final receivedNonce = map['nonce'] as String?;

          if (_nonce != null &&
              receivedNonce != null &&
              receivedNonce != _nonce) {
            debugPrint(
              '[NotificationService] Invalid nonce in pending action - ignoring',
            );
            continue;
          }

          if (action != null) {
            if (_groupActions.contains(action)) {
              _addAction({'action': action});
            } else if (taskId != null && _isValidTaskId(taskId)) {
              _addAction({'action': action, 'taskId': taskId});
            }
          }
        } catch (e) {
          debugPrint(
            '[NotificationService] Error decoding pending action: $e',
          );
        }
      }

      final latestList = prefs.getStringList(_pendingActionsKey) ?? <String>[];
      latestList.removeWhere((item) => rawList.contains(item));
      if (latestList.isEmpty) {
        await prefs.remove(_pendingActionsKey);
      } else {
        await prefs.setStringList(_pendingActionsKey, latestList);
      }
    } catch (e) {
      debugPrint(
        '[NotificationService] Failed to process pending background actions: $e',
      );
    }
  }

  void startPollingPendingActions() {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (_pollTimer != null && _pollTimer!.isActive) return;
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(processPendingBackgroundActions());
    });
  }

  void stopPollingPendingActions() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> init({bool requestPermission = true}) async {
    if (!isSupported) return;

    if (_initFuture != null) {
      if (_receivePort != null &&
          IsolateNameServer.lookupPortByName('dmx_notification_port') != null) {
        unawaited(processPendingBackgroundActions());
        return _initFuture!;
      }
      try {
        await _initFuture!.timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint(
          '[NotificationService] In-flight init timed out or failed ($e). Proceeding with fresh init.',
        );
        _initFuture = null;
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

      await _ensureNoncePersisted();

      if (_actionStreamController.isClosed) {
        _actionStreamController = _createActionStreamController(
          _pendingActions,
        );
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

      _receivePort = ReceivePort();
      IsolateNameServer.registerPortWithName(
        _receivePort!.sendPort,
        'dmx_notification_port',
      );

      _receivePortSub = _receivePort!.listen((message) {
        if (message is Map) {
          final action = message['action'] as String?;
          final taskId = message['taskId'] as String?;
          final receivedNonce = message['nonce'] as String?;

          if (_nonce != null &&
              receivedNonce != null &&
              receivedNonce != _nonce) {
            debugPrint(
              '[NotificationService] Invalid nonce - rejecting action',
            );
            return;
          }

          if (action != null) {
            if (_groupActions.contains(action)) {
              _addAction({'action': action});
            } else if (taskId != null && _isValidTaskId(taskId)) {
              _addAction({'action': action, 'taskId': taskId});
            } else {
              debugPrint(
                '[NotificationService] Dropped action "$action": '
                'taskId=${taskId ?? "null"} failed validation',
              );
            }
          }
          unawaited(_clearPendingActions());
        }
      });

      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (response) {
          var actionId = response.actionId ?? 'tap';
          var payload = response.payload;

          if (actionId.contains(':')) {
            final parts = actionId.split(':');
            actionId = parts[0];
            payload = parts[1];
          }

          if (_groupActions.contains(actionId)) {
            _addAction({'action': actionId});
          } else if (payload != null && _isValidTaskId(payload)) {
            _addAction({'action': actionId, 'taskId': payload});
          } else {
            debugPrint(
              '[NotificationService] Dropped response action "$actionId": '
              'payload=${payload ?? "null"} failed validation',
            );
          }
          unawaited(processPendingBackgroundActions());
        },
        onDidReceiveBackgroundNotificationResponse:
            _onBackgroundNotificationResponse,
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
            description:
                'Notifications for completed or failed downloads with sound',
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

      await processPendingBackgroundActions();
      startPollingPendingActions();
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

  Future<void> showServiceNotification({
    required String title,
    required String content,
  }) async {
    if (!_initialized) return;
    if (!Platform.isAndroid) return;

    const serviceNotificationId = 888;
    const channelId = 'dmx_background_service';
    const channelName = 'XDM Background Service';

    const androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: 'Used for XDM background download service',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      showProgress: false,
      actions: [
        AndroidNotificationAction(
          'stop_all',
          'Stop All',
          showsUserInterface: true,
        ),
        AndroidNotificationAction(
          'start_all',
          'Start All',
          showsUserInterface: true,
        ),
        AndroidNotificationAction(
          'exit_app',
          'Exit App',
          showsUserInterface: true,
        ),
      ],
    );

    await _plugin.show(
      id: serviceNotificationId,
      title: title,
      body: content,
      notificationDetails: const NotificationDetails(android: androidDetails),
    );
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
    String? groupKey,
  }) async {
    if (!_initialized) return;

    final actions = <AndroidNotificationAction>[
      AndroidNotificationAction(
        isPaused ? 'resume:$payload' : 'pause:$payload',
        isPaused
            ? L10n.translate(languageCode, 'resume_btn')
            : L10n.translate(languageCode, 'pause_btn'),
        showsUserInterface: true,
      ),
      AndroidNotificationAction(
        'cancel:$payload',
        L10n.translate(languageCode, 'cancel_btn'),
        showsUserInterface: true,
      ),
    ];

    if (hasMultipleActive) {
      actions.addAll([
        AndroidNotificationAction(
          'pause_all',
          L10n.translate(languageCode, 'pause_all_btn'),
          showsUserInterface: true,
        ),
        AndroidNotificationAction(
          'resume_all',
          L10n.translate(languageCode, 'resume_all_btn'),
          showsUserInterface: true,
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
      groupKey: groupKey,
      groupAlertBehavior: groupKey == null
          ? GroupAlertBehavior.all
          : GroupAlertBehavior.children,
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: !isPaused,
      interruptionLevel: InterruptionLevel.passive,
      threadIdentifier: groupKey ?? 'dmx_downloads',
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      id: notificationId,
      title: title,
      body: isPaused
          ? L10n.translate(languageCode, 'notification_paused')
          : (eta.isNotEmpty ? '$speed | $eta' : speed),
      notificationDetails: details,
      payload: payload,
    );
  }

  Future<void> showGroupSummary({
    required int notificationId,
    required int activeCount,
    String? groupKey,
  }) async {
    if (!_initialized || groupKey == null) return;

    final androidDetails = AndroidNotificationDetails(
      _downloadChannelId,
      _downloadChannelName,
      channelDescription: _downloadChannelDesc,
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: activeCount,
      progress: activeCount,
      ongoing: true,
      autoCancel: false,
      setAsGroupSummary: true,
      groupKey: groupKey,
      groupAlertBehavior: GroupAlertBehavior.children,
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: false,
      interruptionLevel: InterruptionLevel.passive,
      threadIdentifier: groupKey,
      subtitle: '$activeCount active',
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      id: notificationId,
      title: '$activeCount active downloads',
      body: 'Tap to manage active transfers',
      notificationDetails: details,
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

    final channelId =
        playSound ? 'dmx_download_alerts_sound' : _downloadChannelId;
    final channelName =
        playSound ? 'Download Alerts (Sound)' : _downloadChannelName;

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
      threadIdentifier: 'dmx_downloads',
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

    final channelId =
        playSound ? 'dmx_download_alerts_sound' : _downloadChannelId;
    final channelName =
        playSound ? 'Download Alerts (Sound)' : _downloadChannelName;

    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      importance: playSound ? Importance.defaultImportance : Importance.low,
      priority: playSound ? Priority.defaultPriority : Priority.low,
      showProgress: false,
      playSound: playSound,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
      threadIdentifier: 'dmx_downloads',
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

  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _plugin.cancelAll();
  }

  Future<void> dispose() async {
    _pollTimer?.cancel();
    _pollTimer = null;
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