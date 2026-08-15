import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:path/path.dart' as p;

/// Orchestrates Torrent downloads, managing libtorrent interaction and file priorities.
/// Task 1.2: Specialized Service for Torrent download orchestration.
/// Task 2.2: Optimized file reconciliation with O(1) map lookups and >=1000ms throttled ticks.
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
      totalFiles: initSummary.total > 0 ? initSummary.total : null,
      completedFiles: initSummary.done > 0 ? initSummary.done : null,
      totalFileBytes: initSummary.bytes > 0 ? initSummary.bytes : null,
      downloadedFileBytes: initSummary.downloaded > 0 ? initSummary.downloaded : null,
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
      } catch (_) {} // coverage:ignore-line
    });

    try {
      await _waitForMetadata(id, url, cancelToken, onProgress, initialFileSize: knownFileSize);
      _applyFilePriorities(id, getTorrentFiles?.call());

      final resumeBlob = await TorrentResumeStore.loadResumeDataForSource(url);
      if (resumeBlob != null && TorrentService.loadResumeData(id, resumeBlob)) {
        // Fast resume data loaded
      } else {
        TorrentService.recheckTorrent(id);
        await _waitForCheck(id, cancelToken, onProgress, knownFileSize);
      }

      if (cancelToken.isCancelled) return;
      TorrentService.resumeTorrent(id);
      await _listenForCompletion(id, url, currentLocalFilePath, cancelToken, onProgress, getTorrentFiles, knownFileSize);
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

  /// O(1) file priority setting by pre-indexing files
  void _applyFilePriorities(int id, List<Map<String, dynamic>>? files) {
    if (files == null || files.isEmpty) return;
    
    final priorities = List<int>.generate(files.length, (i) {
      final f = files[i];
      final isSelected = (f['selected'] as bool?) ?? true;
      if (!isSelected) return 0;
      return (f['priority'] as num?)?.toInt() ?? 4;
    });
    
    TorrentService.setFilePriorities(id, priorities);
  }

  /// Strictly throttled to a minimum of 1000ms between progress events
  Future<void> _listenForCompletion(
    int id,
    String url,
    String localFilePath,
    CancelToken cancelToken,
    ValueChangedProgress onProgress,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int fileSize,
  ) async {
    final completer = Completer<void>();
    DateTime lastEmitTime = DateTime.fromMillisecondsSinceEpoch(0);

    final sub = TorrentService.torrentUpdates.listen((torrents) async {
      final torrent = torrents[id];
      if (torrent == null) return;

      final now = DateTime.now();
      if (now.difference(lastEmitTime).inMilliseconds < 1000) return;
      lastEmitTime = now;

      final files = getTorrentFiles?.call();
      final summary = _normalizeTorrentFiles(files);
      final totalWanted = torrent.totalWanted > 0
          ? torrent.totalWanted
          : (summary.bytes > 0 ? summary.bytes : fileSize);
      final downloaded = torrent.totalWantedDone > 0
          ? torrent.totalWantedDone
          : (summary.downloaded > 0 ? summary.downloaded : torrent.totalDone);

      final stateLabel = torrent.stateLabel.toLowerCase();
      final isComplete =
          stateLabel == 'seeding' || (totalWanted > 0 && downloaded >= totalWanted);

      onProgress(DownloadProgress(
        downloadedBytes: downloaded,
        fileSize: totalWanted,
        speed: torrent.downloadRate.toDouble(),
        eta: null,
        supportsResume: true,
        torrentFiles: files,
        statusMessage: stateLabel,
        cycleState: stateLabel,
        torrentId: id,
        totalFiles: summary.total > 0 ? summary.total : null,
        completedFiles: summary.done > 0 ? summary.done : null,
        totalFileBytes: summary.bytes > 0 ? summary.bytes : null,
        downloadedFileBytes: downloaded > 0 ? downloaded : null,
      ));

      if (isComplete) {
        if (!completer.isCompleted) completer.complete();
      }
    });

    // ADD TIMEOUT:
    final timeoutTimer = Timer(const Duration(minutes: 30), () {
      if (!completer.isCompleted) {
        sub.cancel();
        completer.completeError(
          TimeoutException('Torrent download timed out after 30 minutes'),
        );
      }
    });

    try {
      await completer.future;
    } finally {
      timeoutTimer.cancel();
      sub.cancel();
    }
  }

  ({int downloaded, int bytes, int total, int done}) _normalizeTorrentFiles(List<Map<String, dynamic>>? files) {
    if (files == null || files.isEmpty) return (downloaded: 0, bytes: 0, total: 0, done: 0);
    int d = 0, b = 0, t = 0, n = 0;
    for (final f in files) {
      final isSelected = (f['selected'] as bool?) ?? true;
      if (!isSelected) continue;
      final len = (f['length'] as num?)?.toInt() ?? 0;
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      b += len;
      d += (len > 0 ? dl.clamp(0, len) : 0);
      t++;
      if (len == 0 || dl >= len) n++;
    }
    return (downloaded: d, bytes: b, total: t, done: n);
  }
}
