import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../di/injection.dart';
import '../../interfaces/i_torrent_service.dart';
import '../download_engine.dart';
import '../logging_service.dart';
import '../power_monitor.dart';
import '../torrent_resume_store.dart';
import '../torrent_service.dart';

// FIX: P0-01 — TorrentDownloadHandler manages BitTorrent lifecycle & progress

final _log = LoggingService.logger('TorrentDownloadHandler');

/// Registry holding weak references to active TorrentDownloadHandlers
/// allowing retries/lookups to find active subscriptions without mutable static state.
class TorrentSubscriptionRegistry {
  TorrentSubscriptionRegistry._();
  static final TorrentSubscriptionRegistry instance =
      TorrentSubscriptionRegistry._();

  final Map<int, WeakReference<TorrentDownloadHandler>> _handlers = {};
  final Map<int, StreamSubscription> _subs = {};

  void register(
      int torrentId, TorrentDownloadHandler handler, StreamSubscription sub) {
    _handlers[torrentId] = WeakReference(handler);
    _subs[torrentId] = sub;
  }

  StreamSubscription? getSubscription(int torrentId) {
    final handler = _handlers[torrentId]?.target;
    if (handler == null) {
      _handlers.remove(torrentId);
      _subs.remove(torrentId);
      return null;
    }
    return _subs[torrentId];
  }

  void unregister(int torrentId, TorrentDownloadHandler handler) {
    final target = _handlers[torrentId]?.target;
    if (target == null || identical(target, handler)) {
      _handlers.remove(torrentId);
      _subs.remove(torrentId);
    }
  }

  @visibleForTesting
  void clear() {
    _handlers.clear();
    _subs.clear();
  }
}

class TorrentDownloadHandler {
  final ITorrentService _torrentService;
  final Set<int> _activeTorrentIds = {};
  final Map<int, StreamSubscription> _activeSubs = {};

  @visibleForTesting
  Map<int, StreamSubscription> get activeSubsForTesting => _activeSubs;

  @visibleForTesting
  static Map<int, StreamSubscription> get globalActiveSubsForTesting =>
      TorrentSubscriptionRegistry.instance._subs;
  DateTime lastProgressTick = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime lastAccurateSync = DateTime.fromMillisecondsSinceEpoch(0);
  List<Map<String, dynamic>>? cachedAccurateFiles;
  String lastStateLabel = '';

  TorrentDownloadHandler({ITorrentService? torrentService})
      : _torrentService = torrentService ??
            (getIt.isRegistered<ITorrentService>()
                ? getIt<ITorrentService>()
                : TorrentServiceImpl());

  Set<int> get activeTorrentIds => Set.unmodifiable(_activeTorrentIds);

  void removeActiveTorrent(int id) {
    _activeTorrentIds.remove(id);
    final sub = _activeSubs.remove(id);
    sub?.cancel();
    TorrentSubscriptionRegistry.instance.unregister(id, this);
  }

  @visibleForTesting
  static Duration computeAdaptiveSyncInterval(int fileCount, {bool inBackground = false}) {
    if (inBackground) return const Duration(seconds: 30);
    return Duration(milliseconds: max(4000, fileCount * 4));
  }

  @visibleForTesting
  static bool shouldSkipPerFileSync(int fileCount) => fileCount > 1000;

  static Map<String, dynamic> normalizeTorrentFile(Map<String, dynamic> f) {
    final len = (f['length'] as num?)?.toInt() ?? 0;
    var dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
    dl = len > 0 ? dl.clamp(0, len) : 0;
    final progress = len > 0 ? (dl / len).clamp(0.0, 1.0) : 1.0;

    f['name'] = f['name'] as String? ?? 'file';
    f['length'] = len;
    f['downloadedBytes'] = dl;
    f['selected'] = f['selected'] as bool? ?? true;
    f['priority'] = (f['priority'] as num?)?.toInt() ?? 4;
    f['speed'] = (f['speed'] as num?)?.toDouble() ?? 0.0;
    f['progress'] = progress;
    f['percent'] = progress;
    f['isComplete'] = len == 0 || dl >= len;
    return f;
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
      final norm = normalizeTorrentFile(f);
      if (isTorrentFileSelected(norm)) {
        final len = (norm['length'] as num?)?.toInt() ?? 0;
        final dl = (norm['downloadedBytes'] as num?)?.toInt() ?? 0;
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
    int confirmedBytes = 0;
    int totalNeedingSize = 0;
    final needing = <Map<String, dynamic>>[];

    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      final estimated = (f['progressEstimated'] as bool?) ?? true;
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final len = (f['length'] as num?)?.toInt() ?? 0;

      if (!estimated) {
        confirmedBytes += dl;
      } else if (dl < len) {
        needing.add(f);
        totalNeedingSize += len;
      }
    }

    if (needing.isEmpty) return;

    final remaining = max(0, totalDownloadedBytes - confirmedBytes);
    for (var i = 0; i < needing.length; i++) {
      final f = needing[i];
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
            } catch (e, st) {
              LoggingService.logger('TorrentDownloadHandler').warning('Operation failed', e, st);
            }
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
      } catch (e, st) {
        LoggingService.logger('TorrentDownloadHandler').warning('Operation failed', e, st);
      }
      await Future.delayed(const Duration(milliseconds: 200));
      List<Map<String, dynamic>>? pauseFiles = getTorrentFiles?.call();
      try {
        final accurateFiles =
            await TorrentService.getAccurateFileProgress(id, saveDir)
                .timeout(const Duration(milliseconds: 500));
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
      } catch (e, st) {
        LoggingService.logger('TorrentDownloadHandler').warning('Operation failed', e, st);
      }
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

