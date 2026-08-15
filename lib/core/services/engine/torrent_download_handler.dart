import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import '../download_engine.dart';
import '../logging_service.dart';
import '../power_monitor.dart';
import '../torrent_resume_store.dart';
import '../torrent_service.dart';

// FIX: P0-01 — TorrentDownloadHandler manages BitTorrent lifecycle & progress

final _log = LoggingService.logger('TorrentDownloadHandler');

class TorrentDownloadHandler {
  final Set<int> _activeTorrentIds = {};

  TorrentDownloadHandler();

  Set<int> get activeTorrentIds => Set.unmodifiable(_activeTorrentIds);

  void removeActiveTorrent(int id) => _activeTorrentIds.remove(id);

  static void normalizeTorrentFile(Map<String, dynamic> f) {
    f['name'] = f['name'] as String? ?? 'file';
    final len = (f['length'] as num?)?.toInt() ?? 0;
    f['length'] = len;
    var dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
    dl = len > 0 ? dl.clamp(0, len) : 0;
    f['downloadedBytes'] = dl;
    f['selected'] = f['selected'] as bool? ?? true;
    f['priority'] = (f['priority'] as num?)?.toInt() ?? 4;
    f['speed'] = (f['speed'] as num?)?.toDouble() ?? 0.0;
    f['progress'] = len > 0 ? (dl / len).clamp(0.0, 1.0) : 1.0;
    f['percent'] = f['progress'];
    f['isComplete'] = len == 0 || dl >= len;
  }

  static bool isTorrentFileSelected(Map<String, dynamic> f) =>
      (f['selected'] as bool?) ?? true;

  static ({int total, int done, int bytes, int downloaded})
      normalizeTorrentFiles(List<Map<String, dynamic>>? files) {
    if (files == null || files.isEmpty) {
      return (total: 0, done: 0, bytes: 0, downloaded: 0);
    }
    int total = 0, done = 0, bytes = 0, downloaded = 0;
    for (final f in files) {
      normalizeTorrentFile(f);
      if (isTorrentFileSelected(f)) {
        final len = (f['length'] as num?)?.toInt() ?? 0;
        final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        total++;
        bytes += len;
        downloaded += dl;
        if (len == 0 || dl >= len) done++;
      }
    }
    return (total: total, done: done, bytes: bytes, downloaded: downloaded);
  }

  static void distributeEstimatedBytes(
      List<Map<String, dynamic>> files, int totalDownloadedBytes) {
    final needing = files.where((f) {
      final estimated = (f['progressEstimated'] as bool?) ?? true;
      if (!estimated) return false;
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final len = (f['length'] as num?)?.toInt() ?? 0;
      return dl < len;
    }).toList();

    if (needing.isEmpty) return;

    int confirmedBytes = 0;
    for (final f in files) {
      if ((f['progressEstimated'] as bool?) == false) {
        confirmedBytes += (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      }
    }
    final remaining = max(0, totalDownloadedBytes - confirmedBytes);
    final totalNeedingSize = needing.fold<int>(
        0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0));

    for (final f in needing) {
      final length = (f['length'] as num?)?.toInt() ?? 0;
      if (length <= 0) {
        f['downloadedBytes'] = 0;
      } else if (totalNeedingSize > 0 && remaining > 0) {
        final est = ((length / totalNeedingSize) * remaining).round();
        f['downloadedBytes'] = est.clamp(0, length);
      } else {
        final prev = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        f['downloadedBytes'] = prev.clamp(0, length);
      }
      f['progressEstimated'] = true;
    }
  }

