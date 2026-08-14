import 'package:flutter/foundation.dart';
import 'torrent_models.dart';

class TrackerManager extends ChangeNotifier {
  static const List<String> defaultTrackers = [
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://open.stealth.si:80/announce',
    'udp://tracker.torrent.eu.org:451/announce',
    'udp://tracker.birkenwald.de:6969/announce',
    'udp://tracker.moeking.me:6969/announce',
    'udp://explodie.org:6969/announce',
    'udp://tracker1.bt.moack.co.kr:80/announce',
    'udp://tracker.dler.org:6969/announce',
    'udp://open.demonii.com:1337/announce',
    'udp://tracker.openbittorrent.com:80/announce',
  ];

  final Map<int, List<TorrentTrackerInfo>> _trackersByTorrent = {};
  final Map<String, DateTime> _lastAnnounceTime = {};
  static const Duration minAnnounceInterval = Duration(seconds: 15);

  bool canAnnounce(String trackerUrl) {
    final last = _lastAnnounceTime[trackerUrl];
    if (last == null) return true;
    return DateTime.now().difference(last) >= minAnnounceInterval;
  }

  void recordAnnounce(String trackerUrl) {
    _lastAnnounceTime[trackerUrl] = DateTime.now();
  }

  List<TorrentTrackerInfo> getTrackers(int torrentId) {
    return List.unmodifiable(_trackersByTorrent[torrentId] ?? []);
  }

  double trackerHealthScore(TorrentTrackerInfo tracker) {
    if (tracker.status == TrackerStatus.working) return 1.0;
    if (tracker.status == TrackerStatus.updating) return 0.5;
    return 0.0;
  }

  void autoAddDefaultsIfSparse(int torrentId) {
    final list = _trackersByTorrent.putIfAbsent(torrentId, () => []);
    if (list.length < 3) {
      for (final url in defaultTrackers) {
        if (!list.any((t) => t.url == url)) {
          list.add(TorrentTrackerInfo(
            url: url,
            status: TrackerStatus.updating,
            message: 'Auto-added default tracker',
          ));
        }
      }
      notifyListeners();
    }
  }

  void autoReannounceFailing(int torrentId) {
    final list = _trackersByTorrent[torrentId];
    if (list != null) {
      bool modified = false;
      final now = DateTime.now();
      for (var i = 0; i < list.length; i++) {
        if (list[i].status == TrackerStatus.notWorking &&
            canAnnounce(list[i].url)) {
          _lastAnnounceTime[list[i].url] = now;
          list[i] = list[i].copyWith(
            status: TrackerStatus.updating,
            message: 'Auto-reannouncing failing tracker...',
          );
          modified = true;
        }
      }
      if (modified) notifyListeners();
    }
  }

  void setTrackers(int torrentId, List<TorrentTrackerInfo> trackers) {
    _trackersByTorrent[torrentId] = List.from(trackers);
    if ((_trackersByTorrent[torrentId]?.length ?? 0) < 3) {
      autoAddDefaultsIfSparse(torrentId);
    } else {
      notifyListeners();
    }
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
    _lastAnnounceTime[trimmed] = DateTime.now();
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

  bool reannounce(int torrentId, {bool force = false}) {
    final list = _trackersByTorrent[torrentId];
    if (list != null) {
      bool anyUpdated = false;
      final now = DateTime.now();
      for (var i = 0; i < list.length; i++) {
        final url = list[i].url;
        if (force || canAnnounce(url)) {
          _lastAnnounceTime[url] = now;
          list[i] = list[i].copyWith(
            status: TrackerStatus.updating,
            message: 'Manual announce queued...',
          );
          anyUpdated = true;
        }
      }
      if (anyUpdated) {
        notifyListeners();
        return true;
      }
    }
    return false;
  }
}
