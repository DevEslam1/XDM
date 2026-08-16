import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dmx/core/services/logging_service.dart';
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_filex/open_filex.dart' as open_filex;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

import '../../../core/services/background_service.dart';
import '../../../core/services/download_engine.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/power_monitor.dart';
import '../../../core/utils/file_utils.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';

/// Translates download events into user-facing notifications.
///
/// Extracted from [DownloadProvider] (Refactor A). Owns the per-task
/// notification ID mapping, the notification action subscription, and all
/// [NotificationService] / background-service notification calls. Task
/// actions triggered from a notification are routed back into the provider
/// through the constructor callbacks.
class NotificationCoordinator {
  NotificationCoordinator({
    required NotificationService notificationService,
    required SettingsProvider settingsProvider,
    required int Function() downloadingTasksCount,
    required double Function() currentDownloadSpeed,
    required DownloadTask? Function(String id) findTask,
    required Future<void> Function(String taskId) onPauseTask,
    required Future<void> Function(String taskId) onResumeTask,
    required Future<void> Function(String taskId) onCancelTask,
    required Future<void> Function() onPauseAll,
    required Future<void> Function() onResumeAll,
    required Future<void> Function() onStopAll,
    required Future<void> Function() onStartAll,
    required Future<void> Function() onExitApp,
  })  : _notificationService = notificationService,
        _settingsProvider = settingsProvider,
        _downloadingTasksCount = downloadingTasksCount,
        _currentDownloadSpeed = currentDownloadSpeed,
        _findTask = findTask,
        _onPauseTask = onPauseTask,
        _onResumeTask = onResumeTask,
        _onCancelTask = onCancelTask,
        _onPauseAll = onPauseAll,
        _onResumeAll = onResumeAll,
        _onStopAll = onStopAll,
        _onStartAll = onStartAll,
        _onExitApp = onExitApp;

  final NotificationService _notificationService;
  final SettingsProvider _settingsProvider;
  final int Function() _downloadingTasksCount;
  final double Function() _currentDownloadSpeed;
  final DownloadTask? Function(String id) _findTask;
  final Future<void> Function(String taskId) _onPauseTask;
  final Future<void> Function(String taskId) _onResumeTask;
  final Future<void> Function(String taskId) _onCancelTask;
  final Future<void> Function() _onPauseAll;
  final Future<void> Function() _onResumeAll;
  final Future<void> Function() _onStopAll;
  final Future<void> Function() _onStartAll;
  final Future<void> Function() _onExitApp;

  StreamSubscription<Map<String, String>>? _actionSubscription;
  final Map<String, int> _notificationIds = {};
  final Map<int, DateTime> _lastProgressPostTimes = {};
  int _nextNotificationId = 1;

  // Android notification grouping: all per-task progress notifications share
  // this group key and collapse under one summary entry.
  static const String _groupKey = 'dmx_downloads';
  static const int _groupSummaryId = 9001;
  DateTime _lastSummaryPost = DateTime.fromMillisecondsSinceEpoch(0);

  // ignore: prefer_collection_literals
  final Map<String, String> _opaqueHandles = LinkedHashMap<String, String>();
  final Map<String, String> _taskToHandle = {};
  final Lock _handlesLock = Lock();
  // Notification actions may wake a killed Android process before the async
  // handle map has finished loading. Keep the action path behind this future
  // so a valid pause/cancel action is not dropped during cold start.
  Future<void>? _handlesLoadFuture;

  static const String _handleMapKey = 'dmx_opaque_handle_map';

