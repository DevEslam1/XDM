import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/torrent_service.dart';

import '../models/download_task.dart';
import '../provider/download_list_provider.dart';
import '../provider/torrent_provider.dart';

/// Clean Architecture Use Case for deleting download tasks.
///
/// FIX-C: Torrent tasks are hard-stopped in the native engine BEFORE the DB
/// row is removed. Otherwise the libtorrent handle keeps transferring (or the
/// deleted task reappears after restart via stale fast-resume data).
class DeleteDownloadUseCase {
  final DownloadListProvider _listProvider;
  final TorrentProvider _torrentProvider;

  const DeleteDownloadUseCase(this._listProvider, this._torrentProvider);

  Future<void> call(String taskId) async {
    final task = _listProvider.findTask(taskId);
    if (task != null && task.isTorrent) {
      final torrentId = _resolveTorrentId(task);
      if (torrentId != null) {
        try {
          await TorrentService.forceStopTorrent(torrentId);
          TorrentService.removeTorrent(torrentId,
              deleteFiles: false, deleteResumeData: true);
        } catch (e, st) {
          LoggingService.logger('DeleteDownloadUseCase')
              .warning('Operation failed', e, st);
        }
      }
      _torrentProvider.unregisterTorrentId(taskId);
    }
    await _listProvider.deleteTask(taskId);
  }

  int? _resolveTorrentId(DownloadTask task) {
    final mapped = _torrentProvider.torrentIds[task.id];
    if (mapped != null) return mapped;
    // Fallback: match a live native handle by file name.
    for (final id in TorrentService.activeTorrentIds) {
      final stats = TorrentService.latestStats[id];
      if (stats != null &&
          (stats.name == task.fileName ||
              stats.name == task.url ||
              (task.torrentFiles?.isNotEmpty == true &&
                  stats.name.contains(task.torrentFiles!.first['name'] as String? ?? '')))) {
        return id;
      }
    }
    return null;
  }
}