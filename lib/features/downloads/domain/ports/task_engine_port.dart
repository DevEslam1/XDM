/// Pure-Dart interface for download engine execution delegates.
abstract class TaskEnginePort {
  /// Starts or resumes download execution for [taskId].
  Future<void> startEngineTask(String taskId, {bool ignoreQueueLimit = false});

  /// Pauses active download execution for [taskId].
  Future<void> pauseEngineTask(String taskId,
      {String? reason, bool userInitiated = true});

  /// Cancels active download execution for [taskId].
  Future<void> cancelEngineTask(String taskId, {bool deleteFiles = false});

  /// Retries a failed or stalled download execution for [taskId].
  Future<void> retryEngineTask(String taskId);

  /// Cleans up resources or files for a deleted task.
  Future<void> deleteEngineTask(String taskId, {bool deleteFiles = false});

  /// Evaluates queue and admits queued tasks up to active limit.
  Future<void> pumpQueue();

  /// Handles network state changes across active engine tasks.
  Future<void> handleNetworkChanged(
      {required bool isConnected, required bool isWifi});

  /// Handles app lifecycle state changes.
  Future<void> handleAppLifecycleChanged(dynamic state);

  /// Handles periodic torrent stats.
  Future<void> handleTorrentStats(String taskId, dynamic stats);
}
