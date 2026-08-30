import '../models/download_task.dart';

/// Exhaustive mapper between domain state representations:
/// - [DomainDownloadState] (pure domain lifecycle)
/// - [CycleState] (fine-grained engine cycle status)
/// - [DownloadStatus] (high-level UI/persistence status)
class TaskStateMapper {
  const TaskStateMapper._();

  /// Converts fine-grained [CycleState] to high-level [DownloadStatus].
  /// Exhaustive switch with no default branch.
  static DownloadStatus toDownloadStatus(CycleState cycleState) {
    return switch (cycleState) {
      CycleState.starting => DownloadStatus.downloading,
      CycleState.allocating => DownloadStatus.downloading,
      CycleState.fetchingMetadata => DownloadStatus.downloading,
      CycleState.downloading => DownloadStatus.downloading,
      CycleState.verifying => DownloadStatus.downloading,
      CycleState.merging => DownloadStatus.merging,
      CycleState.retrying => DownloadStatus.downloading,
      CycleState.resuming => DownloadStatus.downloading,
      CycleState.stalled => DownloadStatus.downloading,
      CycleState.seeding => DownloadStatus.completed,
      CycleState.completed => DownloadStatus.completed,
      CycleState.paused => DownloadStatus.paused,
      CycleState.updatingLinks => DownloadStatus.paused,
      CycleState.failed => DownloadStatus.failed,
    };
  }

  /// Converts high-level [DownloadStatus] to default [CycleState].
  /// Exhaustive switch with no default branch.
  static CycleState toCycleState(DownloadStatus status) {
    return switch (status) {
      DownloadStatus.queued => CycleState.starting,
      DownloadStatus.downloading => CycleState.downloading,
      DownloadStatus.paused => CycleState.paused,
      DownloadStatus.merging => CycleState.merging,
      DownloadStatus.completed => CycleState.completed,
      DownloadStatus.failed => CycleState.failed,
    };
  }

  /// Converts [DomainDownloadState] to [DownloadStatus].
  /// Exhaustive switch with no default branch.
  static DownloadStatus domainToDownloadStatus(DomainDownloadState state) {
    return switch (state) {
      DomainDownloadState.idle => DownloadStatus.queued,
      DomainDownloadState.queued => DownloadStatus.queued,
      DomainDownloadState.starting => DownloadStatus.downloading,
      DomainDownloadState.downloading => DownloadStatus.downloading,
      DomainDownloadState.retrying => DownloadStatus.downloading,
      DomainDownloadState.merging => DownloadStatus.merging,
      DomainDownloadState.completing => DownloadStatus.completed,
      DomainDownloadState.completed => DownloadStatus.completed,
      DomainDownloadState.paused => DownloadStatus.paused,
      DomainDownloadState.failed => DownloadStatus.failed,
    };
  }

  /// Converts [DownloadStatus] to [DomainDownloadState].
  /// Exhaustive switch with no default branch.
  static DomainDownloadState downloadStatusToDomain(DownloadStatus status) {
    return switch (status) {
      DownloadStatus.queued => DomainDownloadState.queued,
      DownloadStatus.downloading => DomainDownloadState.downloading,
      DownloadStatus.paused => DomainDownloadState.paused,
      DownloadStatus.merging => DomainDownloadState.merging,
      DownloadStatus.completed => DomainDownloadState.completed,
      DownloadStatus.failed => DomainDownloadState.failed,
    };
  }

  /// Converts [CycleState] to [DomainDownloadState].
  /// Exhaustive switch with no default branch.
  static DomainDownloadState cycleStateToDomain(CycleState cycleState) {
    return switch (cycleState) {
      CycleState.starting => DomainDownloadState.starting,
      CycleState.allocating => DomainDownloadState.starting,
      CycleState.fetchingMetadata => DomainDownloadState.starting,
      CycleState.downloading => DomainDownloadState.downloading,
      CycleState.verifying => DomainDownloadState.downloading,
      CycleState.merging => DomainDownloadState.merging,
      CycleState.retrying => DomainDownloadState.retrying,
      CycleState.resuming => DomainDownloadState.starting,
      CycleState.stalled => DomainDownloadState.downloading,
      CycleState.seeding => DomainDownloadState.completed,
      CycleState.completed => DomainDownloadState.completed,
      CycleState.paused => DomainDownloadState.paused,
      CycleState.updatingLinks => DomainDownloadState.paused,
      CycleState.failed => DomainDownloadState.failed,
    };
  }
}