    try {
      if (cancelToken.isCancelled) {
        try {
          TorrentService.pauseTorrent(id);
        } catch (e, st) {
          LoggingService.logger('TorrentDownloadHandler').warning('Operation failed', e, st);
        }
        throw DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel,
          message: 'Download paused',
        );
      }

      try {
        TorrentService.resumeTorrent(id);
      } catch (e, st) {
        LoggingService.logger('TorrentDownloadHandler').warning('Operation failed', e, st);
      }

      await _listenForCompletion(
        id,
        url,
        currentLocalFilePath,
        cancelToken,
        onProgress,
        getTorrentFiles: getTorrentFiles,
      );
      torrentCompleted = true;
    } finally {
      _activeSubs.remove(id);
      _activeTorrentIds.remove(id);
    }
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

    // Cancel any existing subscription for this torrent ID before attaching a new one
    final existingSub = _activeSubs.remove(id) ??
        TorrentSubscriptionRegistry.instance.getSubscription(id);
    await existingSub?.cancel();
    TorrentSubscriptionRegistry.instance.unregister(id, this);

    lastProgressTick = DateTime.fromMillisecondsSinceEpoch(0);
    lastAccurateSync = DateTime.fromMillisecondsSinceEpoch(0);
    cachedAccurateFiles = null;
    lastStateLabel = '';

    try {
      sub = _torrentService.torrentUpdates.listen((torrents) async {
        final torrent = torrents[id];
        if (torrent == null) {
          if (!_torrentService.isTorrentAlive(id)) {
            sub?.cancel();
            _activeSubs.remove(id);
            _activeTorrentIds.remove(id);
            TorrentSubscriptionRegistry.instance.unregister(id, this);
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
        final fileCount =
            resolvedFiles?.length ?? cachedAccurateFiles?.length ?? 0;
        final skipPerFileSync = shouldSkipPerFileSync(fileCount);
        if (!isCheckingOrMetadata &&
            torrent.hasMetadata &&
            !PowerMonitor.screenOff &&
            !skipPerFileSync) {
          final syncInterval = computeAdaptiveSyncInterval(
            fileCount,
            inBackground: DownloadEngine.isInBackground,
          );

          if (now.difference(lastAccurateSync) >= syncInterval ||
              cachedAccurateFiles == null) {
            lastAccurateSync = now;
            try {
              final accurate =
                  await _torrentService.getAccurateFileProgress(id, saveDir);
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
            } catch (e, st) {
              LoggingService.logger('TorrentDownloadHandler')
                  .warning('Accurate file progress error', e, st);
            }
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

        int perFileSum = 0;
        if (resolvedFiles != null) {
          for (var i = 0; i < resolvedFiles.length; i++) {
            final f = resolvedFiles[i];
            final len = (f['length'] as num?)?.toInt() ?? 0;
            var dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
            if (len > 0) {
              dl = dl.clamp(0, len);
              f['downloadedBytes'] = dl;
              f['progress'] = (dl / len).clamp(0.0, 1.0);
            }
            perFileSum += dl;
          }
        }
        final downloadedBytes = perFileSum > 0 ? perFileSum : rawDownloaded;
        final speed = torrent.downloadPayloadRate.toDouble();

        onProgress(DownloadProgress(
          downloadedBytes: downloadedBytes,
          fileSize: totalSize,
          speed: speed,
          eta: null,
          torrentFiles: resolvedFiles ?? cachedAccurateFiles,
          cycleState: 'downloading',
          statusMessage: torrent.stateLabel,
          torrentId: id,
        ));

        if (stateLabel == 'seeding' ||
            (totalSize > 0 && downloadedBytes >= totalSize)) {
          sub?.cancel();
          _activeSubs.remove(id);
          _activeTorrentIds.remove(id);
          TorrentSubscriptionRegistry.instance.unregister(id, this);
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
      });

      _activeSubs[id] = sub;
      TorrentSubscriptionRegistry.instance.register(id, this, sub);

      cancelToken.whenCancel.then((_) {
        sub?.cancel();
        _activeSubs.remove(id);
        _activeTorrentIds.remove(id);
        TorrentSubscriptionRegistry.instance.unregister(id, this);
        if (!completer.isCompleted) {
          completer.completeError(DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
            message: 'Torrent paused',
          ));
        }
      });

      await completer.future;
    } finally {
      await sub?.cancel();
      _activeSubs.remove(id);
      TorrentSubscriptionRegistry.instance.unregister(id, this);
    }
  }
}