  Future<void> _loadPersistedHandles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_handleMapKey);
      if (raw != null) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        await _handlesLock.synchronized(() {
          _opaqueHandles.clear();
          _taskToHandle.clear();
          map.forEach((handle, taskId) {
            if (taskId is String) {
              _opaqueHandles[handle] = taskId;
              _taskToHandle[taskId] = handle;
            }
          });
          while (_opaqueHandles.length > 30) {
            final firstKey = _opaqueHandles.keys.first;
            _opaqueHandles.remove(firstKey);
          }
        });
      }
    } catch (e) {
      debugPrint('[NotificationCoordinator] Failed to load handle map: $e');
    }
  }

  Future<void> _persistHandles() async {
    try {
      final String payload = await _handlesLock.synchronized(() {
        return jsonEncode(_opaqueHandles);
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_handleMapKey, payload);
    } catch (e) {
      debugPrint('[NotificationCoordinator] Failed to persist handle map: $e');
    }
  }

  /// Issues an opaque handle for [taskId] to embed in a notification payload.
  ///
  /// FIX: We bypass the opaque handle mapping and return the real task ID.
  /// The task ID is already strictly validated via `_isValidTaskId` in
  /// `NotificationService`, which prevents injection attacks.
  /// This ensures that actions survive cold starts even if the persisted
  /// handle map is lost or corrupted.
  String opaqueHandleFor(String taskId) {
    return taskId;
  }

  Future<String?> _resolveOpaqueHandle(String? handle) async {
    if (handle == null) return null;
    final resolved = await _handlesLock.synchronized(() {
      final res = _opaqueHandles[handle];
      if (res != null) {
        // Move to end on access (LRU)
        _opaqueHandles.remove(handle);
        _opaqueHandles[handle] = res;
      }
      return res;
    });
    if (resolved != null) return resolved;
    if (_findTask(handle) != null) return handle;
    return null;
  }

  void init() {
    _nextNotificationId =
        (DateTime.now().millisecondsSinceEpoch % 10000) + 1000;
    _handlesLoadFuture ??= _loadPersistedHandles();
    _actionSubscription?.cancel();
    _actionSubscription = _notificationService.onActionTapped.listen(
      _handleNotificationAction,
    );
  }

  /// Allocates (or reuses) the notification ID for [taskId].
  int idFor(String taskId) {
    return _notificationIds.putIfAbsent(taskId, () => _nextNotificationId++);
  }

  /// Cancels the task's lingering progress notification, if any.
  void cancelForTask(String taskId) {
    final notifId = _notificationIds.remove(taskId);
    if (notifId != null) {
      unawaited(
        _notificationService.cancelNotification(notifId).catchError((e) {
          LoggingService.logger('NotificationCoordinator').info(
            '[NotificationCoordinator] cancel notification failed: $e',
          );
        }),
      );
    }
    unawaited(_handlesLock
        .synchronized(() {
          final handle = _taskToHandle.remove(taskId);
          if (handle != null) {
            _opaqueHandles.remove(handle);
          }
        })
        .then((_) => _persistHandles())
        .catchError(
            (e) => debugPrint('[Notifications] persistHandles failed: $e')));
  }

  /// Drops the ID mapping for [taskId] and returns the removed ID (used by
  /// delete flows that cancel the notification after file cleanup).
  int? removeId(String taskId) {
    unawaited(_handlesLock
        .synchronized(() {
          final handle = _taskToHandle.remove(taskId);
          if (handle != null) {
            _opaqueHandles.remove(handle);
          }
        })
        .then((_) => _persistHandles())
        .catchError((e) => debugPrint('[DMX] persistHandles failed: $e')));
    return _notificationIds.remove(taskId);
  }

  void cancelNotification(int notificationId) {
    _notificationService.cancelNotification(notificationId);
  }

  /// FIX(14): Cancels the group summary notification.
  void cancelGroupSummary() {
    _notificationService.cancelNotification(_groupSummaryId);
  }

  Future<void> cancelAll() => _notificationService.cancelAll();

  bool _isValidTaskId(String id) {
    if (id.isEmpty || id.length > 128) return false;
    return RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id);
  }

  final Map<String, DateTime> _lastNotifActionTime = {};

  Future<void> _handleNotificationAction(Map<String, String> event) async {
    await _handlesLoadFuture;

    final action = event['action'];
    final rawHandle = event['taskId'];
    if (action == null) return;

    // Retry resolving the handle in case the task provider hasn't finished loading
    String? taskId;
    for (int i = 0; i < 5; i++) {
      taskId = await _resolveOpaqueHandle(rawHandle);
      if (taskId != null) break;
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // If still null, but rawHandle is a valid task ID, proceed anyway.
    if (taskId == null && rawHandle != null && _isValidTaskId(rawHandle)) {
      taskId = rawHandle;
    }

    if (taskId != null) {
      final task = _findTask(taskId);
      if (task == null &&
          (action == 'pause' || action == 'resume' || action == 'cancel')) {
        debugPrint(
            '[Notifications] Task $taskId not found, ignoring action $action');
        return;
      }
    }

    if (taskId != null &&
        (action == 'pause' || action == 'resume' || action == 'cancel')) {
      final key = '$taskId:$action';
      final lastTime = _lastNotifActionTime[key];
      final now = DateTime.now();
      if (lastTime != null &&
          now.difference(lastTime) < const Duration(milliseconds: 500)) {
        debugPrint(
            '[NotificationCoordinator] Ignored duplicate $action for $taskId');
        return;
      }
      _lastNotifActionTime[key] = now;
    }

    try {
      switch (action) {
        case 'pause':
          if (taskId != null) await _onPauseTask(taskId);
          break;
        case 'resume':
          if (taskId != null) await _onResumeTask(taskId);
          break;
        case 'cancel':
          if (taskId != null) await _onCancelTask(taskId);
          break;
        case 'pause_all':
          await _onPauseAll();
          break;
        case 'resume_all':
          await _onResumeAll();
          break;
        case 'stop_all':
          await _onStopAll();
          break;
        case 'start_all':
          await _onStartAll();
          break;
        case 'exit_app':
          await _onExitApp();
          break;
        case 'install_apk':
        case 'tap':
          if (taskId != null) {
            final task = _findTask(taskId);
            if (task != null && task.status == DownloadStatus.completed) {
              open_filex.OpenFilex.open(task.localFilePath);
            }
          }
          break;
      }
    } catch (e, st) {
      LoggingService.logger('NotificationCoordinator').warning(
        '[NotificationCoordinator] Failed to handle notification action "$action" '
        'for task $taskId: $e',
        e,
        st,
      );
    }
  }

  /// Shows the completion notification for [task] (app updates get an
  /// install action). No-op when notifications are disabled. During quiet
  /// hours the notification is delivered silently (no sound / no alert).
  void showComplete(DownloadTask task, int notificationId) {
    if (!_settingsProvider.notificationsEnabled) return;
    final quietHours = _settingsProvider.isInQuietHoursNow();
    if (task.isAppUpdate) {
      _notificationService.showDownloadComplete(
        notificationId: notificationId,
        title: 'Update ready',
        body: 'App update ${task.fileName} downloaded. Tap to install.',
        playSound: _settingsProvider.soundNotification && !quietHours,
        payload: opaqueHandleFor(task.id),
        actions: [
          AndroidNotificationAction(
            'install_apk:${opaqueHandleFor(task.id)}',
            'Install',
            showsUserInterface: true,
          ),
        ],
      );
    } else {
      _notificationService.showDownloadComplete(
        notificationId: notificationId,
        title: task.fileName,
        playSound: _settingsProvider.soundNotification && !quietHours,
        payload: opaqueHandleFor(task.id),
      );
    }
  }

  /// SCHED-FIX-5: Shows notification when a scheduled download starts.
  void showScheduledStarted(String taskName, DateTime scheduledAt) {
    if (!_settingsProvider.notificationsEnabled) return;
    final quietHours = _settingsProvider.isInQuietHoursNow();
    // Allocate from the same monotonic sequence as [idFor] so this ID can
    // never collide with a task's notification or with another scheduled
    // download (a time-derived `% 1000` collided for downloads scheduled at
    // the same instant).
    final id = _nextNotificationId++;
    final local = scheduledAt.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    _notificationService.showDownloadComplete(
      notificationId: id,
      title: 'Scheduled download started',
      body: '$taskName (scheduled for $hour:$minute)',
      playSound: _settingsProvider.soundNotification && !quietHours,
    );
  }

  /// Updates the per-task progress notification. No-op when notifications
  /// are disabled. Multiple active downloads are grouped under one summary.
  void showProgress({
    required int notificationId,
    required String title,
    required int progressPercent,
    required String speed,
    required String eta,
    required String payload,
    bool isPaused = false,
  }) {
    if (!_settingsProvider.notificationsEnabled) return;

    final now = DateTime.now();
    final lastPost = _lastProgressPostTimes[notificationId];
    final minIntervalMs = PowerMonitor.screenOff
        ? 30000
        : (DownloadEngine.isInBackground
            ? 10000
            : (_settingsProvider.batterySaverMode ? 5000 : 1000));
    if (!isPaused &&
        progressPercent < 100 &&
        lastPost != null &&
        now.difference(lastPost).inMilliseconds < minIntervalMs) {
      return;
    }
    _lastProgressPostTimes[notificationId] = now;

    final activeCount = _downloadingTasksCount();
    final multiple = activeCount > 1;
    _notificationService.showDownloadProgress(
      notificationId: notificationId,
      title: title,
      progressPercent: progressPercent,
      speed: speed,
      eta: eta,
      languageCode: _settingsProvider.languageCode,
      payload: payload,
      isPaused: isPaused,
      hasMultipleActive: multiple,
      groupKey:
          _groupKey, // FIX(14): always use group key for consistent threadIdentifier
    );
    if (multiple) {
      _postGroupSummary(activeCount);
    } else {
      cancelGroupSummary(); // FIX(14): only one active, no summary needed
    }
  }

  /// Refreshes the collapsed group summary at most once every 3 seconds (30s when screen OFF).
  void _postGroupSummary(int activeCount) {
    final now = DateTime.now();
    final summaryInterval = PowerMonitor.screenOff ? 30 : 3;
    if (now.difference(_lastSummaryPost) < Duration(seconds: summaryInterval)) {
      return;
    }
    _lastSummaryPost = now;
    unawaited(
      _notificationService
          .showGroupSummary(
        notificationId: _groupSummaryId,
        activeCount: activeCount,
        groupKey: _groupKey,
      )
          .catchError((Object e) {
        debugPrint('[Notifications] Group summary failed: $e');
      }),
    );
  }

  /// Shows the failure notification. No-op when notifications are disabled.
  /// During quiet hours the notification is delivered silently.
  void showFailed({
    required int notificationId,
    required String title,
    required String error,
  }) {
    if (!_settingsProvider.notificationsEnabled) return;
    final quietHours = _settingsProvider.isInQuietHoursNow();
    _notificationService.showDownloadFailed(
      notificationId: notificationId,
      title: title,
      error: error,
      playSound: _settingsProvider.soundNotification && !quietHours,
    );
  }

  /// Refreshes the persistent background-service notification with
  /// Stop All / Start All / Exit App action buttons.
  void updateBackgroundNotification() {
    if (!_settingsProvider.notificationsEnabled) {
      _notificationService.cancelNotification(888); // Cancel service notif
      return;
    }
    final active = _downloadingTasksCount();
    final speed = _currentDownloadSpeed();
    final title = active > 0 ? 'XDM - $active active' : 'XDM';
    final content = active > 0
        ? '${formatBytes(speed)}/s  •  Tap to open'
        : 'Ready — tap to open';
    unawaited(
      _notificationService
          .showServiceNotification(title: title, content: content)
          .catchError((e) {
        debugPrint('[DMX] showServiceNotification failed: $e');
        // Fallback to plain background-service notification if flutter_local_notifications
        // fails (e.g. on first launch before permissions granted).
        BackgroundService.updateNotification(title: title, content: content);
      }),
    );
  }

  void cleanupTask(String taskId) {
    final notifId = _notificationIds.remove(taskId);
    if (notifId != null) {
      _lastProgressPostTimes.remove(notifId);
      unawaited(
          _notificationService.cancelNotification(notifId).catchError((_) {}));
    }
    unawaited(_handlesLock
        .synchronized(() {
          final handle = _taskToHandle.remove(taskId);
          if (handle != null) {
            _opaqueHandles.remove(handle);
          }
        })
        .then((_) => _persistHandles())
        .catchError(
            (e) => debugPrint('[Notifications] persistHandles failed: $e')));
  }

  void dispose() {
    _actionSubscription?.cancel();
    _actionSubscription = null;
    _notificationIds.clear();
    _lastProgressPostTimes.clear();
    _handlesLock.synchronized(() {
      _opaqueHandles.clear();
      _taskToHandle.clear();
    });
    _notificationService.stopPollingPendingActions();
  }
}
