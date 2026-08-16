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

  static PauseReason _inferPauseReason(String? message) {
    if (message == null) return PauseReason.userRequested;
    final m = message.toLowerCase();
    if (m.contains('network') || m.contains('connection')) return PauseReason.networkLost;
    if (m.contains('battery')) return PauseReason.batteryLow;
    if (m.contains('schedule')) return PauseReason.scheduled;
    return PauseReason.userRequested;
  }

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

  static void _reconcileEstimatedFiles(
    List<Map<String, dynamic>> files,
    int totalDownloadedBytes,
  ) {
    if (totalDownloadedBytes <= 0 || files.isEmpty) return;
    int currentSum = 0;
    Map<String, dynamic>? largestEstimatedFile;
    int largestLen = -1;

    for (final f in files) {
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      currentSum += dl;
      final estimated = (f['progressEstimated'] as bool?) ?? false;
      final len = (f['length'] as num?)?.toInt() ?? 0;
      if (estimated && len > largestLen) {
        largestLen = len;
        largestEstimatedFile = f;
      }
    }

    final diff = totalDownloadedBytes - currentSum;
    if (diff != 0 && largestEstimatedFile != null) {
      final len = (largestEstimatedFile['length'] as num?)?.toInt() ?? 0;
      final dl = (largestEstimatedFile['downloadedBytes'] as num?)?.toInt() ?? 0;
      final newDl = (dl + diff).clamp(0, len);
      largestEstimatedFile['downloadedBytes'] = newDl;
      largestEstimatedFile['progress'] =
          len > 0 ? (newDl / len).clamp(0.0, 1.0) : 1.0;
      largestEstimatedFile['isComplete'] = len == 0 || newDl >= len;
    }
  }

  /// Updates per-file progress in memory directly from native engine progress
  /// without disk I/O scanning.
  static void updateFilesWithNativeProgress(
    List<Map<String, dynamic>> files,
    double progress,
    int totalDownloadedBytes,
  ) {
    if (files.isEmpty) return;
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      final len = (f['length'] as num?)?.toInt() ?? 0;
      if (len <= 0) {
        f['downloadedBytes'] = 0;
        f['progress'] = 1.0;
        f['isComplete'] = true;
        f['progressEstimated'] = false;
        continue;
      }

      // If downloaded bytes is already set accurately by native engine, use it
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? -1;
      if (dl >= 0 && dl <= len) {
        f['progress'] = (dl / len).clamp(0.0, 1.0);
        f['isComplete'] = dl >= len;
      } else {
        // Compute from overall progress ratio
        final est = (len * progress).clamp(0.0, len.toDouble()).toInt();
        f['downloadedBytes'] = est;
        f['progress'] = len > 0 ? (est / len).clamp(0.0, 1.0) : 1.0;
        f['isComplete'] = est >= len;
        f['progressEstimated'] = true;
      }
    }
    // Fix 6 & 7: Check sequentialDownloadEnabled and distribute estimated bytes accordingly
    if (TorrentService.sequentialDownloadEnabled) {
      distributeEstimatedBytesSequential(files, totalDownloadedBytes);
    } else {
      distributeEstimatedBytes(files, totalDownloadedBytes);
    }
  }

  static void distributeEstimatedBytesSequential(
      List<Map<String, dynamic>> files, int totalDownloadedBytes) {
    int remaining = totalDownloadedBytes;
    for (final f in files) {
      if (!isTorrentFileSelected(f)) continue;
      final len = (f['length'] as num?)?.toInt() ?? 0;
      if (len <= 0) continue;
      final dl = remaining >= len ? len : remaining;
      f['downloadedBytes'] = dl;
      f['progress'] = len > 0 ? (dl / len).clamp(0.0, 1.0) : 1.0;
      f['isComplete'] = dl >= len;
      f['progressEstimated'] = true;
      remaining -= dl;
      if (remaining <= 0) break;
    }
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
        f['progressEstimated'] = true;
      } else {
        final prev = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        f['downloadedBytes'] = prev.clamp(0, length);
      }
    }
    _reconcileEstimatedFiles(files, totalDownloadedBytes);
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
          ? CycleState.retrying
          : (initSummary.downloaded > 0
              ? CycleState.resuming
              : CycleState.starting),
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
        onProgress(DownloadProgress(
          downloadedBytes: 0,
          fileSize: knownFileSize,
          speed: 0,
          eta: null,
          supportsResume: true,
          statusMessage: 'Fetching metadata…',
          cycleState: CycleState.fetchingMetadata,
          torrentId: torrentId,
        ));
        // Fix 3: Emit failed cycle on torrent magnet metadata timeout
        try {
          id = await TorrentService.addMagnetWithMetadataTimeout(
            url,
            saveDir,
            onStatusUpdate: (message) {
              onProgress(DownloadProgress(
                downloadedBytes: 0,
                fileSize: knownFileSize,
                speed: 0,
                eta: null,
                supportsResume: true,
                statusMessage: message,
                cycleState: CycleState.fetchingMetadata,
                torrentId: torrentId,
              ));
            },
          );
        } catch (e) {
          onProgress(DownloadProgress(
            downloadedBytes: 0,
            fileSize: knownFileSize,
            speed: 0,
            eta: null,
            supportsResume: true,
            statusMessage: 'Failed: Metadata fetch timeout',
            cycleState: CycleState.failed,
            torrentId: torrentId,
          ));
          rethrow;
        }
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

      if (id >= 0 && await TorrentService.hasResumeData(url)) {
        final resumeBytes = TorrentService.fetchResumeBytes(id) ??
            await TorrentResumeStore.loadResumeDataForSource(url);
        if (resumeBytes != null) {
          TorrentService.loadResumeData(id, resumeBytes.toList());
        }
      }
    }

    if (id < 0) {
      onProgress(DownloadProgress(
        downloadedBytes: initSummary.downloaded,
        fileSize: initSummary.bytes > 0 ? initSummary.bytes : knownFileSize,
        speed: 0,
        eta: null,
        supportsResume: true,
        torrentFiles: initFiles,
        statusMessage: 'Failed: Torrent engine rejected the torrent',
        cycleState: CycleState.failed,
        torrentId: torrentId,
        totalFiles: initSummary.total > 0 ? initSummary.total : null,
        completedFiles: initSummary.total > 0 ? initSummary.done : null,
        totalFileBytes: initSummary.bytes > 0 ? initSummary.bytes : null,
        downloadedFileBytes:
            initSummary.bytes > 0 ? initSummary.downloaded : null,
      ));
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.unknown,
        error: 'Torrent engine rejected the torrent.',
      );
    }

    TorrentResumeStore.registerSource(id, url);
    _activeTorrentIds.add(id);
    bool torrentCompleted = false;

    if (id != torrentId) {
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
            ? CycleState.retrying
            : (initSummary.downloaded > 0
                ? CycleState.resuming
                : CycleState.starting),
        torrentId: id,
        totalFiles: initSummary.total > 0 ? initSummary.total : null,
        completedFiles: initSummary.total > 0 ? initSummary.done : null,
        totalFileBytes: initSummary.bytes > 0 ? initSummary.bytes : null,
        downloadedFileBytes:
            initSummary.bytes > 0 ? initSummary.downloaded : null,
      ));
    }

    cancelToken.whenCancel.then((_) async {
      if (torrentCompleted) return;
      try {
        TorrentService.pauseTorrent(id);
      } catch (e, st) {
        LoggingService.logger('TorrentDownloadHandler').warning('Operation failed', e, st);
      }
      await Future.delayed(const Duration(milliseconds: 50));
      List<Map<String, dynamic>>? pauseFiles = getTorrentFiles?.call();
      final previousSelectedMap = <String, bool>{
        if (pauseFiles != null)
          for (final f in pauseFiles)
            if (f['name'] != null) (f['name'] as String): (f['selected'] as bool?) ?? true
      };
      final previousPriorityMap = <String, int>{
        if (pauseFiles != null)
          for (final f in pauseFiles)
            if (f['name'] != null && f['priority'] is int)
              (f['name'] as String): f['priority'] as int
      };
      try {
        final accurateFiles =
            await _torrentService.getAccurateFileProgress(id, saveDir);
        if (accurateFiles.isNotEmpty) {
          pauseFiles = [
            for (var i = 0; i < accurateFiles.length; i++)
              {
                'name': accurateFiles[i].name,
                'length': accurateFiles[i].size,
                'downloadedBytes': accurateFiles[i].downloadedBytes,
                'selected': previousSelectedMap[accurateFiles[i].name] ?? true,
                'priority': previousPriorityMap[accurateFiles[i].name] ?? 4,
                'progress': accurateFiles[i].progress,
                'isComplete': accurateFiles[i].isComplete,
                'progressEstimated': false,
              }
          ];
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
        cycleState: CycleState.paused,
        pauseReason: _inferPauseReason(cancelToken.cancelError?.message),
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
      final sub = _activeSubs.remove(id);
      await sub?.cancel();
      _activeTorrentIds.remove(id);
      TorrentSubscriptionRegistry.instance.unregister(id, this);
      cachedAccurateFiles = null;
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

    // Cancel any existing subscription for this torrent ID before attaching a new one

    final existingSub = _activeSubs.remove(id) ??
        TorrentSubscriptionRegistry.instance.getSubscription(id);
    await existingSub?.cancel();
    TorrentSubscriptionRegistry.instance.unregister(id, this);

    lastProgressTick = DateTime.fromMillisecondsSinceEpoch(0);
    lastAccurateSync = DateTime.fromMillisecondsSinceEpoch(0);
    cachedAccurateFiles = null;
    lastStateLabel = '';
    DateTime lastTorrentProgressTime = DateTime.now();
    int lastTorrentDownloadedBytes = 0;
    int currentTotalSize = 0;
    Timer? stallWatchdog;

    try {
      stallWatchdog = Timer.periodic(const Duration(minutes: 5), (_) {
        final elapsed = DateTime.now().difference(lastTorrentProgressTime);
        final isTerminal = lastStateLabel == 'seeding' ||
            lastStateLabel == 'paused' ||
            lastStateLabel == 'stopped' ||
            lastStateLabel == 'error';
        if (elapsed >= const Duration(minutes: 5) && !isTerminal) {
          onProgress(DownloadProgress(
            downloadedBytes: lastTorrentDownloadedBytes,
            fileSize: currentTotalSize,
            speed: 0,
            eta: null,
            torrentFiles: cachedAccurateFiles,
            cycleState: CycleState.stalled,
            statusMessage: 'Stalled (no peers)',
            torrentId: id,
          ));
        }

        // Force re-announce after 10 minutes of stall
        if (elapsed >= const Duration(minutes: 10) && !isTerminal) {
          _log.warning('Torrent $id stalled for 10min — forcing reannounce');
          try {
            TorrentService.announceNow(id);
          } catch (e, st) {
            _log.warning('Force reannounce failed for $id', e, st);
          }
        }
      });

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
            now.difference(lastProgressTick) < const Duration(milliseconds: 500)) {
          return;
        }
        final previousState = lastStateLabel;
        lastProgressTick = now;
        lastStateLabel = stateLabel;

        List<Map<String, dynamic>>? resolvedFiles = getTorrentFiles?.call();
        if ((resolvedFiles == null || resolvedFiles.isEmpty) && torrent.hasMetadata) {
          try {
            final nativeFiles = _torrentService.getFiles(id);
            if (nativeFiles.isNotEmpty) {
              resolvedFiles = nativeFiles
                  .map((f) => {
                        'name': f.name,
                        'length': f.size,
                        'downloadedBytes': f.safeDownloadedBytes,
                        'selected': f.selected,
                        'priority': f.priority,
                        'progress': f.size > 0
                            ? (f.safeDownloadedBytes / f.size).clamp(0.0, 1.0)
                            : 1.0,
                        'isComplete': f.size == 0 || f.safeDownloadedBytes >= f.size,
                        'progressEstimated': false,
                      })
                  .toList();
              cachedAccurateFiles = resolvedFiles;
            }
          } catch (e, st) {
            LoggingService.logger('TorrentDownloadHandler')
                .fine('Failed to fetch native file list: $e', e, st);
          }
        }

        final selectedFiles = resolvedFiles?.where((f) => (f['selected'] as bool?) ?? true).toList();
        final int selectedFilesSum = selectedFiles != null && selectedFiles.isNotEmpty
            ? selectedFiles.fold<int>(0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0))
            : 0;

        final totalSize = selectedFilesSum > 0
            ? selectedFilesSum
            : (torrent.totalWanted > 0
                ? torrent.totalWanted
                : (resolvedFiles?.fold<int>(
                        0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0)) ??
                    0));
        currentTotalSize = totalSize;

        final torrentAggregate = torrent.totalWantedDone > 0
            ? torrent.totalWantedDone
            : (torrent.totalDone > 0 ? torrent.totalDone : 0);

        final rawDownloaded = torrentAggregate > 0 ? torrentAggregate : 0;
        final safeProgress = torrent.progress.isFinite ? torrent.progress.clamp(0.0, 1.0) : 0.0;

        if (resolvedFiles != null && resolvedFiles.isNotEmpty) {
          updateFilesWithNativeProgress(resolvedFiles, safeProgress, rawDownloaded);
        }

        final downloadedBytes = rawDownloaded;
        final speed = torrent.downloadPayloadRate.toDouble();

        var resolvedCycleState = CycleState.fromLibtorrent(torrent.stateLabel);
        var resolvedStatusMessage = torrent.stateLabel;

        if (speed > 0 || downloadedBytes != lastTorrentDownloadedBytes) {
          lastTorrentDownloadedBytes = downloadedBytes;
          lastTorrentProgressTime = DateTime.now();
        } else if (speed == 0) {
          final elapsed = DateTime.now().difference(lastTorrentProgressTime);
          if (elapsed >= const Duration(minutes: 5) &&
              stateLabel != 'seeding' &&
              stateLabel != 'paused' &&
              stateLabel != 'stopped' &&
              stateLabel != 'error') {
            resolvedStatusMessage = 'Stalled (no peers)';
            resolvedCycleState = CycleState.stalled;
          }
        }

        // Fix 4: Emit retrying cycle when transitioning from stalled/error back to active
        final isRecovering = (previousState == 'stalled' || previousState == 'error') &&
            (stateLabel == 'downloading' ||
                stateLabel == 'downloading_metadata' ||
                stateLabel == 'checking_files' ||
                stateLabel == 'checking_resume_data');
        if (isRecovering) {
          onProgress(DownloadProgress(
            downloadedBytes: downloadedBytes,
            fileSize: totalSize,
            speed: speed,
            eta: null,
            torrentFiles: resolvedFiles ?? cachedAccurateFiles,
            cycleState: CycleState.retrying,
            totalPieces: torrent.piecesTotal,
            completedPieces: torrent.piecesHave,
            statusMessage: 'Retrying torrent…',
            torrentId: id,
          ));
        }

        onProgress(DownloadProgress(
          downloadedBytes: downloadedBytes,
          fileSize: totalSize,
          speed: speed,
          eta: null,
          torrentFiles: resolvedFiles ?? cachedAccurateFiles,
          cycleState: resolvedCycleState,
          totalPieces: torrent.piecesTotal,
          completedPieces: torrent.piecesHave,
          statusMessage: resolvedStatusMessage,
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
      stallWatchdog?.cancel();
      await sub?.cancel();
      _activeSubs.remove(id);
      TorrentSubscriptionRegistry.instance.unregister(id, this);
    }
  }
}
