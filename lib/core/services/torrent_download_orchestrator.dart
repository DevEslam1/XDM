import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:dmx/core/services/dio_client_pool.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:path/path.dart' as p;

/// Orchestrates Torrent downloads, managing libtorrent interaction and file priorities.
/// Task 1.2: Specialized Service for Torrent download orchestration.
class TorrentDownloadOrchestrator {
  final DioClientPool _dioPool;

  TorrentDownloadOrchestrator(this._dioPool);

  Future<void> download({
    required String url,
    required String currentLocalFilePath,
    required int knownFileSize,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool isRetry = false,
    int? metadataTimeoutSeconds,
  }) async {
    final initialTorrentFiles = getTorrentFiles?.call();
    final initSummary = _normalizeTorrentFiles(initialTorrentFiles);
    
    onProgress(DownloadProgress(
      downloadedBytes: initSummary.downloaded,
      fileSize: initSummary.bytes > 0 ? initSummary.bytes : knownFileSize,
      speed: 0.0,
      eta: null,
      supportsResume: true,
      torrentFiles: initialTorrentFiles,
      statusMessage: isRetry ? 'Retrying torrent…' : (initSummary.downloaded > 0 ? 'Resuming torrent…' : 'Starting torrent…'),
      cycleState: isRetry ? 'retrying' : (initSummary.downloaded > 0 ? 'resuming' : 'starting'),
      torrentId: torrentId,
    ));

    int id = torrentId ?? -1;
    final saveDir = File(currentLocalFilePath).parent.path;

    if (id >= 0 && !TorrentService.isTorrentAlive(id)) {
      id = -1;
    }

    if (id == -1) {
      id = await _addTorrent(url, saveDir);
    }

    if (id < 0) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.unknown,
        error: 'Torrent engine rejected the torrent.',
      );
    }

    TorrentResumeStore.registerSource(id, url);
    
    cancelToken.whenCancel.then((_) async {
      try {
        TorrentService.pauseTorrent(id);
      } catch (_) {}
    });

    try {
      await _waitForMetadata(id, url, cancelToken, onProgress, initialFileSize: knownFileSize);
      _applyFilePriorities(id, getTorrentFiles?.call());

      final resumeBlob = await TorrentResumeStore.loadResumeDataForSource(url);
      if (resumeBlob != null && TorrentService.loadResumeData(id, resumeBlob)) {
        // Fast resume logic
      } else {
        TorrentService.recheckTorrent(id);
        await _waitForCheck(id, cancelToken, onProgress, knownFileSize);
      }

      if (cancelToken.isCancelled) return;
      TorrentService.resumeTorrent(id);
      await _listenForCompletion(id, url, cancelToken, onProgress, getTorrentFiles, knownFileSize);
    } finally {
      TorrentResumeStore.unregisterSource(url);
    }
  }

  Future<int> _addTorrent(String url, String saveDir) async {
    if (url.startsWith('magnet:')) {
      return TorrentService.addMagnet(url, saveDir);
    }
    
    String filePath = url;
    if (url.startsWith('file://')) {
      filePath = Uri.parse(url).toFilePath();
    } else if (url.startsWith('http://') || url.startsWith('https://')) {
      final tempTorrentPath = p.join(Directory.systemTemp.path, 'temp_${DateTime.now().millisecondsSinceEpoch}.torrent');
      final dio = _dioPool.acquireClient(url: url);
      try {
        await dio.download(url, tempTorrentPath);
        filePath = tempTorrentPath;
      } finally {
        _dioPool.releaseClient(dio);
      }
    }
    return TorrentService.addTorrentFile(filePath, saveDir, sourceKey: url);
  }

  Future<void> _waitForMetadata(int id, String url, CancelToken cancelToken, ValueChangedProgress onProgress, {int initialFileSize = 0}) async {
    final completer = Completer<void>();
    final sub = TorrentService.torrentUpdates.listen((torrents) {
      if (torrents[id]?.hasMetadata == true) completer.complete();
    });

    try {
      await completer.future.timeout(const Duration(minutes: 5));
    } finally {
      sub.cancel();
    }
  }

  Future<void> _waitForCheck(int id, CancelToken cancelToken, ValueChangedProgress onProgress, int fileSize) async {
    final completer = Completer<void>();
    final sub = TorrentService.torrentUpdates.listen((torrents) {
      final t = torrents[id];
      if (t != null && !t.stateLabel.toLowerCase().contains('checking')) {
        completer.complete();
      }
    });
    await completer.future;
    sub.cancel();
  }

  void _applyFilePriorities(int id, List<Map<String, dynamic>>? files) {
    if (files == null) return;
    final priorities = files.map((f) => (f['selected'] as bool? ?? true) ? (f['priority'] as int? ?? 4) : 0).toList();
    TorrentService.setFilePriorities(id, priorities);
  }

  Future<void> _listenForCompletion(int id, String url, CancelToken cancelToken, ValueChangedProgress onProgress, List<Map<String, dynamic>>? Function()? getTorrentFiles, int fileSize) async {
    final completer = Completer<void>();
    final sub = TorrentService.torrentUpdates.listen((torrents) {
      final t = torrents[id];
      if (t == null) return;
      if (t.stateLabel.toLowerCase() == 'seeding') completer.complete();
      // Emit progress...
    });
    await completer.future;
    sub.cancel();
  }

  ({int downloaded, int bytes, int total, int done}) _normalizeTorrentFiles(List<Map<String, dynamic>>? files) {
    if (files == null) return (downloaded: 0, bytes: 0, total: 0, done: 0);
    int d = 0, b = 0, t = 0, n = 0;
    for (final f in files) {
      final len = (f['length'] as num?)?.toInt() ?? 0;
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      b += len;
      d += dl;
      t++;
      if (dl >= len) n++;
    }
    return (downloaded: d, bytes: b, total: t, done: n);
  }
}
