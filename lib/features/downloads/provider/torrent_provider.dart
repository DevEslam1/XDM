import 'package:dmx/core/services/torrent_models.dart';
import 'package:flutter/foundation.dart';

/// Single-responsibility provider for torrent session management and stats tracking.
class TorrentProvider extends ChangeNotifier {
  final Map<String, int> _torrentIds = {};
  final Map<int, TorrentUpdateInfo> _latestStats = {};

  Map<String, int> get torrentIds => Map.unmodifiable(_torrentIds);
  Map<int, TorrentUpdateInfo> get latestStats => Map.unmodifiable(_latestStats);

  void registerTorrentId(String taskId, int torrentId) {
    _torrentIds[taskId] = torrentId;
    notifyListeners();
  }

  void unregisterTorrentId(String taskId) {
    final torrentId = _torrentIds.remove(taskId);
    if (torrentId != null) {
      _latestStats.remove(torrentId);
    }
    notifyListeners();
  }

  void updateStats(TorrentUpdateInfo info) {
    _latestStats[info.id] = info;
    notifyListeners();
  }

  TorrentUpdateInfo? getStatsForTask(String taskId) {
    final torrentId = _torrentIds[taskId];
    if (torrentId == null) return null;
    return _latestStats[torrentId];
  }

  Iterable<TorrentUpdateInfo> get activeTorrents => _latestStats.values;

  void registerTorrent(int id, TorrentUpdateInfo info) {
    _latestStats[id] = info;
    notifyListeners();
  }

  void updateTorrentProgress(int id, TorrentUpdateInfo info) {
    _latestStats[id] = info;
    notifyListeners();
  }

  void removeTorrent(int id) {
    _latestStats.remove(id);
    notifyListeners();
  }
}
