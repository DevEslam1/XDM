import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/torrent_service.dart';

import '../models/pause_reason.dart';
import '../provider/download_queue_provider.dart';
import '../provider/torrent_provider.dart';

/// Clean Architecture Use Case for pausing download tasks.
///
/// FIX-C: A UI-level "paused" flag alone does NOT stop libtorrent. The native
/// torrent must be hard-stopped (pause + verify + release handle) so the
/// transfer actually halts. Fast-resume data is preserved for a later resume.
class PauseDownloadUseCase {
  final DownloadQueueProvider _queueProvider;
  final TorrentProvider _torrentProvider;

  const PauseDownloadUseCase(this._queueProvider, this._torrentProvider);

  Future<void> call(String taskId,
      {PauseReason reason = PauseReason.userRequested}) async {
    final torrentId = _torrentProvider.torrentIds[taskId];
    if (torrentId != null) {
      try {
        await TorrentService.forceStopTorrent(torrentId);
      } catch (e, st) {
        LoggingService.logger('PauseDownloadUseCase')
            .warning('Operation failed', e, st);
      }
    }
    await _queueProvider.pauseTask(taskId, reason: reason);
  }
}
