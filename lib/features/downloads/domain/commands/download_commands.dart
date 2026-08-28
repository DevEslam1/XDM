/// Base class for all commands processed by the downloads domain subsystem.
sealed class DownloadCommand {
  const DownloadCommand();
}

/// Commands targeted at a specific download task actor.
sealed class TaskCommand extends DownloadCommand {
  final String id;
  const TaskCommand(this.id);
}

/// System-wide / global commands that may route to multiple tasks.
sealed class GlobalCommand extends DownloadCommand {
  const GlobalCommand();
}

/// Command to start or admit a task into the downloading state.
final class StartTask extends TaskCommand {
  final bool ignoreQueueLimit;
  const StartTask(super.id, {this.ignoreQueueLimit = false});

  @override
  String toString() =>
      'StartTask(id: $id, ignoreQueueLimit: $ignoreQueueLimit)';
}

/// Command to pause an active task.
final class PauseTask extends TaskCommand {
  final String? reason;
  final bool userInitiated;
  const PauseTask(super.id, {this.reason, this.userInitiated = true});

  @override
  String toString() =>
      'PauseTask(id: $id, reason: $reason, userInitiated: $userInitiated)';
}

/// Command to resume a paused task.
final class ResumeTask extends TaskCommand {
  final bool userInitiated;
  const ResumeTask(super.id, {this.userInitiated = true});

  @override
  String toString() => 'ResumeTask(id: $id, userInitiated: $userInitiated)';
}

/// Command to cancel an active/queued task.
final class CancelTask extends TaskCommand {
  final bool deleteFiles;
  const CancelTask(super.id, {this.deleteFiles = false});

  @override
  String toString() => 'CancelTask(id: $id, deleteFiles: $deleteFiles)';
}

/// Command to delete a task record and optionally its downloaded files.
final class DeleteTask extends TaskCommand {
  final bool deleteFiles;
  const DeleteTask(super.id, {this.deleteFiles = false});

  @override
  String toString() => 'DeleteTask(id: $id, deleteFiles: $deleteFiles)';
}

/// Command to retry a failed or stalled task.
final class RetryTask extends TaskCommand {
  const RetryTask(super.id);

  @override
  String toString() => 'RetryTask(id: $id)';
}

/// Command triggered when a scheduled time has arrived for a task.
final class ScheduleFired extends TaskCommand {
  const ScheduleFired(super.id);

  @override
  String toString() => 'ScheduleFired(id: $id)';
}

/// Command delivering periodic statistics from the torrent engine for a task.
final class TorrentStatsTick extends TaskCommand {
  final dynamic stats;
  const TorrentStatsTick(super.id, {required this.stats});

  @override
  String toString() => 'TorrentStatsTick(id: $id, stats: $stats)';
}

/// Command to update task target download URL (e.g. expired YouTube streams).
final class UpdateTaskUrl extends TaskCommand {
  final String newUrl;
  final String? newAudioUrl;
  const UpdateTaskUrl(super.id, {required this.newUrl, this.newAudioUrl});

  @override
  String toString() =>
      'UpdateTaskUrl(id: $id, newUrl: $newUrl, newAudioUrl: $newAudioUrl)';
}

/// Command to change task priority.
final class SetTaskPriority extends TaskCommand {
  final int priority;
  const SetTaskPriority(super.id, {required this.priority});

  @override
  String toString() => 'SetTaskPriority(id: $id, priority: $priority)';
}

/// Global command to evaluate the download queue and start eligible tasks.
final class QueuePump extends GlobalCommand {
  const QueuePump();

  @override
  String toString() => 'QueuePump()';
}

/// Global command emitted when network connectivity changes.
final class NetworkChanged extends GlobalCommand {
  final dynamic state;
  final bool isConnected;
  final bool isWifi;
  const NetworkChanged({
    this.state,
    this.isConnected = true,
    this.isWifi = false,
  });

  @override
  String toString() =>
      'NetworkChanged(isConnected: $isConnected, isWifi: $isWifi, state: $state)';
}

/// Global command emitted when application lifecycle state changes.
final class AppLifecycleChanged extends GlobalCommand {
  final dynamic state;
  const AppLifecycleChanged(this.state);

  @override
  String toString() => 'AppLifecycleChanged(state: $state)';
}

/// Global command to reorder queued tasks.
final class ReorderQueue extends GlobalCommand {
  final List<String> taskIds;
  const ReorderQueue(this.taskIds);

  @override
  String toString() => 'ReorderQueue(taskIds: $taskIds)';
}
