import 'package:meta/meta.dart';
import '../commands/download_commands.dart';

/// Classified typed error codes emitted by engines when a task fails.
enum DomainErrorCode {
  networkError,
  serverError,
  authError,
  diskFull,
  integrityError,
  fileChanged,
  mergeFailed,
  torrentError,
  cancelled,
  unrecoverable,
  unknown,
}

/// Base sealed class for all events emitted by engines and domain executors.
@immutable
sealed class DownloadEvent {
  const DownloadEvent();
}

/// Event emitted when engine successfully initiates downloading for a task.
final class TaskStarted extends DownloadEvent {
  final String taskId;
  final DateTime timestamp;

  TaskStarted({
    required this.taskId,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() => 'TaskStarted(taskId: $taskId, timestamp: $timestamp)';
}

/// Event emitted when progress is made during a task download.
final class TaskProgressed extends DownloadEvent {
  final String taskId;
  final int downloadedBytes;
  final int totalBytes;
  final double speed;
  final int? eta;
  final List<double>? chunks;
  final String? statusMessage;
  final DateTime timestamp;

  TaskProgressed({
    required this.taskId,
    required this.downloadedBytes,
    required this.totalBytes,
    this.speed = 0.0,
    this.eta,
    this.chunks,
    this.statusMessage,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      'TaskProgressed(taskId: $taskId, downloaded: $downloadedBytes/$totalBytes, speed: $speed)';
}

/// Event emitted when engine confirms that a task has paused.
final class TaskPausedConfirmed extends DownloadEvent {
  final String taskId;
  final String? reason;
  final bool userInitiated;
  final DateTime timestamp;

  TaskPausedConfirmed({
    required this.taskId,
    this.reason,
    this.userInitiated = true,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      'TaskPausedConfirmed(taskId: $taskId, reason: $reason, userInitiated: $userInitiated)';
}

/// Event emitted when a task fails with a typed classified error.
final class TaskFailed extends DownloadEvent {
  final String taskId;
  final DomainErrorCode errorCode;
  final String? message;
  final String? recoveryHint;
  final bool isUnrecoverable;
  final DateTime timestamp;

  TaskFailed({
    required this.taskId,
    required this.errorCode,
    this.message,
    this.recoveryHint,
    this.isUnrecoverable = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      'TaskFailed(taskId: $taskId, errorCode: $errorCode, message: $message)';
}

/// Event emitted when a task successfully completes downloading (and merging).
final class TaskCompleted extends DownloadEvent {
  final String taskId;
  final int finalSize;
  final DateTime timestamp;

  TaskCompleted({
    required this.taskId,
    required this.finalSize,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      'TaskCompleted(taskId: $taskId, finalSize: $finalSize)';
}

/// Event emitted when a command is rejected by validation or state rules.
final class TaskRejected extends DownloadEvent {
  final DownloadCommand command;
  final String reason;
  final DateTime timestamp;

  TaskRejected({
    required this.command,
    required this.reason,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      'TaskRejected(command: $command, reason: $reason)';
}

/// Event emitted when a task is admitted or enqueued.
final class TaskEnqueued extends DownloadEvent {
  final String taskId;
  final int queueOrder;
  final DateTime timestamp;

  TaskEnqueued({
    required this.taskId,
    this.queueOrder = 0,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() => 'TaskEnqueued(taskId: $taskId, queueOrder: $queueOrder)';
}

/// Event emitted when a task moves into merging phase.
final class TaskMerging extends DownloadEvent {
  final String taskId;
  final DateTime timestamp;

  TaskMerging({
    required this.taskId,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() => 'TaskMerging(taskId: $taskId)';
}

/// Event emitted when a task is removed/deleted from domain state.
final class TaskDeleted extends DownloadEvent {
  final String taskId;
  final bool filesDeleted;
  final DateTime timestamp;

  TaskDeleted({
    required this.taskId,
    this.filesDeleted = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      'TaskDeleted(taskId: $taskId, filesDeleted: $filesDeleted)';
}
