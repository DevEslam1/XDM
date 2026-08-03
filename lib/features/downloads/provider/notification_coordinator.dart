import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_filex/open_filex.dart' as open_filex;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/background_service.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';
import 'package:dmx/core/services/logging_service.dart';

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
    required void Function(String taskId) onPauseTask,
    required void Function(String taskId) onResumeTask,
    required void Function(String taskId) onCancelTask,
    required void Function() onPauseAll,
    required void Function() onResumeAll,
  })  : _notificationService = notificationService,
        _settingsProvider = settingsProvider,
        _downloadingTasksCount = downloadingTasksCount,
        _currentDownloadSpeed = currentDownloadSpeed,
        _findTask = findTask,
        _onPauseTask = onPauseTask,
        _onResumeTask = onResumeTask,
        _onCancelTask = onCancelTask,
        _onPauseAll = onPauseAll,
        _onResumeAll = onResumeAll;

  final NotificationService _notificationService;
  final SettingsProvider _settingsProvider;
  final int Function() _downloadingTasksCount;
  final double Function() _currentDownloadSpeed;
  final DownloadTask? Function(String id) _findTask;
  final void Function(String taskId) _onPauseTask;
  final void Function(String taskId) _onResumeTask;
  final void Function(String taskId) _onCancelTask;
  final void Function() _onPauseAll;
  final void Function() _onResumeAll;

  StreamSubscription<Map<String, String>>? _actionSubscription;
  final Map<String, int> _notificationIds = {};
  int _nextNotificationId = 1;

  // Android notification grouping: all per-task progress notifications share
  // this group key and collapse under one summary entry.
  static const String _groupKey = 'dmx_downloads';
  static const int _groupSummaryId = 9001;
  DateTime _lastSummaryPost = DateTime.fromMillisecondsSinceEpoch(0);

  // ignore: prefer_collection_literals
  final Map<String, String> _opaqueHandles = LinkedHashMap<String, String>();
  final Map<String, String> _taskToHandle = {};
  // Notification actions may wake a killed Android process before the async
  // handle map has finished loading. Keep the action path behind this future
  // so a valid pause/cancel action is not dropped during cold start.
  Future<void>? _handlesLoadFuture;
  static final Random _handleRandom = Random.secure();
  static const int _maxOpaqueHandles = 512;
  static const String _handleMapKey = 'dmx_opaque_handle_map';

  Future<void> _loadPersistedHandles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_handleMapKey);
      if (raw != null) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _opaqueHandles.clear();
        _taskToHandle.clear();
        map.forEach((handle, taskId) {
          if (taskId is String) {
            _opaqueHandles[handle] = taskId;
            _taskToHandle[taskId] = handle;
          }
        });
      }
    } catch (e) {
      debugPrint('[NotificationCoordinator] Failed to load handle map: $e');
    }
  }

  Future<void> _persistHandles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_handleMapKey, jsonEncode(_opaqueHandles));
    } catch (e) {
      debugPrint('[NotificationCoordinator] Failed to persist handle map: $e');
    }
  }

  /// Issues an opaque handle for [taskId] to embed in a notification payload.
  /// Safe to call repeatedly; returns the stable handle if it exists.
  String opaqueHandleFor(String taskId) {
    final existing = _taskToHandle[taskId];
    if (existing != null) {
      // Move to end (most recently used)
      _opaqueHandles.remove(existing);
      _opaqueHandles[existing] = taskId;
      return existing;
    }

    final handle = 't${_handleRandom.nextInt(1 << 31).toRadixString(16)}'
        '${_handleRandom.nextInt(1 << 31).toRadixString(16)}';
    _opaqueHandles[handle] = taskId;
    _taskToHandle[taskId] = handle;
    if (_opaqueHandles.length > _maxOpaqueHandles) {
      final oldestHandle = _opaqueHandles.keys.first; // Now LRU
      final oldestTaskId = _opaqueHandles[oldestHandle];
      _opaqueHandles.remove(oldestHandle);
      if (oldestTaskId != null) {
        _taskToHandle.remove(oldestTaskId);
      }
    }
    unawaited(_persistHandles());
    return handle;
  }

  String? _resolveOpaqueHandle(String? handle) {
    if (handle == null) return null;
    final resolved = _opaqueHandles[handle];
    if (resolved != null) {
      // Move to end on access (LRU)
      _opaqueHandles.remove(handle);
      _opaqueHandles[handle] = resolved;
      return resolved;
    }
    if (_findTask(handle) != null) return handle;
    return null;
  }

  void init() {
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
    final notifId = _notificationIds[taskId];
    if (notifId != null) {
      unawaited(
        _notificationService.cancelNotification(notifId).catchError((e) {
          LoggingService.logger('NotificationCoordinator').info(
            '[NotificationCoordinator] cancel notification failed: $e',
          );
        }),
      );
    }
  }

  /// Drops the ID mapping for [taskId] and returns the removed ID (used by
  /// delete flows that cancel the notification after file cleanup).
  int? removeId(String taskId) {
    final handle = _taskToHandle.remove(taskId);
    if (handle != null) {
      _opaqueHandles.remove(handle);
      unawaited(_persistHandles());
    }
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

  Future<void> _handleNotificationAction(Map<String, String> event) async {
    // On Android/ColorOS this is commonly a cold-start path: the notification
    // callback is replayed immediately while the provider is still loading.
    // Awaiting the map restore makes opaque handles resolvable after process
    // death instead of silently ignoring the user's action.
    await _handlesLoadFuture;

    final action = event['action'];
    // FIX(18): the payload is an opaque handle; resolve it to the real task
    // id. Unknown/unresolvable handles are ignored (e.g. after restart).
    final taskId = _resolveOpaqueHandle(event['taskId']);
    if (action == null) return;

    switch (action) {
      case 'pause':
        if (taskId != null) _onPauseTask(taskId);
        break;
      case 'resume':
        if (taskId != null) _onResumeTask(taskId);
        break;
      case 'cancel':
        if (taskId != null) _onCancelTask(taskId);
        break;
      case 'pause_all':
        _onPauseAll();
        break;
      case 'resume_all':
        _onResumeAll();
        break;
      case 'install_apk':
      case 'tap':
        if (taskId != null) {
          final task = _findTask(taskId);
          if (task != null &&
              task.isAppUpdate &&
              task.status == DownloadStatus.completed) {
            open_filex.OpenFilex.open(task.localFilePath);
          }
        }
        break;
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
        actions: const [
          AndroidNotificationAction(
            'install_apk',
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
      );
    }
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
  }) {
    if (!_settingsProvider.notificationsEnabled) return;
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
      hasMultipleActive: multiple,
      groupKey: _groupKey, // FIX(14): always use group key for consistent threadIdentifier
    );
    if (multiple) {
      _postGroupSummary(activeCount);
    } else {
      cancelGroupSummary(); // FIX(14): only one active, no summary needed
    }
  }

  /// Refreshes the collapsed group summary at most once every 3 seconds.
  void _postGroupSummary(int activeCount) {
    final now = DateTime.now();
    if (now.difference(_lastSummaryPost) < const Duration(seconds: 3)) return;
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

  /// Refreshes the persistent background-service notification.
  void updateBackgroundNotification() {
    final active = _downloadingTasksCount();
    if (active > 0) {
      BackgroundService.updateNotification(
        title: 'XDM - $active active',
        content: '${formatBytes(_currentDownloadSpeed())}/s',
      );
    }
  }

  void dispose() {
    _actionSubscription?.cancel();
    _notificationIds.clear();
    _notificationService.stopPollingPendingActions();
  }
}
