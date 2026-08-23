import '../models/download_task.dart';

/// Maps between [CycleState] (domain engine cycle representation)
/// and [DownloadStatus] (UI/persistence aggregate state).
class TaskStateMapper {
  const TaskStateMapper._();

  /// Converts a fine-grained [CycleState] to its corresponding high-level [DownloadStatus].
  static DownloadStatus toDownloadStatus(CycleState cycleState) {
    switch (cycleState) {
      case CycleState.starting:
      case CycleState.allocating:
      case CycleState.fetchingMetadata:
      case CycleState.downloading:
      case CycleState.verifying:
      case CycleState.merging:
      case CycleState.retrying:
      case CycleState.resuming:
      case CycleState.stalled:
        return DownloadStatus.downloading;
      case CycleState.seeding:
      case CycleState.completed:
        return DownloadStatus.completed;
      case CycleState.paused:
      case CycleState.updatingLinks:
        return DownloadStatus.paused;
      case CycleState.failed:
        return DownloadStatus.failed;
    }
  }

  /// Converts a [DownloadStatus] into an initial default [CycleState].
  static CycleState toCycleState(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.downloading:
        return CycleState.downloading;
      case DownloadStatus.merging:
        return CycleState.merging;
      case DownloadStatus.paused:
        return CycleState.paused;
      case DownloadStatus.completed:
        return CycleState.completed;
      case DownloadStatus.failed:
        return CycleState.failed;
      case DownloadStatus.queued:
        return CycleState.starting;
    }
  }
}
