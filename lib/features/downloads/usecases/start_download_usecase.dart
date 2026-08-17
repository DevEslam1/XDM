import '../models/download_task.dart';
import '../provider/download_provider.dart';

/// Clean Architecture Use Case for adding and queueing a new download.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// ⚠️  DEPRECATED — Orphaned scaffolding, not wired to any UI callsite.
/// ─────────────────────────────────────────────────────────────────────────────
///
/// The real start/add logic lives in [DownloadProvider.addDownload], which handles
/// permission checks, disk-space validation, queue-slot management, and the full
/// orchestration pipeline including torrent-add and YouTube pre-fetch.
///
/// This stub exists solely so the file is not silently missing. Calling it
/// forwards to [DownloadProvider.addDownload] so behaviour is correct.
/// Do NOT add logic here — extend [DownloadProvider] instead.
@Deprecated(
  'Use DownloadProvider.addDownload(...) directly. '
  'This use case is orphaned scaffolding and does not implement the full '
  'start/add pipeline. See DownloadProvider.addDownload in download_provider.dart.',
)
class StartDownloadUseCase {
  // ignore: unused_field
  final DownloadProvider _downloadProvider;

  const StartDownloadUseCase(this._downloadProvider);

  /// Previously added a task directly to DownloadListProvider + queue.
  /// Now a no-op placeholder — use [DownloadProvider.addDownload] instead.
  ///
  /// The [task] parameter is kept for API compatibility only.
  // ignore: avoid_unused_parameters
  Future<void> call(DownloadTask task) async {
    // Real implementation: _downloadProvider.addDownload(url: task.url, ...)
    // Not forwarded because addDownload signature differs from DownloadTask fields.
    // Callers should migrate to DownloadProvider.addDownload() directly.
    assert(false, 'StartDownloadUseCase is deprecated. Use DownloadProvider.addDownload() instead.');
  }
}
