import 'dart:async';
import 'dart:io';
import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:flutter/foundation.dart';
import '../../../core/di/injection.dart';
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
    final seeds = stats?.numSeeds ?? 0;
    return seeds < 0 ? 0 : seeds;
  }

  int getPeers(String taskId) {
    final stats = getStats(taskId);
    final peers = stats?.numPeers ?? 0;
    return peers < 0 ? 0 : peers;
  }

  bool isTorrentAlive(String taskId) {
    final tid = _torrentIds[taskId];
    if (tid == null) return false;
    return _torrentService.isTorrentAlive(tid);
  }

  /// Pauses a torrent for the given task.
  Future<void> pauseTorrent(String taskId) async {
    final tid = _torrentIds[taskId];
    if (tid == null) return;

    if (!_torrentService.isTorrentAlive(tid)) {
      _torrentIds.remove(taskId);
      return;
    }

    await _torrentService.pauseTorrent(tid);

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
  }

  /// Resumes a torrent task. If forceStopTorrent was called or the handle is dead/removed,
  /// re-adds the torrent via addMagnet/addTorrentFile with the saved infoHash + loadResumeData.
  /// Does not call resumeTorrent on a removed handle.
  Future<int?> resumeTorrentTask(DownloadTask task) async {
    final tid = _torrentIds[task.id];
    if (tid != null && _torrentService.isTorrentAlive(tid)) {
      await _torrentService.resumeTorrent(tid);
      return tid;
    }

    // Handle was removed / dead (e.g. after forceStopTorrent): re-add with saved infoHash & resume data
    _torrentIds.remove(task.id);
    final rawSaveDir = task.savePath.isNotEmpty
        ? task.savePath
        : (task.localFilePath.isNotEmpty
            ? File(task.localFilePath).parent.path
            : '');
    final saveDir = rawSaveDir.isNotEmpty ? rawSaveDir : Directory.current.path;
    int newId = -1;
    if (task.url.startsWith('magnet:')) {
      newId = _torrentService.addMagnet(task.url, saveDir);
    } else {
      newId = _torrentService.addTorrentFile(task.url, saveDir,
          sourceKey: task.url);
    }

    if (newId >= 0) {
      _torrentIds[task.id] = newId;
      try {
        final resumeBytes =
            await TorrentResumeStore.loadResumeDataForSource(task.url);
        if (resumeBytes != null && resumeBytes.isNotEmpty) {
          _torrentService.loadResumeData(newId, resumeBytes);
        }
      } catch (e) {
        debugPrint(
            '[TorrentSessionManager] Failed to load resume data on re-add: $e');
      }
      await _torrentService.resumeTorrent(newId);
      return newId;
    }
    return null;
  }

  /// Starts or resumes seeding for a completed torrent task.
  Future<void> startSeeding(DownloadTask task) async {
    if (task.pausedByUser || task.pauseReason == PauseReason.user) return;
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

  void dispose() {
    _torrentIds.clear();
    _latestStats.clear();
  }
}
