import '../models/download_task.dart';
import '../provider/notification_coordinator.dart';

/// Service responsible for managing user-visible OS notifications for active,
/// completed, and failed downloads across Android, iOS, and Desktop.
class DownloadNotificationBridge {
  final NotificationCoordinator _coordinator;

  DownloadNotificationBridge({required NotificationCoordinator coordinator})
      : _coordinator = coordinator;

  NotificationCoordinator get coordinator => _coordinator;

  int idFor(String taskId) => _coordinator.idFor(taskId);

  /// Shows or updates the ongoing notification for active downloads.
  void showProgress({
    required int notificationId,
    required String title,
    required int progressPercent,
    required String speed,
    required String eta,
    required String payload,
    bool isPaused = false,
  }) {
    _coordinator.showProgress(
      notificationId: notificationId,
      title: title,
      progressPercent: progressPercent,
      speed: speed,
      eta: eta,
      payload: payload,
      isPaused: isPaused,
    );
  }

  /// Shows the completion notification for a downloaded task.
  void showComplete(DownloadTask task, int notificationId) {
    _coordinator.showComplete(task, notificationId);
  }

  /// Cancels notifications associated with the specified task.
  void cancelForTask(String taskId) {
    _coordinator.cancelForTask(taskId);
  }

  /// Cancels all active download notifications.
  void cancelAll() {
    _coordinator.cancelAll();
  }
}
