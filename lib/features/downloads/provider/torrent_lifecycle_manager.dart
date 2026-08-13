import '../../../core/services/torrent_service.dart';
import '../models/download_task.dart';

class TorrentLifecycleManager {
  final Map<String, int> _torrentIds;
  final Map<int, TorrentUpdateInfo> _latestTorrentStats;

  TorrentLifecycleManager({
    required Map<String, int> torrentIds,
    required Map<int, TorrentUpdateInfo> latestTorrentStats,
  })  : _torrentIds = torrentIds,
        _latestTorrentStats = latestTorrentStats;

  Future<void> startSeeding(DownloadTask task) async {
    final torrentId = _torrentIds[task.id];
    if (torrentId != null) {
      TorrentService.resumeTorrent(torrentId);
    }
  }

  double getUploadSpeed(String taskId) {
    final torrentId = _torrentIds[taskId];
    if (torrentId == null) return 0.0;
    return (_latestTorrentStats[torrentId]?.uploadRate ?? 0).toDouble();
  }

  int getSeeds(String taskId) {
    final torrentId = _torrentIds[taskId];
    if (torrentId == null) return 0;
    return _latestTorrentStats[torrentId]?.numSeeds ?? 0;
  }

  int getPeers(String taskId) {
    final torrentId = _torrentIds[taskId];
    if (torrentId == null) return 0;
    return _latestTorrentStats[torrentId]?.numPeers ?? 0;
  }

  void checkRatioLimits() {
    // Torrent ratio enforcement delegate
  }

  void enforceQueue() {
    // Torrent queue enforcement delegate
  }
}
