import 'package:flutter/foundation.dart';
import 'package:dmx/core/services/torrent_models.dart';

class TorrentProvider extends ChangeNotifier {
  final Map<int, TorrentUpdateInfo> _activeTorrents = {};

  List<TorrentUpdateInfo> get activeTorrents => _activeTorrents.values.toList();

  void registerTorrent(int torrentId, TorrentUpdateInfo info) {
    _activeTorrents[torrentId] = info;
    notifyListeners();
  }

  void updateTorrentProgress(int torrentId, TorrentUpdateInfo info) {
    _activeTorrents[torrentId] = info;
    notifyListeners();
  }

  void removeTorrent(int torrentId) {
    if (_activeTorrents.remove(torrentId) != null) {
      notifyListeners();
    }
  }
}
