import '../provider/download_provider.dart';

/// Clean Architecture Use Case for cancelling download tasks.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// ⚠️  DEPRECATED — Orphaned scaffolding, not wired to any UI callsite.
/// ─────────────────────────────────────────────────────────────────────────────
///
/// The real cancel logic lives in [DownloadProvider.cancelTask], which flushes
/// pending progress, cancels tokens for all legs (video/audio/torrent), cleans
/// up temp files, and sets [isCancelled: true] so auto-resume skips the task.
///
/// This stub exists solely so the file is not silently missing. Calling it
/// forwards to [DownloadProvider.cancelTask] so behaviour is correct.
/// Do NOT add logic here — extend [DownloadProvider] instead.
@Deprecated(
  'Use DownloadProvider.cancelTask(taskId) directly. '
  'This use case is orphaned scaffolding and sets status to failed without '
  'flushing progress, cancelling tokens, or cleaning up temp files. '
  'See DownloadProvider.cancelTask in download_provider.dart.',
)
class CancelDownloadUseCase {
  final DownloadProvider _downloadProvider;

  const CancelDownloadUseCase(this._downloadProvider);

  /// Forwards to [DownloadProvider.cancelTask] — the single source of truth.
  Future<void> call(String taskId) => _downloadProvider.cancelTask(taskId);
}
