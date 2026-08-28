import 'dart:async';
import 'package:dmx/core/services/logging_service.dart';
import '../../../core/interfaces/i_download_engine.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/utils/torrent_id_resolver.dart';
import '../domain/ports/task_engine_port.dart';
import '../models/download_task.dart';

/// Adapter implementing [TaskEnginePort] to bridge domain commands to
/// concrete download engines (HTTP, Torrent, YouTube, Mux).
class DownloadEngineAdapter implements TaskEnginePort {
  // ignore: unused_field
  final IDownloadEngine _downloadEngine;
  final DownloadTask? Function(String id) _findTask;
  final int? Function(String taskId)? _torrentIdForTask;
  // ignore: unused_field
  final Future<void> Function(DownloadTask task) _saveTask;
  final void Function() _pumpQueueCallback;

  DownloadEngineAdapter({
    required IDownloadEngine downloadEngine,
    required DownloadTask? Function(String id) findTask,
    required Future<void> Function(DownloadTask task) saveTask,
    required void Function() pumpQueueCallback,
    int? Function(String taskId)? torrentIdForTask,
  })  : _downloadEngine = downloadEngine,
        _findTask = findTask,
        _saveTask = saveTask,
        _pumpQueueCallback = pumpQueueCallback,
        _torrentIdForTask = torrentIdForTask;

  int? _nativeTorrentId(DownloadTask task) {
    final mapped = _torrentIdForTask?.call(task.id);
    if (mapped != null && mapped >= 0) return mapped;
    return TorrentIdResolver.resolve(task);
  }

  @override
  Future<void> startEngineTask(String taskId,
      {bool ignoreQueueLimit = false}) async {
    final task = _findTask(taskId);
    if (task == null) return;
    try {
      _pumpQueueCallback();
    } catch (e, st) {
      LoggingService.logger('DownloadEngineAdapter')
          .warning('startEngineTask failed for ', e, st);
    }
  }

  @override
  Future<void> pauseEngineTask(
    String taskId, {
    String? reason,
    bool userInitiated = true,
  }) async {
    final task = _findTask(taskId);
    if (task == null) return;
    // A magnet has no torrentFiles until metadata arrives. Use the source
    // type instead of the file list so pause works during metadata fetching.
    if (task.isTorrent) {
      // Torrent task pause
      try {
        final torrentId = _nativeTorrentId(task);
        if (torrentId != null) {
          await TorrentService.pauseTorrent(torrentId);
        }
      } catch (e, st) {
        LoggingService.logger('DownloadEngineAdapter')
            .warning('Torrent pause failed for ', e, st);
      }
    }
  }

  @override
  Future<void> cancelEngineTask(String taskId,
      {bool deleteFiles = false}) async {
    final task = _findTask(taskId);
    if (task == null) return;
    // The same applies to cancel/delete while a magnet is still resolving.
    if (task.isTorrent) {
      try {
        final torrentId = _nativeTorrentId(task);
        if (torrentId != null) {
          TorrentService.removeTorrent(torrentId, deleteFiles: deleteFiles);
        }
      } catch (e, st) {
        LoggingService.logger('DownloadEngineAdapter')
            .warning('Torrent cancel failed for ', e, st);
      }
    }
  }

  @override
  Future<void> retryEngineTask(String taskId) async {
    _pumpQueueCallback();
  }

  @override
  Future<void> deleteEngineTask(String taskId,
      {bool deleteFiles = false}) async {
    await cancelEngineTask(taskId, deleteFiles: deleteFiles);
  }

  @override
  Future<void> pumpQueue() async {
    _pumpQueueCallback();
  }

  @override
  Future<void> handleNetworkChanged({
    required bool isConnected,
    required bool isWifi,
  }) async {
    _pumpQueueCallback();
  }

  @override
  Future<void> handleAppLifecycleChanged(dynamic state) async {
    // App lifecycle handler
  }

  @override
  Future<void> handleTorrentStats(String taskId, dynamic stats) async {
    // Torrent stats update handler
  }
}
