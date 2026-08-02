import 'package:flutter/foundation.dart';
import 'torrent_models.dart';

class TrackerManager extends ChangeNotifier {
  final Map<int, List<TorrentTrackerInfo>> _trackersByTorrent = {};

  List<TorrentTrackerInfo> getTrackers(int torrentId) {
    return List.unmodifiable(_trackersByTorrent[torrentId] ?? []);
  }

  void setTrackers(int torrentId, List<TorrentTrackerInfo> trackers) {
    _trackersByTorrent[torrentId] = List.from(trackers);
    notifyListeners();
  }

  bool addTracker(int torrentId, String trackerUrl) {
    final trimmed = trackerUrl.trim();
    if (trimmed.isEmpty) return false;
    if (!trimmed.startsWith('http://') &&
        !trimmed.startsWith('https://') &&
        !trimmed.startsWith('udp://')) {
      return false;
    }

    final list = _trackersByTorrent.putIfAbsent(torrentId, () => []);
    if (list.any((t) => t.url == trimmed)) return false;

    list.add(TorrentTrackerInfo(
      url: trimmed,
      status: TrackerStatus.updating,
      message: 'Announcing...',
    ));
    notifyListeners();
    return true;
  }

  void removeTracker(int torrentId, String trackerUrl) {
    final list = _trackersByTorrent[torrentId];
    if (list != null) {
      list.removeWhere((t) => t.url == trackerUrl);
      notifyListeners();
    }
  }

  void reannounce(int torrentId) {
    final list = _trackersByTorrent[torrentId];
    if (list != null) {
      for (var i = 0; i < list.length; i++) {
        list[i] = list[i].copyWith(
          status: TrackerStatus.updating,
          message: 'Manual announce queued...',
        );
      }
      notifyListeners();
    }
  }
}
