import 'dart:async';

import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:flutter/foundation.dart';

/// Single-responsibility provider for torrent session management and stats tracking.
class TorrentProvider extends ChangeNotifier {
  final Map<String, int> _torrentIds = {};
  final Map<int, TorrentUpdateInfo> _latestStats = {};
  StreamSubscription<Map<int, TorrentUpdateInfo>>? _updatesSub;
  Timer? _staleDetector;

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

  void startListening() {
    if (_updatesSub != null) return;
    _updatesSub = TorrentService.torrentUpdates.listen((torrents) {
      for (final entry in torrents.entries) {
        _latestStats[entry.key] = entry.value;
      }
      notifyListeners();
    }, onError: (Object e) {
      LoggingService.logger('TorrentProvider')
          .warning('torrentUpdates error', e as Exception);
    });
    _startStaleDetector();
  }

  void _startStaleDetector() {
    _staleDetector?.cancel();
    _staleDetector = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!TorrentService.isInitialized) return;
      final active = TorrentService.activeTorrentIds;
      final registeredToTasks = _torrentIds.values.toSet();
      _latestStats.removeWhere((id, _) =>
          !active.contains(id) && !registeredToTasks.contains(id));
    });
  }

  @override
  void dispose() {
    _updatesSub?.cancel();
    _updatesSub = null;
    _staleDetector?.cancel();
    _staleDetector = null;
    super.dispose();
  }
}
