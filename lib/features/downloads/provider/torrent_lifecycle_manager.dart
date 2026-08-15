/// Handles torrent-specific lifecycle events (start/stop/seeding).
class TorrentLifecycleManager {
  final Map<String, int> _torrentIds = {};

  void registerTorrent(String taskId, int torrentId) {
    _torrentIds[taskId] = torrentId;
  }

  void unregisterTorrent(String taskId) {
    _torrentIds.remove(taskId);
  }

  int? getTorrentId(String taskId) => _torrentIds[taskId];
}
