import 'dart:async';
import 'package:dmx/core/services/logging_service.dart';
import '../../../core/interfaces/i_download_engine.dart';
import '../../../core/services/torrent_service.dart';
import '../domain/ports/task_engine_port.dart';
import '../models/download_task.dart';

/// Adapter implementing [TaskEnginePort] to bridge domain commands to
/// concrete download engines (HTTP, Torrent, YouTube, Mux).
class DownloadEngineAdapter implements TaskEnginePort {
  // ignore: unused_field
  final IDownloadEngine _downloadEngine;
  final DownloadTask? Function(String id) _findTask;
  // ignore: unused_field
  final Future<void> Function(DownloadTask task) _saveTask;
  final void Function() _pumpQueueCallback;

  DownloadEngineAdapter({
    required IDownloadEngine downloadEngine,
    required DownloadTask? Function(String id) findTask,
    required Future<void> Function(DownloadTask task) saveTask,
    required void Function() pumpQueueCallback,
  })  : _downloadEngine = downloadEngine,
        _findTask = findTask,
        _saveTask = saveTask,
        _pumpQueueCallback = pumpQueueCallback;

  @override
  Future<void> startEngineTask(String taskId, {bool ignoreQueueLimit = false}) async {
    final task = _findTask(taskId);
    if (task == null) return;
    try {
      _pumpQueueCallback();
    } catch (e, st) {
      LoggingService.logger('DownloadEngineAdapter').warning('startEngineTask failed for $taskId', e, st);
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
    if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
      // Torrent task pause
      try {
        final torrentId = int.tryParse(task.id);
        if (torrentId != null) {
          TorrentService.pauseTorrent(torrentId);
        }
      } catch (e, st) {
        LoggingService.logger('DownloadEngineAdapter').warning('Torrent pause failed for $taskId', e, st);
      }
    }
  }

  @override
  Future<void> cancelEngineTask(String taskId, {bool deleteFiles = false}) async {
    final task = _findTask(taskId);
    if (task == null) return;
    if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
      try {
        final torrentId = int.tryParse(task.id);
        if (torrentId != null) {
          TorrentService.removeTorrent(torrentId, deleteFiles: deleteFiles);
        }
      } catch (e, st) {
        LoggingService.logger('DownloadEngineAdapter').warning('Torrent cancel failed for $taskId', e, st);
      }
    }
  }

  @override
  Future<void> retryEngineTask(String taskId) async {
    _pumpQueueCallback();
  }

  @override
  Future<void> deleteEngineTask(String taskId, {bool deleteFiles = false}) async {
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
    // Periodic stats update
  }
}
