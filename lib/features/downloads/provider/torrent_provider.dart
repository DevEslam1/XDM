import 'dart:async';

import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:flutter/foundation.dart';

/// Single-responsibility provider for torrent session management and stats tracking.
class TorrentProvider extends ChangeNotifier {
  final Map<String, int> _torrentIds = {};
  final Map<int, TorrentUpdateInfo> _latestStats = {};
  Timer? _notifyDebounceTimer;
  DateTime? _lastNotifyTime;
  StreamSubscription<Map<int, TorrentUpdateInfo>>? _updatesSub;
  Timer? _staleDetector;

  @override
  void notifyListeners() {
    if (DownloadEngine.isInBackground && PowerMonitor.screenOff) return;
    super.notifyListeners();
  }

  void _debouncedNotify() {
    if (DownloadEngine.isInBackground && PowerMonitor.screenOff) return;
    final now = DateTime.now();
    if (_lastNotifyTime == null ||
        now.difference(_lastNotifyTime!) >= const Duration(milliseconds: 300)) {
      _lastNotifyTime = now;
      _notifyDebounceTimer?.cancel();
      _notifyDebounceTimer = null;
      notifyListeners();
    } else {
      _notifyDebounceTimer ??= Timer(const Duration(milliseconds: 300), () {
        _lastNotifyTime = DateTime.now();
        _notifyDebounceTimer = null;
        notifyListeners();
      });
    }
  }

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
    _debouncedNotify();
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
    _debouncedNotify();
  }

  void removeTorrent(int id) {
    _latestStats.remove(id);
    notifyListeners();
  }

  /// FIX-E: Subscribes directly to the engine's torrentUpdates broadcast
  /// stream (200ms debounced) so the coordinator/UI always see live metrics
  /// even when no other consumer is listening.
  void startListening() {
    if (_updatesSub != null) return;
    _updatesSub = TorrentService.torrentUpdates.listen((torrents) {
      for (final entry in torrents.entries) {
        _latestStats[entry.key] = entry.value;
      }
      _debouncedNotify();
    }, onError: (Object e) {
      LoggingService.logger('TorrentProvider')
          .warning('torrentUpdates error', e as Exception);
    });
    _startStaleDetector();
  }

  /// FIX-E: Every 30s, drop stats for torrents that no longer appear in the
  /// engine's active set (and are not registered to any task), preventing a
  /// stale "ghost" metric from keeping the UI stuck at a non-zero value.
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
    _notifyDebounceTimer?.cancel();
    _notifyDebounceTimer = null;
    super.dispose();
  }
}