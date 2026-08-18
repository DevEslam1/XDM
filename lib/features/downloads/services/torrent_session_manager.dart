import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../core/di/injection.dart';
import '../../../core/interfaces/i_torrent_service.dart';
import '../../../core/services/torrent_resume_store.dart';
import '../../../core/services/torrent_service.dart';
import '../models/download_task.dart';

/// Service responsible for managing libtorrent sessions, FFI bridge communication,
/// per-file priorities, fast-resume states, and seeding configurations.
class TorrentSessionManager {
  final ITorrentService _torrentService;
  final Map<String, int> _torrentIds = {};
  final Map<int, TorrentUpdateInfo> _latestStats = {};

  TorrentSessionManager({ITorrentService? torrentService})
      : _torrentService = torrentService ??
            (getIt.isRegistered<ITorrentService>()
                ? getIt<ITorrentService>()
                : TorrentServiceImpl());

  Map<String, int> get torrentIds => _torrentIds;
  Map<int, TorrentUpdateInfo> get latestStats => _latestStats;

  void registerTorrentId(String taskId, int torrentId) {
    _torrentIds[taskId] = torrentId;
  }

  int? getTorrentId(String taskId) => _torrentIds[taskId];

  void unregisterTorrent(String taskId) {
    _torrentIds.remove(taskId);
  }

  void updateStats(int torrentId, TorrentUpdateInfo info) {
    _latestStats[torrentId] = info;
  }

  TorrentUpdateInfo? getStats(String taskId) {
    final tid = _torrentIds[taskId];
    if (tid == null) return null;
    return _latestStats[tid] ?? _torrentService.latestStats[tid];
  }

  double getUploadSpeed(String taskId) {
    final stats = getStats(taskId);
    return (stats?.uploadRate ?? 0).toDouble();
  }

  int getSeeds(String taskId) {
    final stats = getStats(taskId);
    return stats?.numSeeds ?? 0;
  }

  int getPeers(String taskId) {
    final stats = getStats(taskId);
    return stats?.numPeers ?? 0;
  }

  bool isTorrentAlive(String taskId) {
    final tid = _torrentIds[taskId];
    if (tid == null) return false;
    return _torrentService.isTorrentAlive(tid);
  }

  /// Pauses a torrent and waits for confirmation up to [timeout] (FIX T-5).
  Future<bool> pauseTorrentWithConfirmation(String taskId,
      {Duration timeout = const Duration(seconds: 4)}) async {
    final tid = _torrentIds[taskId];
    if (tid == null) return true;

    if (!_torrentService.isTorrentAlive(tid)) {
      _torrentIds.remove(taskId);
      return true;
    }

    await _torrentService.pauseTorrent(tid);

    final deadline = DateTime.now().add(timeout);
    bool isPaused = false;
    while (!isPaused && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 50));
      try {
        final stats = _latestStats[tid] ?? _torrentService.latestStats[tid];
        final stateLabel = stats?.stateLabel.toLowerCase() ?? '';
        isPaused = stateLabel.contains('paused') ||
            stateLabel.contains('stopped') ||
            !_torrentService.isTorrentAlive(tid);
      } catch (_) {
        isPaused = true;
      }
    }

    // FIX-PAUSE: If poll timed out but handle is gone, still count as paused.
    if (!isPaused && !_torrentService.isTorrentAlive(tid)) {
      isPaused = true;
      debugPrint('[TorrentSessionManager] pauseTorrentWithConfirmation: '
          'poll timed out but torrent $tid handle gone — treating as paused');
    }

    // Save fast-resume data
    try {
      await TorrentResumeStore.saveAll(
        {tid},
        (id) => _torrentService.resumeBlobFor(id),
      );
    } catch (e) {
      debugPrint(
          '[TorrentSessionManager] Failed to save resume data on pause: $e');
    }

    return isPaused;
  }

  /// Starts or resumes seeding for a completed torrent task.
  Future<void> startSeeding(DownloadTask task) async {
    final tid = _torrentIds[task.id];
    if (tid != null && _torrentService.isTorrentAlive(tid)) {
      _torrentService.resumeTorrent(tid);
    }
  }

  /// Applies file priority selection for a torrent.
  void setFilePriorities(int torrentId, List<int> priorities) {
    _torrentService.setFilePriorities(torrentId, priorities);
  }

  /// Retrieves live per-file statistics for a torrent.
  List<TorrentFileItem> getFiles(int torrentId) {
    return _torrentService.getFiles(torrentId);
  }

  /// Removes a torrent from the session.
  void removeTorrent(int torrentId,
      {bool deleteFiles = false, bool deleteResumeData = true}) {
    _torrentService.removeTorrent(torrentId,
        deleteFiles: deleteFiles, deleteResumeData: deleteResumeData);
    _latestStats.remove(torrentId);
    _torrentIds.removeWhere((_, tid) => tid == torrentId);
  }

  Future<int> reconcileWithDatabase(dynamic dbService) async {
    var reconciled = 0;
    try {
      _latestStats
        ..clear()
        ..addAll(_torrentService.latestStats);

      final activeIds = _torrentService.activeTorrentIds.toSet();
      // ignore: avoid_dynamic_calls
      final tasks = await dbService.loadTasks() as List<dynamic>;
      final nameToActiveId = <String, int>{};
      for (final id in activeIds) {
        final stats = _latestStats[id];
        if (stats != null && stats.name.isNotEmpty) {
          nameToActiveId.putIfAbsent(stats.name, () => id);
        }
      }

      for (final task in tasks) {
        // ignore: avoid_dynamic_calls
        if (!task.isTorrent) continue;
        // ignore: avoid_dynamic_calls
        var tid = _torrentIds[task.id];
        if (tid != null && activeIds.contains(tid)) {
          reconciled++;
          continue;
        }
        if (tid != null) {
          // ignore: avoid_dynamic_calls
          _torrentIds.remove(task.id);
          tid = null;
        }
        // ignore: avoid_dynamic_calls
        final match = nameToActiveId[task.fileName];
        if (match != null) {
          // ignore: avoid_dynamic_calls
          _torrentIds[task.id] = match;
          reconciled++;
        }
      }
    } catch (e) {
      debugPrint('[TorrentSessionManager] reconcileWithDatabase failed: $e');
    }
    return reconciled;
  }
}