  Future<void> handleTorrentDownload({
    required String taskId,
    required String url,
    required String currentLocalFilePath,
    required int knownFileSize,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    required Dio Function(String url) clientBuilder,
    required void Function(Dio client) clientReleaser,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool isRetry = false,
  }) async {
    final initFiles = getTorrentFiles?.call();
    final initSummary = normalizeTorrentFiles(initFiles);
    final saveDir = File(currentLocalFilePath).parent.path;

    onProgress(DownloadProgress(
      downloadedBytes: initSummary.downloaded,
      fileSize: initSummary.bytes > 0 ? initSummary.bytes : knownFileSize,
      speed: 0,
      eta: null,
      supportsResume: true,
      torrentFiles: initFiles,
      statusMessage: isRetry
          ? 'Retrying torrent…'
          : (initSummary.downloaded > 0
              ? 'Resuming torrent…'
              : 'Starting torrent…'),
      cycleState: isRetry
          ? 'retrying'
          : (initSummary.downloaded > 0 ? 'resuming' : 'starting'),
      torrentId: torrentId,
      totalFiles: initSummary.total > 0 ? initSummary.total : null,
      completedFiles: initSummary.total > 0 ? initSummary.done : null,
      totalFileBytes: initSummary.bytes > 0 ? initSummary.bytes : null,
      downloadedFileBytes:
          initSummary.bytes > 0 ? initSummary.downloaded : null,
    ));

    int id = torrentId ?? -1;
    if (id >= 0 && !TorrentService.isTorrentAlive(id)) {
      _log.warning('Stale torrent handle $id detected; re-adding.');
      _activeTorrentIds.remove(id);
      id = -1;
    }

    if (id == -1) {
      final dir = Directory(saveDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      if (url.startsWith('magnet:')) {
        id = TorrentService.addMagnet(url, saveDir);
      } else {
        String filePath = url;
        if (url.startsWith('file://')) {
          filePath = Uri.parse(url).toFilePath();
        } else if (url.startsWith('http://') || url.startsWith('https://')) {
          final tempTorrentPath = p.join(
            Directory.systemTemp.path,
            'temp_${DateTime.now().millisecondsSinceEpoch}.torrent',
          );
          final tempTorrentFile = File(tempTorrentPath);
          final torrentDio = clientBuilder(url);
          try {
            await torrentDio.download(url, tempTorrentPath);
            filePath = tempTorrentPath;
            id = TorrentService.addTorrentFile(filePath, saveDir, sourceKey: url);
          } finally {
            clientReleaser(torrentDio);
            try {
              if (await tempTorrentFile.exists()) {
                await tempTorrentFile.delete();
              }
            } catch (_) {} // coverage:ignore-line
          }
        } else {
          id = TorrentService.addTorrentFile(filePath, saveDir, sourceKey: url);
        }
      }
    }

    if (id < 0) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.unknown,
        error: 'Torrent engine rejected the torrent.',
      );
    }

    TorrentResumeStore.registerSource(id, url);
    _activeTorrentIds.add(id);
    bool torrentCompleted = false;

    cancelToken.whenCancel.then((_) async {
      if (torrentCompleted) return;
      try {
        TorrentService.pauseTorrent(id);
      } catch (_) {} // coverage:ignore-line
      await Future.delayed(const Duration(milliseconds: 200));
      List<Map<String, dynamic>>? pauseFiles = getTorrentFiles?.call();
      try {
        final accurateFiles =
            await TorrentService.getAccurateFileProgress(id, saveDir);
        if (accurateFiles.isNotEmpty) {
          pauseFiles = accurateFiles
              .map((f) => {
                    'name': f.name,
                    'length': f.size,
                    'downloadedBytes': f.downloadedBytes,
                    'selected': true,
                    'priority': 4,
                    'progress': f.progress,
                    'percent': f.progress,
                    'isComplete': f.isComplete,
                    'progressEstimated': false,
                  })
              .toList();
        }
      } catch (_) {} // coverage:ignore-line
      final pauseSummary = normalizeTorrentFiles(pauseFiles);
      onProgress(DownloadProgress(
        downloadedBytes: pauseSummary.downloaded,
        fileSize: pauseSummary.bytes > 0 ? pauseSummary.bytes : knownFileSize,
        speed: 0,
        eta: null,
        supportsResume: true,
        torrentFiles: pauseFiles,
        statusMessage: 'Paused',
        cycleState: 'paused',
        torrentId: id,
        totalFiles: pauseSummary.total > 0 ? pauseSummary.total : null,
        completedFiles: pauseSummary.total > 0 ? pauseSummary.done : null,
        totalFileBytes: pauseSummary.bytes > 0 ? pauseSummary.bytes : null,
        downloadedFileBytes:
            pauseSummary.bytes > 0 ? pauseSummary.downloaded : null,
      ));
    });

