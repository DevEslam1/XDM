import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

import '../utils/localization.dart';
import 'background_gate.dart';
import 'download_engine.dart';
import 'power_monitor.dart';
import 'tick_manager.dart';

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
  unawaited(_forwardBackgroundAction(actionId, payload).catchError((e) =>
      debugPrint('[Notifications] Failed to forward background action: $e')));
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
    unawaited(_ensureNoncePersisted().catchError((e) =>
        debugPrint('[Notifications] Failed to ensure nonce persisted: $e')));
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
  final Map<int, DateTime> _lastProgressPostTimes = {};
  final Map<int, Timer> _trailingPostTimers = {};

  @visibleForTesting
  static void setInitializedForTesting(bool val) {
    _instance._initialized = val;
  }

  @visibleForTesting
  Future<void> Function({
    required int id,
    required String title,
    required String body,
  })? showHookForTesting;

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

  static const int _maxPendingActions = 50;
  static const Duration _actionStaleThreshold = Duration(seconds: 30);
  final Queue<_BufferedNotificationAction> _actionQueue = Queue();
  final Lock _actionQueueLock = Lock();

  late final StreamController<Map<String, String>> _actionStreamController =
      StreamController<Map<String, String>>.broadcast(
    sync: true,
    onListen: () {
      unawaited(_drainActionQueue().catchError((e) =>
          debugPrint('[Notifications] Failed to drain action queue: $e')));
    },
  );

  Stream<Map<String, String>> get onActionTapped =>
      _actionStreamController.stream;

  Future<void> _drainActionQueue() async {
    await _actionQueueLock.synchronized(() {
      final now = DateTime.now();
      while (_actionQueue.isNotEmpty) {
        final item = _actionQueue.removeFirst();
        if (now.difference(item.timestamp) <= _actionStaleThreshold) {
          _actionStreamController.add(item.event);
        } else {
          debugPrint(
            '[NotificationService] Discarded stale action (${item.event}) older than 30s',
          );
        }
      }
    });
  }

  final Map<String, DateTime> _lastActionTimes = {};

  void _addAction(Map<String, String> event) {
    // FIX-32: Debounce duplicate rapid notification taps within 500ms
    final key = '${event['action']}_${event['taskId']}';
    final now = DateTime.now();
    final lastTime = _lastActionTimes[key];
    if (lastTime != null && now.difference(lastTime) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastActionTimes[key] = now;
    if (_lastActionTimes.length > 100) {
      _lastActionTimes.removeWhere((_, time) => now.difference(time) > const Duration(minutes: 5));
    }

    unawaited(_actionQueueLock.synchronized(() {
      final item = _BufferedNotificationAction(
        event: Map<String, String>.unmodifiable(event),
        timestamp: DateTime.now(),
      );

      if (_actionStreamController.hasListener) {
        final now = DateTime.now();
        while (_actionQueue.isNotEmpty) {
          final queued = _actionQueue.removeFirst();
          if (now.difference(queued.timestamp) <= _actionStaleThreshold) {
            _actionStreamController.add(queued.event);
          }
        }
        _actionStreamController.add(item.event);
      } else {
        _actionQueue.add(item);
        if (_actionQueue.length > _maxPendingActions) {
          _actionQueue.removeFirst();
        }
      }
    }).catchError((e) {
      debugPrint('[Notifications] Failed to add action to queue: $e');
    }));
  }

  @visibleForTesting
  void handleNotificationActionForTest(Map<String, String> event) {
    _addAction(event);
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
        await _clearPendingActions();
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
    stopPollingPendingActions();
    // FIX-02: Consolidate into TickManager
    TickManager.instance.registerTick(
      id: 'notification_service_poll',
      interval: BackgroundGate.adaptInterval(const Duration(seconds: 30)),
      priority: TickPriority.normal,
      callback: (_) {
        unawaited(processPendingBackgroundActions().catchError((e) => debugPrint(
            '[Notifications] Failed to process pending background actions: $e')));
      },
    );
  }

  void stopPollingPendingActions() {
    TickManager.instance.unregisterTick('notification_service_poll');
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> init({bool requestPermission = true}) async {
    if (!isSupported) return;
    if (_initFuture != null) {
      if (_receivePort != null &&
          IsolateNameServer.lookupPortByName('dmx_notification_port') != null) {
        unawaited(processPendingBackgroundActions().catchError((e) => debugPrint(
            '[Notifications] Failed to process pending background actions: $e')));
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
          unawaited(processPendingBackgroundActions().catchError((e) => debugPrint(
              '[Notifications] Failed to process pending background actions: $e')));
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
          unawaited(processPendingBackgroundActions().catchError((e) => debugPrint(
              '[Notifications] Failed to process pending background actions: $e')));
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
    final now = DateTime.now();
    final lastPost = _lastProgressPostTimes[notificationId];
    // FIX: Enforce minimum 1,000ms between calls per notification ID, 60,000ms in background
    final isBg = DownloadEngine.isInBackground || PowerMonitor.screenOff;
    final throttleMs = isBg ? 60000 : 1000;
    if (!isPaused &&
        lastPost != null &&
        now.difference(lastPost).inMilliseconds < throttleMs) {
      // Schedule trailing update if not already scheduled
      _trailingPostTimers[notificationId]?.cancel();
      _trailingPostTimers[notificationId] = Timer(
        Duration(
          milliseconds:
              (throttleMs - now.difference(lastPost).inMilliseconds) + 20,
        ),
        () {
          _trailingPostTimers.remove(notificationId);
          unawaited(
            showDownloadProgress(
              notificationId: notificationId,
              title: title,
              progressPercent: progressPercent,
              speed: speed,
              eta: eta,
              languageCode: languageCode,
              payload: payload,
              isPaused: isPaused,
              hasMultipleActive: hasMultipleActive,
              groupKey: groupKey,
            ),
          );
        },
      );
      return;
    }
    _trailingPostTimers[notificationId]?.cancel();
    _trailingPostTimers.remove(notificationId);
    _lastProgressPostTimes[notificationId] = now;
    // FIX-M5: Cap _lastProgressPostTimes at 100 entries
    if (_lastProgressPostTimes.length > 100) {
      final keysToRemove = _lastProgressPostTimes.keys
          .take(_lastProgressPostTimes.length - 100)
          .toList();
      for (final k in keysToRemove) {
        _lastProgressPostTimes.remove(k);
      }
    }
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
    final body = isPaused
        ? L10n.translate(languageCode, 'notification_paused')
        : (eta.isNotEmpty ? '$speed | $eta' : speed);

    if (showHookForTesting != null) {
      await showHookForTesting!(
        id: notificationId,
        title: title,
        body: body,
      );
      return;
    }

    await _plugin.show(
      id: notificationId,
      title: title,
      body: body,
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

  Future<void> showProgress({
    required int notificationId,
    required String title,
    required int progressPercent,
    String speed = '',
    String eta = '',
    String languageCode = 'en',
    String payload = '',
  }) =>
      showDownloadProgress(
        notificationId: notificationId,
        title: title,
        progressPercent: progressPercent,
        speed: speed,
        eta: eta,
        languageCode: languageCode,
        payload: payload,
      );

  Future<void> cancelNotification(int notificationId) async {
    _lastProgressPostTimes.remove(notificationId);
    _trailingPostTimers[notificationId]?.cancel();
    _trailingPostTimers.remove(notificationId);
    if (!_initialized) return;
    await _plugin.cancel(id: notificationId);
  }

  Future<void> cancelAll() async {
    _lastProgressPostTimes.clear();
    for (final timer in _trailingPostTimers.values) {
      timer.cancel();
    }
    _trailingPostTimers.clear();
    if (!_initialized) return;
    await _plugin.cancelAll();
  }

  Future<void> dispose() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    for (final timer in _trailingPostTimers.values) {
      timer.cancel();
    }
    _trailingPostTimers.clear();
    await _receivePortSub?.cancel();
    _receivePortSub = null;
    _receivePort?.close();
    _receivePort = null;
    IsolateNameServer.removePortNameMapping('dmx_notification_port');
    if (!_actionStreamController.isClosed) {
      _actionStreamController.close();
    }
    await _actionQueueLock.synchronized(() {
      _actionQueue.clear();
    });
  }
}

class _BufferedNotificationAction {
  const _BufferedNotificationAction({
    required this.event,
    required this.timestamp,
  });

  final Map<String, String> event;
  final DateTime timestamp;
}
