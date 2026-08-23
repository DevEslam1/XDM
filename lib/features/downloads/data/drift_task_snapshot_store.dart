import 'dart:async';
import '../../../core/services/database_service.dart';
import '../domain/commands/download_commands.dart';
import '../domain/ports/task_snapshot_store.dart';
import '../models/download_task.dart';

/// Adapter persisting state transitions into the Drift database.
class DriftTaskSnapshotStore implements TaskSnapshotStore {
  final DatabaseService _databaseService;
  final DownloadTask? Function(String id) _findTask;
  final void Function(DownloadTask task)? _onTaskUpdated;

  DriftTaskSnapshotStore({
    required DatabaseService databaseService,
    required DownloadTask? Function(String id) findTask,
    void Function(DownloadTask task)? onTaskUpdated,
  })  : _databaseService = databaseService,
        _findTask = findTask,
        _onTaskUpdated = onTaskUpdated;

  @override
  Future<void> onTaskStateChanged(
    String taskId,
    DomainDownloadState from,
    DomainDownloadState to,
    Object command, {
    String? errorMessage,
    String? pauseReason,
    bool? pausedByUser,
    bool? isCancelled,
  }) async {
    final task = _findTask(taskId);
    if (task == null) return;

    final legacyStatus = DownloadStateMachine.toStatus(to);
    final isCanc = isCancelled ?? (to == DomainDownloadState.failed && command is CancelTask);
    final isPausedUser = pausedByUser ?? (to == DomainDownloadState.paused);

    final updated = task.copyWith(
      status: legacyStatus,
      errorMessage: errorMessage ?? task.errorMessage,
      pauseReason: pauseReason != null ? PauseReason.fromName(pauseReason) : task.pauseReason,
      pausedByUser: isPausedUser,
      isCancelled: isCanc,
      speed: (to == DomainDownloadState.paused ||
              to == DomainDownloadState.failed ||
              to == DomainDownloadState.completed)
          ? 0.0
          : task.speed,
      completedAt:
          to == DomainDownloadState.completed ? DateTime.now() : task.completedAt,
      updatedAt: DateTime.now(),
    );

    // FIX-07: Use the callback instead of direct collection modification
    _onTaskUpdated?.call(updated);
    await _databaseService.saveTask(updated);
  }

  @override
  Future<void> deleteTaskSnapshot(String taskId) async {
    await _databaseService.deleteTask(taskId);
  }
}
