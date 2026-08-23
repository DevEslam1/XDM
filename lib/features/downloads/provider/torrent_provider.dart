import 'dart:async';

import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

/// Single-responsibility provider for torrent session management and stats tracking.
class TorrentProvider extends ChangeNotifier {
  final ITorrentService _torrentService;
  final Map<String, int> _torrentIds = {};
  final Map<int, TorrentUpdateInfo> _latestStats = {};
  StreamSubscription<Map<int, TorrentUpdateInfo>>? _updatesSub;
  Timer? _staleDetector;
  Timer? _coalesceTimer;
  // FIX-3.4: Add _disposed guard
  bool _disposed = false;

  TorrentProvider({ITorrentService? torrentService})
      : _torrentService = torrentService ??
            (GetIt.I.isRegistered<ITorrentService>()
                ? GetIt.I<ITorrentService>()
                : TorrentServiceImpl());

  Map<String, int> get torrentIds => Map.unmodifiable(_torrentIds);
  Map<int, TorrentUpdateInfo> get latestStats => Map.unmodifiable(_latestStats);

  void registerTorrentId(String taskId, int torrentId) {
    if (_disposed) return;
    _torrentIds[taskId] = torrentId;
    notifyListeners();
  }

  void unregisterTorrentId(String taskId) {
    if (_disposed) return;
    final torrentId = _torrentIds.remove(taskId);
    if (torrentId != null) {
      _latestStats.remove(torrentId);
    }
    notifyListeners();
  }

  void updateStats(TorrentUpdateInfo info) {
    if (_disposed) return;
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
    if (_disposed) return;
    _latestStats[id] = info;
    notifyListeners();
  }

  void updateTorrentProgress(int id, TorrentUpdateInfo info) {
    if (_disposed) return;
    _latestStats[id] = info;
    notifyListeners();
  }

  void removeTorrent(int id) {
    if (_disposed) return;
    _latestStats.remove(id);
    notifyListeners();
  }

  void startListening() {
    if (_disposed || _updatesSub != null) return;
    _updatesSub = _torrentService.torrentUpdates.listen((torrents) {
      if (_disposed) return;
      // FIX-2.8: Prune entries no longer in updates to prevent leak
      _latestStats.removeWhere((key, _) => !torrents.containsKey(key));
      for (final entry in torrents.entries) {
        _latestStats[entry.key] = entry.value;
      }
      _coalesceTimer?.cancel();
      _coalesceTimer = Timer(const Duration(seconds: 1), () {
        if (!_disposed) notifyListeners();
      });
    }, onError: (Object e) {
      LoggingService.logger('TorrentProvider')
          .warning('torrentUpdates error', e as Exception);
    });
    _startStaleDetector();
  }

  void _startStaleDetector() {
    _staleDetector?.cancel();
    final isBg = PowerMonitor.screenOff ||
        !DownloadEngine.appInForeground ||
        DownloadEngine.isInBackground;
    final interval = isBg ? const Duration(seconds: 60) : const Duration(seconds: 30);
    _staleDetector = Timer.periodic(interval, (_) {
      if (_disposed || !_torrentService.isInitialized) return;
      final active = _torrentService.activeTorrentIds;
      final registeredToTasks = _torrentIds.values.toSet();
      _latestStats.removeWhere(
          (id, _) => !active.contains(id) && !registeredToTasks.contains(id));
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _updatesSub?.cancel();
    _updatesSub = null;
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    _staleDetector?.cancel();
    _staleDetector = null;
    super.dispose();
  }
}
