import '../provider/download_provider.dart';

/// Clean Architecture Use Case for retrying failed download tasks.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// ⚠️  DEPRECATED — Orphaned scaffolding, not wired to any UI callsite.
/// ─────────────────────────────────────────────────────────────────────────────
///
/// The real retry logic lives in [DownloadProvider.retryTask], which:
///   • Refreshes YouTube signed URLs via YoutubeService.getFreshStreams
///   • Detects stream identity changes (itag swap → full restart)
///   • Classifies failures via [ErrorTaxonomy] to pick full-reset vs. resume
///   • Clears [failureCategory], [recoveryHint], [pauseReason], and [cycleState]
///   • Handles merge-only retries when only one leg (video/audio) is missing
///
/// This stub exists solely so the file is not silently missing. Calling it
/// forwards to [DownloadProvider.retryTask] so behaviour is correct.
/// Do NOT add logic here — extend [DownloadProvider._retryTaskInternal] instead.
@Deprecated(
  'Use DownloadProvider.retryTask(taskId) directly. '
  'This use case is orphaned scaffolding and does not implement the full retry '
  'pipeline. See _retryTaskInternal in download_provider.dart.',
)
class RetryDownloadUseCase {
  final DownloadProvider _downloadProvider;

  const RetryDownloadUseCase(this._downloadProvider);

  /// Forwards to [DownloadProvider.retryTask] — the single source of truth.
  Future<void> call(String taskId) => _downloadProvider.retryTask(taskId);
}