    if (cancelToken.isCancelled) {
      try {
        TorrentService.pauseTorrent(id);
      } catch (_) {} // coverage:ignore-line
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.cancel,
        message: 'Download paused',
      );
    }

    try {
      TorrentService.resumeTorrent(id);
    } catch (_) {} // coverage:ignore-line

    await _listenForCompletion(
      id,
      url,
      currentLocalFilePath,
      cancelToken,
      onProgress,
      getTorrentFiles: getTorrentFiles,
    );
    torrentCompleted = true;
  }

  Future<void> _listenForCompletion(
    int id,
    String url,
    String localFilePath,
    CancelToken cancelToken,
    ValueChangedProgress onProgress, {
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
  }) async {
    final completer = Completer<void>();
    StreamSubscription? sub;
    final saveDir = File(localFilePath).parent.path;
    DateTime lastProgressTick = DateTime.fromMillisecondsSinceEpoch(0);
    DateTime lastAccurateSync = DateTime.fromMillisecondsSinceEpoch(0);
    List<Map<String, dynamic>>? cachedAccurateFiles;
    String lastStateLabel = '';

    sub = TorrentService.torrentUpdates.listen((torrents) async {
      final torrent = torrents[id];
      if (torrent == null) {
        if (!TorrentService.isTorrentAlive(id)) {
          sub?.cancel();
          _activeTorrentIds.remove(id);
          if (!completer.isCompleted) {
            completer.completeError(DioException(
              requestOptions: RequestOptions(path: url),
              type: DioExceptionType.unknown,
              error: 'Torrent handle lost.',
            ));
          }
        }
        return;
      }

      final stateLabel = torrent.stateLabel.toLowerCase();
      final isStateChange = stateLabel != lastStateLabel;
      final isTerminal = stateLabel == 'seeding' ||
          stateLabel == 'paused' ||
          stateLabel == 'stopped' ||
          stateLabel == 'error';
      final now = DateTime.now();
      if (!isTerminal &&
          !isStateChange &&
          now.difference(lastProgressTick) < const Duration(milliseconds: 750)) {
        return;
      }
      lastProgressTick = now;
      lastStateLabel = stateLabel;

      final isCheckingOrMetadata = stateLabel == 'checking' ||
          stateLabel == 'downloading_metadata' ||
          stateLabel == 'queued_for_checking' ||
          !torrent.hasMetadata;

      List<Map<String, dynamic>>? resolvedFiles = getTorrentFiles?.call();
      final cachedFileCount = cachedAccurateFiles?.length ?? 0;
      // FIX-BG-05: Large torrents skip expensive per-file progress queries.
      final skipPerFileSync = cachedFileCount > 1000;
      if (!isCheckingOrMetadata &&
          torrent.hasMetadata &&
          !PowerMonitor.screenOff &&
          !skipPerFileSync) {
        // FIX-P1-02 / FIX-BG-04: Throttle accurate file progress (4s foreground, 30s background)
        final syncInterval = DownloadEngine.isInBackground
            ? const Duration(seconds: 30)
            : const Duration(seconds: 4);

        if (now.difference(lastAccurateSync) >= syncInterval || cachedAccurateFiles == null) {
          lastAccurateSync = now;
          try {
            final accurate =
                await TorrentService.getAccurateFileProgress(id, saveDir);
            if (accurate.isNotEmpty) {
              cachedAccurateFiles = accurate
                  .map((f) => {
                        'name': f.name,
                        'length': f.size,
                        'downloadedBytes': f.downloadedBytes,
                        'selected': true,
                        'priority': 4,
                        'progress': f.progress,
                        'percent': f.progress,
                        'isComplete': f.isComplete,
                        'progressEstimated': false,
                      })
                  .toList();
            }
          } catch (_) {} // coverage:ignore-line
        }
        if (cachedAccurateFiles != null) {
          resolvedFiles = cachedAccurateFiles;
        }
      }

      final totalWanted = torrent.totalWanted;
      final totalSize = totalWanted > 0
          ? totalWanted
          : (resolvedFiles?.fold<int>(
                  0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0)) ??
              0);

      final torrentAggregate = torrent.totalWantedDone > 0
          ? torrent.totalWantedDone
          : (torrent.totalDone > 0 ? torrent.totalDone : 0);

      final rawDownloaded = torrentAggregate > 0 ? torrentAggregate : 0;
      if (rawDownloaded > 0 && resolvedFiles != null) {
        distributeEstimatedBytes(resolvedFiles, rawDownloaded);
      }

      final perFileSum = resolvedFiles?.fold<int>(
              0, (s, f) => s + ((f['downloadedBytes'] as num?)?.toInt() ?? 0)) ??
          0;
      final downloadedBytes = perFileSum > 0 ? perFileSum : rawDownloaded;

      if (resolvedFiles != null) {
        for (final f in resolvedFiles) {
          final len = (f['length'] as num?)?.toInt() ?? 0;
          var dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
          if (len > 0) {
            dl = dl.clamp(0, len);
            f['downloadedBytes'] = dl;
            f['progress'] = (dl / len).clamp(0.0, 1.0);
          }
        }
      }

      if (stateLabel == 'seeding' ||
          (totalSize > 0 && downloadedBytes >= totalSize)) {
        sub?.cancel();
        _activeTorrentIds.remove(id);
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    });

    cancelToken.whenCancel.then((_) {
      sub?.cancel();
      _activeTorrentIds.remove(id);
      if (!completer.isCompleted) {
        completer.completeError(DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel,
          message: 'Torrent paused',
        ));
      }
    });

    return completer.future;
  }
}
