import '../models/domain_download_state.dart';

/// Pure-Dart interface for persisting task state snapshots.
abstract class TaskSnapshotStore {
  /// Invoked when a task undergoes a state transition.
  Future<void> onTaskStateChanged(
    String taskId,
    DomainDownloadState from,
    DomainDownloadState to,
    Object command, {
    String? errorMessage,
    String? pauseReason,
    bool? pausedByUser,
    bool? isCancelled,
  });

  /// Deletes a task from the persistent snapshot store.
  Future<void> deleteTaskSnapshot(String taskId);
}
