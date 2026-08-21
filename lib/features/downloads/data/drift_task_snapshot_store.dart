import 'dart:async';
import '../../../core/services/database_service.dart';
import '../domain/ports/task_snapshot_store.dart';
import '../models/download_state_machine.dart';
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
    final isCanc = isCancelled ?? (to == DomainDownloadState.failed && command.toString().contains('CancelTask'));
    final isPausedUser = pausedByUser ?? (to == DomainDownloadState.paused);

    final updated = DownloadTask(
      id: task.id,
      fileName: task.fileName,
      url: task.url,
      fileSize: task.fileSize,
      downloadedBytes: task.downloadedBytes,
      speed: (to == DomainDownloadState.paused || to == DomainDownloadState.failed || to == DomainDownloadState.completed) ? 0.0 : task.speed,
      eta: task.eta,
      category: task.category,
      status: legacyStatus,
      savePath: task.savePath,
      localFilePath: task.localFilePath,
      tempFilePath: task.tempFilePath,
      errorMessage: errorMessage ?? task.errorMessage,
      statusMessage: task.statusMessage,
      failureCategory: task.failureCategory,
      recoveryHint: task.recoveryHint,
      threadCount: task.threadCount,
      chunks: task.chunks,
      createdAt: task.createdAt,
      updatedAt: DateTime.now(),
      completedAt: to == DomainDownloadState.completed ? DateTime.now() : task.completedAt,
      scheduledAt: task.scheduledAt,
      wasScheduledAt: task.wasScheduledAt,
      supportsResume: task.supportsResume,
      speedLimitKbps: task.speedLimitKbps,
      seedingEnabled: task.seedingEnabled,
      seedingLimited: task.seedingLimited,
      seedingLimitKbps: task.seedingLimitKbps,
      torrentFiles: task.torrentFiles,
      downloadPageUrl: task.downloadPageUrl,
      mergedAudioUrl: task.mergedAudioUrl,
      audioSize: task.audioSize,
      videoStreamSize: task.videoStreamSize,
      audioProgress: task.audioProgress,
      audioThreadCount: task.audioThreadCount,
      pausedByUser: isPausedUser,
      isCancelled: isCanc,
      youtubeQualityPreset: task.youtubeQualityPreset,
      notes: task.notes,
      isAppUpdate: task.isAppUpdate,
      priority: task.priority,
      queueOrder: task.queueOrder,
      playlistId: task.playlistId,
      playlistTitle: task.playlistTitle,
      thumbnailUrl: task.thumbnailUrl,
      expectedSha256: task.expectedSha256,
      mirrorUrls: task.mirrorUrls,
      siteType: task.siteType,
      siteDisplayName: task.siteDisplayName,
      contentHint: task.contentHint,
      totalPieces: task.totalPieces,
      completedPieces: task.completedPieces,
      ytCounterpartDownloadedBytes: task.ytCounterpartDownloadedBytes,
      cycleState: task.cycleState,
      previousCycleState: task.previousCycleState,
      totalFiles: task.totalFiles,
      completedFiles: task.completedFiles,
      totalFileBytes: task.totalFileBytes,
      downloadedFileBytes: task.downloadedFileBytes,
      infoHash: task.infoHash,
    );

    _onTaskUpdated?.call(updated);
    await _databaseService.saveTask(updated);
  }

  @override
  Future<void> deleteTaskSnapshot(String taskId) async {
    await _databaseService.deleteTask(taskId);
  }
}
