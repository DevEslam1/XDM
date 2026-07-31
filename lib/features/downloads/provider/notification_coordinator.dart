import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_filex/open_filex.dart' as open_filex;

import '../../../core/services/background_service.dart';
import '../../../core/services/notification_service.dart';
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
    required void Function(String taskId) onPauseTask,
    required void Function(String taskId) onResumeTask,
    required void Function(String taskId) onCancelTask,
    required void Function() onPauseAll,
    required void Function() onResumeAll,
  }) : _notificationService = notificationService,
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

  void init() {
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
        _notificationService.cancelNotification(notifId).catchError((e) {}),
      );
    }
  }

  /// Drops the ID mapping for [taskId] and returns the removed ID (used by
  /// delete flows that cancel the notification after file cleanup).
  int? removeId(String taskId) {
    return _notificationIds.remove(taskId);
  }

  void cancelNotification(int notificationId) {
    _notificationService.cancelNotification(notificationId);
  }

  Future<void> cancelAll() => _notificationService.cancelAll();

  void _handleNotificationAction(Map<String, String> event) {
    final action = event['action'];
    final taskId = event['taskId'];
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
  /// install action). No-op when notifications are disabled.
  void showComplete(DownloadTask task, int notificationId) {
    if (!_settingsProvider.notificationsEnabled) return;
    if (task.isAppUpdate) {
      _notificationService.showDownloadComplete(
        notificationId: notificationId,
        title: 'Update ready',
        body: 'App update ${task.fileName} downloaded. Tap to install.',
        playSound: _settingsProvider.soundNotification,
        payload: task.id,
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
        playSound: _settingsProvider.soundNotification,
      );
    }
  }

  /// Updates the per-task progress notification. No-op when notifications
  /// are disabled.
  void showProgress({
    required int notificationId,
    required String title,
    required int progressPercent,
    required String speed,
    required String eta,
    required String payload,
  }) {
    if (!_settingsProvider.notificationsEnabled) return;
    _notificationService.showDownloadProgress(
      notificationId: notificationId,
      title: title,
      progressPercent: progressPercent,
      speed: speed,
      eta: eta,
      languageCode: _settingsProvider.languageCode,
      payload: payload,
      hasMultipleActive: _downloadingTasksCount() > 1,
    );
  }

  /// Shows the failure notification. No-op when notifications are disabled.
  void showFailed({
    required int notificationId,
    required String title,
    required String error,
  }) {
    if (!_settingsProvider.notificationsEnabled) return;
    _notificationService.showDownloadFailed(
      notificationId: notificationId,
      title: title,
      error: error,
      playSound: _settingsProvider.soundNotification,
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
  }
}
