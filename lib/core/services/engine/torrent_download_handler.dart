import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../../features/downloads/provider/network_monitor.dart';
import '../../di/injection.dart';
import '../../interfaces/i_torrent_service.dart';
import '../download_engine.dart';
import '../logging_service.dart';
import '../power_monitor.dart';
import '../torrent_resume_store.dart';
import '../torrent_service.dart';
import 'torrent_file_normalizer.dart';

// FIX: P0-01 — TorrentDownloadHandler manages BitTorrent lifecycle & progress

final _log = LoggingService.logger('TorrentDownloadHandler');

class _TorrentSubEntry {
  final WeakReference<TorrentDownloadHandler> handlerRef;
  final StreamSubscription subscription;

  _TorrentSubEntry({required this.handlerRef, required this.subscription});
}

/// Registry holding weak references to active TorrentDownloadHandlers
/// allowing retries/lookups to find active subscriptions without leaking dead handlers.
class TorrentSubscriptionRegistry {
  TorrentSubscriptionRegistry._();
  static final TorrentSubscriptionRegistry instance =
      TorrentSubscriptionRegistry._();

  final Map<int, _TorrentSubEntry> _registry = {};

  void _cleanupDeadEntries() {
    final deadKeys = <int>[];
    for (final entry in _registry.entries) {
      if (entry.value.handlerRef.target == null) {
        deadKeys.add(entry.key);
        try {
          entry.value.subscription.cancel();
        } catch (e, st) {
          _log.fine('Failed to cancel dead entry sub: $e', e, st);
        }
      }
    }
    for (final k in deadKeys) {
      _registry.remove(k);
    }
  }

  void register(
      int torrentId, TorrentDownloadHandler handler, StreamSubscription sub) {
    _cleanupDeadEntries();
    _registry[torrentId] = _TorrentSubEntry(
      handlerRef: WeakReference(handler),
      subscription: sub,
    );
  }

  StreamSubscription? getSubscription(int torrentId) {
    _cleanupDeadEntries();
    final entry = _registry[torrentId];
    if (entry == null) return null;
    final handler = entry.handlerRef.target;
    if (handler == null) {
      try {
        entry.subscription.cancel();
      } catch (e, st) {
        _log.fine('Failed to cancel subscription: $e', e, st);
      }
      _registry.remove(torrentId);
      return null;
    }
    return entry.subscription;
  }

  void unregister(int torrentId, TorrentDownloadHandler handler) {
    _cleanupDeadEntries();
    final entry = _registry[torrentId];
    if (entry != null) {
      final target = entry.handlerRef.target;
      if (target == null || identical(target, handler)) {
        _registry.remove(torrentId);
      }
    }
  }

  /// FIX-P2-02: Explicit disposal — cancels the subscription and removes the
  /// entry immediately instead of waiting for WeakReference GC to trigger a
  /// later cleanup. Called from the task-delete path so deleted torrents
  /// release their stream subscriptions deterministically.
  void dispose(int torrentId) {
    final entry = _registry.remove(torrentId);
    if (entry == null) return;
    try {
      entry.subscription.cancel();
    } catch (e, st) {
      _log.fine('Failed to cancel disposed subscription: $e', e, st);
    }
  }

  @visibleForTesting
  void clear() {
    for (final entry in _registry.values) {
      try {
        entry.subscription.cancel();
      } catch (e, st) {
        _log.fine('Failed to cancel registry subscription: $e', e, st);
      }
    }
    _registry.clear();
  }

  @visibleForTesting
  int get activeCountForTesting {
    _cleanupDeadEntries();
    return _registry.length;
  }

  @visibleForTesting
  Map<int, StreamSubscription> get subsMapForTesting {
    _cleanupDeadEntries();
    return _registry.map((k, v) => MapEntry(k, v.subscription));
  }
}

class TorrentDownloadHandler {
  final ITorrentService _torrentService;
  final Set<int> _activeTorrentIds = {};
  final Map<int, StreamSubscription> _activeSubs = {};
  Timer? _stallWatchdog;
  Completer<void>? _completionGuard;

  @visibleForTesting
  Map<int, StreamSubscription> get activeSubsForTesting => _activeSubs;

  @visibleForTesting
  static Map<int, StreamSubscription> get globalActiveSubsForTesting =>
      TorrentSubscriptionRegistry.instance.subsMapForTesting;

  @visibleForTesting
  Timer? get stallWatchdogForTesting => _stallWatchdog;

  @visibleForTesting
  Completer<void>? get completionGuardForTesting => _completionGuard;

  DateTime lastProgressTick = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime lastAccurateSync = DateTime.fromMillisecondsSinceEpoch(0);
  List<Map<String, dynamic>>? cachedAccurateFiles;
  String lastStateLabel = '';

  TorrentDownloadHandler({ITorrentService? torrentService})
      : _torrentService = torrentService ??
            (getIt.isRegistered<ITorrentService>()
                ? getIt<ITorrentService>()
                : TorrentServiceImpl());

  @visibleForTesting
  static PauseReason inferPauseReasonForTesting([PauseReason? reason]) =>
      _inferPauseReason(reason);

  static PauseReason _inferPauseReason([PauseReason? reason]) {
    if (reason != null) return reason;
    try {
      if (getIt.isRegistered<NetworkMonitor>()) {
        final networkMonitor = getIt<NetworkMonitor>();
        if (!networkMonitor.hasConnection) {
          return PauseReason.networkLost;
        }
      }
    } catch (e, st) {
      _log.fine('NetworkMonitor check in pause inference failed: $e', e, st);
    }
    try {
      if (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive) {
        return PauseReason.batterySaver;
      }
      if (PowerMonitor.screenOff) {
        return PauseReason.background;
      }
    } catch (e, st) {
      _log.fine('PowerMonitor check in pause inference failed: $e', e, st);
    }
    return PauseReason.userRequested;
  }

  Set<int> get activeTorrentIds => Set.unmodifiable(_activeTorrentIds);

  void removeActiveTorrent(int id) {
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    _activeTorrentIds.remove(id);
    final sub = _activeSubs.remove(id);
    sub?.cancel();
    TorrentSubscriptionRegistry.instance.unregister(id, this);
    cachedAccurateFiles = null;
    lastStateLabel = '';
  }

  // Fix 2: Adaptive sync intervals for all file counts including >10,000 files
  @visibleForTesting
  static Duration computeAdaptiveSyncInterval(int fileCount,
      {bool inBackground = false}) {
    if (inBackground) {
      if (fileCount > 5000) return const Duration(minutes: 5);
      if (fileCount > 1000) return const Duration(minutes: 3);
      return const Duration(seconds: 90);
    }
    if (fileCount > 10000) return const Duration(seconds: 120);
    if (fileCount > 5000) return const Duration(seconds: 45);
    if (fileCount > 1000) return const Duration(seconds: 30);
    if (fileCount > 100) return const Duration(seconds: 15);
    return const Duration(seconds: 5);
  }

  @visibleForTesting
  static bool shouldSkipPerFileSync(int fileCount,
      {bool inBackground = false}) {
    if (inBackground && fileCount > 5000) return true;
    return false;
  }

  static Map<String, dynamic> normalizeTorrentFile(Map<String, dynamic> f) =>
      TorrentFileNormalizer.normalizeTorrentFile(f);

  static bool isTorrentFileSelected(Map<String, dynamic> f) =>
      TorrentFileNormalizer.isTorrentFileSelected(f);

  static ({int total, int done, int bytes, int downloaded})
      normalizeTorrentFiles(List<Map<String, dynamic>>? files) {
    final result = TorrentFileNormalizer.normalizeTorrentFileList(files);
    return (
      total: result.total,
      done: result.done,
      bytes: result.bytes,
      downloaded: result.downloaded,
    );
  }

  static void _reconcileEstimatedFiles(
    List<Map<String, dynamic>> files,
    int totalDownloadedBytes,
  ) {
    if (totalDownloadedBytes <= 0 || files.isEmpty) return;
    int currentSum = 0;
    final estimatedFiles = <Map<String, dynamic>>[];
    int totalRemainingNeeded = 0;

    for (final f in files) {
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final len = (f['length'] as num?)?.toInt() ?? 0;
      currentSum += dl;
      final estimated = (f['progressEstimated'] as bool?) ?? false;
      if (estimated && dl < len) {
        estimatedFiles.add(f);
        totalRemainingNeeded += (len - dl);
      }
    }

    final diff = totalDownloadedBytes - currentSum;
    if (diff == 0 || estimatedFiles.isEmpty) return;

    if (diff > 0 && totalRemainingNeeded > 0) {
      int applied = 0;
      for (int i = 0; i < estimatedFiles.length; i++) {
        final f = estimatedFiles[i];
        final len = (f['length'] as num?)?.toInt() ?? 0;
        final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        final remainingNeeded = len - dl;
        final share = (i == estimatedFiles.length - 1)
            ? (diff - applied)
            : ((remainingNeeded / totalRemainingNeeded) * diff).round();
        applied += share;
        final newDl = (dl + share).clamp(0, len);
        f['downloadedBytes'] = newDl;
        f['progress'] = len > 0 ? (newDl / len).clamp(0.0, 1.0) : 1.0;
        f['isComplete'] = len == 0 || newDl >= len;
      }
    } else {
      int unallocated = diff;
      for (final f in estimatedFiles) {
        final len = (f['length'] as num?)?.toInt() ?? 0;
        final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        final newDl = (dl + unallocated).clamp(0, len);
        final delta = newDl - dl;
        unallocated -= delta;
        f['downloadedBytes'] = newDl;
        f['progress'] = len > 0 ? (newDl / len).clamp(0.0, 1.0) : 1.0;
        f['isComplete'] = len == 0 || newDl >= len;
        if (unallocated == 0) break;
      }
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
      final priorDl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final calculatedDl = remaining >= len ? len : remaining;
      final dl = math.max(priorDl, calculatedDl).clamp(0, len);
      f['downloadedBytes'] = dl;
      f['progress'] = len > 0 ? (dl / len).clamp(0.0, 1.0) : 1.0;
      f['isComplete'] = dl >= len;
      f['progressEstimated'] = true;
      remaining -= calculatedDl;
      if (remaining <= 0) remaining = 0;
    }
  }

  static double _priorityWeight(int priority) {
    if (priority <= 0) return 0.0;
    if (priority == 4) return 1.0;
    if (priority >= 7) return 1.5;
    return 1.0 + ((priority - 4) / 6.0);
  }

  static void distributeEstimatedBytes(
      List<Map<String, dynamic>> files, int totalDownloadedBytes) {
    int confirmedBytes = 0;
    double totalWeightedNeedingSize = 0;
    final needing = <Map<String, dynamic>>[];

    for (final f in files) {
      final estimated = (f['progressEstimated'] as bool?) ?? true;
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final len = (f['length'] as num?)?.toInt() ?? 0;
      final priority = (f['priority'] as num?)?.toInt() ?? 4;
      if (!estimated) {
        confirmedBytes += dl;
      } else if (dl < len && len > 0) {
        needing.add(f);
        totalWeightedNeedingSize += len * _priorityWeight(priority);
      }
    }
    if (needing.isEmpty) return;

    final remaining = math.max(0, totalDownloadedBytes - confirmedBytes);

    for (final f in needing) {
      final length = (f['length'] as num?)?.toInt() ?? 0;
      final priority = (f['priority'] as num?)?.toInt() ?? 4;
      if (length <= 0) {
        f['downloadedBytes'] = 0;
        continue;
      }

      final weight = totalWeightedNeedingSize > 0 && remaining > 0
          ? (length * _priorityWeight(priority)) / totalWeightedNeedingSize
          : 0.0;
      final est = (weight * remaining).round().clamp(0, length);
      f['downloadedBytes'] = est;
      f['progressEstimated'] = true;
      f['progress'] = length > 0 ? (est / length).clamp(0.0, 1.0) : 1.0;
      f['isComplete'] = est >= length;
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
    PauseReason? pauseReason,
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
    bool hasLoadedResume = false;
    if (id >= 0 && !_torrentService.isTorrentAlive(id)) {
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
        } catch (e, st) {
          _log.fine('Metadata fetch probe failed', e, st);
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
            id = TorrentService.addTorrentFile(filePath, saveDir,
                sourceKey: url);
          } finally {
            clientReleaser(torrentDio);
            try {
              if (await tempTorrentFile.exists()) {
                await tempTorrentFile.delete();
              }
            } catch (e, st) {
              LoggingService.logger('TorrentDownloadHandler')
                  .warning('Operation failed', e, st);
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
          hasLoadedResume = true;
          onProgress(DownloadProgress(
            downloadedBytes: initSummary.downloaded,
            fileSize: initSummary.bytes > 0 ? initSummary.bytes : knownFileSize,
            speed: 0,
            eta: null,
            supportsResume: true,
            torrentFiles: initFiles,
            statusMessage: 'Verifying resume data…',
            cycleState: CycleState.verifying,
            torrentId: id,
            totalFiles: initSummary.total > 0 ? initSummary.total : null,
            completedFiles: initSummary.total > 0 ? initSummary.done : null,
            totalFileBytes: initSummary.bytes > 0 ? initSummary.bytes : null,
            downloadedFileBytes:
                initSummary.bytes > 0 ? initSummary.downloaded : null,
          ));
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

    if (id != torrentId || hasLoadedResume) {
      onProgress(DownloadProgress(
        downloadedBytes: initSummary.downloaded,
        fileSize: initSummary.bytes > 0 ? initSummary.bytes : knownFileSize,
        speed: 0,
        eta: null,
        supportsResume: true,
        torrentFiles: initFiles,
        statusMessage: isRetry
            ? 'Retrying torrent…'
            : ((initSummary.downloaded > 0 || hasLoadedResume)
                ? 'Resuming torrent…'
                : 'Starting torrent…'),
        cycleState: isRetry
            ? CycleState.retrying
            : ((initSummary.downloaded > 0 || hasLoadedResume)
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

    final cancelCompleter = Completer<void>();
    cancelToken.whenCancel.then((cancelReason) async {
      if (torrentCompleted || cancelCompleter.isCompleted) return;
      cancelCompleter.complete();
      try {
        TorrentService.pauseTorrent(id);
      } catch (e, st) {
        LoggingService.logger('TorrentDownloadHandler')
            .warning('Operation failed', e, st);
      }
      await Future.delayed(const Duration(milliseconds: 50));
      List<Map<String, dynamic>>? pauseFiles = getTorrentFiles?.call();
      String normKey(String name) => name.toLowerCase().replaceAll('\\', '/');
      final previousSelectedMap = <String, bool>{
        if (pauseFiles != null)
          for (final f in pauseFiles)
            if (f['name'] != null)
              normKey(f['name'] as String): (f['selected'] as bool?) ?? true
      };
      final previousPriorityMap = <String, int>{
        if (pauseFiles != null)
          for (final f in pauseFiles)
            if (f['name'] != null && f['priority'] is int)
              normKey(f['name'] as String): f['priority'] as int
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
                'selected':
                    previousSelectedMap[normKey(accurateFiles[i].name)] ?? true,
                'priority':
                    previousPriorityMap[normKey(accurateFiles[i].name)] ?? 4,
                'progress': accurateFiles[i].progress,
                'isComplete': accurateFiles[i].isComplete,
                'progressEstimated': false,
              }
          ];
        }
      } catch (e, st) {
        LoggingService.logger('TorrentDownloadHandler')
            .warning('Operation failed', e, st);
      }
      final pauseSummary = normalizeTorrentFiles(pauseFiles);

      // Fix 5: Check disk space on saveDir before inferring pause reason
      PauseReason? effectivePauseReason = pauseReason;
      if (effectivePauseReason == null) {
        try {
          final engine = getIt.isRegistered<DownloadEngine>()
              ? getIt<DownloadEngine>()
              : DownloadEngine();
          final hasSpace =
              await engine.hasEnoughDiskSpace(saveDir, 100 * 1024 * 1024);
          if (!hasSpace) {
            effectivePauseReason = PauseReason.diskFull;
          }
        } catch (e, st) {
          _log.fine('Disk space check before pause failed: $e', e, st);
        }
      }

      final String? cancelReasonStr = cancelReason.error?.toString() ??
          cancelReason.message ??
          cancelToken.cancelError?.error?.toString() ??
          cancelToken.cancelError?.message;
      final parsedPauseReason = cancelReasonStr?.contains(':') == true
          ? (PauseReason.fromName(cancelReasonStr!.split(':')[1]) ??
              PauseReason.userRequested)
          : (cancelReasonStr != null && cancelReasonStr.isNotEmpty
              ? (PauseReason.fromName(cancelReasonStr) ??
                  _inferPauseReason(effectivePauseReason))
              : _inferPauseReason(effectivePauseReason));
      onProgress(DownloadProgress(
        downloadedBytes: pauseSummary.downloaded,
        fileSize: pauseSummary.bytes > 0 ? pauseSummary.bytes : knownFileSize,
        speed: 0,
        eta: null,
        supportsResume: true,
        torrentFiles: pauseFiles,
        statusMessage: 'Paused',
        cycleState: CycleState.paused,
        pauseReason: parsedPauseReason,
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
          LoggingService.logger('TorrentDownloadHandler')
              .warning('Operation failed', e, st);
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
        LoggingService.logger('TorrentDownloadHandler')
            .warning('Operation failed', e, st);
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
      // Cancel the whenCancel listener if torrent completed naturally
      if (torrentCompleted && !cancelCompleter.isCompleted) {
        cancelCompleter.complete();
      }
      final sub = _activeSubs.remove(id);
      await sub?.cancel();
      _activeTorrentIds.remove(id);
      TorrentSubscriptionRegistry.instance.unregister(id, this);
      cachedAccurateFiles = null;
    }
  }

  @visibleForTesting
  Future<void> listenForCompletionForTesting(
    int id,
    String url,
    String localFilePath,
    CancelToken cancelToken,
    ValueChangedProgress onProgress, {
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
  }) {
    return _listenForCompletion(
      id,
      url,
      localFilePath,
      cancelToken,
      onProgress,
      getTorrentFiles: getTorrentFiles,
    );
  }

  Future<void> _listenForCompletion(
    int id,
    String url,
    String localFilePath,
    CancelToken cancelToken,
    ValueChangedProgress onProgress, {
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
  }) async {
    // Cancel any stale stall watchdog from a previous cycle before creating a
    // new one. Otherwise the old Timer leaks and can double-complete the guard.
    _stallWatchdog?.cancel();
    _stallWatchdog = null;

    // Guard against overlapping completion handlers: if a previous
    // _listenForCompletion for this torrent is still running, wait on its
    // completion future rather than starting a second subscription loop.
    if (_completionGuard != null && !_completionGuard!.isCompleted) {
      await _completionGuard!.future;
      return;
    }

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
    double lastTorrentSpeed = 0.0;
    int lastTorrentPeerCount = 0;
    int currentTotalSize = 0;
    DateTime? lastRecoveryEmit;

    final initialFiles = getTorrentFiles?.call();
    final initialFileCount = initialFiles?.length ?? 0;
    final watchdogInterval = initialFileCount < 1000
        ? const Duration(seconds: 30)
        : const Duration(seconds: 120);

    _completionGuard = completer;

    try {
      _stallWatchdog?.cancel();
      _stallWatchdog = Timer.periodic(watchdogInterval, (_) {
        if (getIt.isRegistered<NetworkMonitor>()) {
          final networkMonitor = getIt<NetworkMonitor>();
          if (!networkMonitor.hasConnection) {
            onProgress(DownloadProgress(
              downloadedBytes: lastTorrentDownloadedBytes,
              fileSize: currentTotalSize,
              speed: 0,
              eta: null,
              torrentFiles: cachedAccurateFiles,
              cycleState: CycleState.paused,
              pauseReason: PauseReason.networkLost,
              statusMessage: 'Waiting for network…',
              torrentId: id,
            ));
            return;
          }
        }

        final elapsed = DateTime.now().difference(lastTorrentProgressTime);
        final isTerminal = lastStateLabel == 'seeding' ||
            lastStateLabel == 'paused' ||
            lastStateLabel == 'stopped' ||
            lastStateLabel == 'error';
        if (isTerminal) return;

        final isNonDownloadPhase = lastStateLabel.contains('checking') ||
            lastStateLabel.contains('downloading_metadata') ||
            lastStateLabel.contains('allocating');
        if (isNonDownloadPhase) return;

        if (elapsed >= const Duration(minutes: 5)) {
          if (lastStateLabel == 'downloading' && lastTorrentPeerCount == 0) {
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
          if (_completionGuard != null && !_completionGuard!.isCompleted) {
            _completionGuard!.completeError(const TorrentStallException(
              'Torrent download stalled for > 5 minutes with no updates',
            ));
            return;
          }
        } else if (elapsed >= const Duration(seconds: 60) &&
            lastTorrentSpeed == 0) {
          onProgress(DownloadProgress(
            downloadedBytes: lastTorrentDownloadedBytes,
            fileSize: currentTotalSize,
            speed: 0,
            eta: null,
            torrentFiles: cachedAccurateFiles,
            cycleState: CycleState.stalled,
            statusMessage: 'Looking for peers…',
            torrentId: id,
          ));
        }

        // Force re-announce after 10 minutes of stall
        if (elapsed >= const Duration(minutes: 10)) {
          _log.warning('Torrent $id stalled for 10min — forcing reannounce');
          try {
            TorrentService.announceNow(id);
            onProgress(DownloadProgress(
              downloadedBytes: lastTorrentDownloadedBytes,
              fileSize: currentTotalSize,
              speed: 0,
              eta: null,
              torrentFiles: cachedAccurateFiles,
              cycleState: CycleState.retrying,
              statusMessage: 'Retrying connection…',
              torrentId: id,
            ));
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
            now.difference(lastProgressTick) <
                const Duration(milliseconds: 500)) {
          return;
        }
        final previousState = lastStateLabel;
        lastProgressTick = now;
        lastStateLabel = stateLabel;
        if (isStateChange) {
          lastTorrentProgressTime = now;
        }

        List<Map<String, dynamic>>? resolvedFiles = getTorrentFiles?.call();
        if ((resolvedFiles == null || resolvedFiles.isEmpty) &&
            torrent.hasMetadata) {
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
                        'isComplete':
                            f.size == 0 || f.safeDownloadedBytes >= f.size,
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

        final selectedFiles = resolvedFiles
            ?.where((f) => (f['selected'] as bool?) ?? true)
            .toList();
        final int selectedFilesSum =
            selectedFiles != null && selectedFiles.isNotEmpty
                ? selectedFiles.fold<int>(
                    0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0))
                : 0;

        final totalSize = selectedFilesSum > 0
            ? selectedFilesSum
            : (torrent.totalWanted > 0
                ? torrent.totalWanted
                : (resolvedFiles?.fold<int>(0,
                        (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0)) ??
                    0));
        currentTotalSize = totalSize;

        final fileCount =
            resolvedFiles?.length ?? (cachedAccurateFiles?.length ?? 0);
        final inBg = DownloadEngine.isInBackground;
        if (fileCount > 0 && !shouldSkipPerFileSync(fileCount, inBackground: inBg)) {
          final syncInterval = computeAdaptiveSyncInterval(fileCount,
              inBackground: inBg);
          if (now.difference(lastAccurateSync) >= syncInterval) {
            lastAccurateSync = now;
            try {
              final saveDir = File(localFilePath).parent.path;
              final accurate =
                  await _torrentService.getAccurateFileProgress(id, saveDir);
              if (accurate.isNotEmpty) {
                String normKey(String n) =>
                    n.toLowerCase().replaceAll('\\', '/');
                final previousSelectedMap = <String, bool>{
                  if (resolvedFiles != null)
                    for (final f in resolvedFiles)
                      if (f['name'] != null)
                        normKey(f['name'] as String):
                            (f['selected'] as bool?) ?? true
                };
                final previousPriorityMap = <String, int>{
                  if (resolvedFiles != null)
                    for (final f in resolvedFiles)
                      if (f['name'] != null && f['priority'] is int)
                        normKey(f['name'] as String): f['priority'] as int
                };
                resolvedFiles = [
                  for (final f in accurate)
                    {
                      'name': f.name,
                      'length': f.size,
                      'downloadedBytes': f.downloadedBytes,
                      'selected': previousSelectedMap[normKey(f.name)] ?? true,
                      'priority': previousPriorityMap[normKey(f.name)] ?? 4,
                      'progress': f.progress,
                      'isComplete': f.isComplete,
                      'progressEstimated': false,
                    }
                ];
                cachedAccurateFiles = resolvedFiles;
              }
            } catch (e, st) {
              LoggingService.logger('TorrentDownloadHandler')
                  .warning('Accurate file sync failed: $e', e, st);
            }
          }
        }

        final rawDownloaded =
            torrent.totalWantedDone > 0 ? torrent.totalWantedDone : 0;
        final safeProgress =
            torrent.progress.isFinite ? torrent.progress.clamp(0.0, 1.0) : 0.0;

        if (resolvedFiles != null && resolvedFiles.isNotEmpty) {
          bool pieceMapped = false;
          if (fileCount > 5000) {
            try {
              final pieceProgress = await _torrentService.getPieceProgress(id);
              if (pieceProgress != null) {
                final piecesHave =
                    (pieceProgress['piecesHave'] as num?)?.toInt() ?? 0;
                final piecesTotal =
                    (pieceProgress['piecesTotal'] as num?)?.toInt() ?? 0;
                if (piecesTotal > 0) {
                  final pieceRatio = (piecesHave / piecesTotal).clamp(0.0, 1.0);
                  updateFilesWithNativeProgress(
                      resolvedFiles, pieceRatio, rawDownloaded);
                  pieceMapped = true;
                }
              }
            } catch (e, st) {
              _log.fine('Piece progress query failed: $e', e, st);
            }
          }
          if (!pieceMapped) {
            updateFilesWithNativeProgress(
                resolvedFiles, safeProgress, rawDownloaded);
          }
        }

        final downloadedBytes = rawDownloaded;
        final speed = torrent.downloadPayloadRate.toDouble();
        lastTorrentSpeed = speed;
        lastTorrentPeerCount = torrent.numPeers;

        var resolvedCycleState = CycleState.fromLibtorrent(
          torrent.stateLabel,
          seedingEnabled: TorrentService.seedingEnabled,
        );
        var resolvedStatusMessage = torrent.stateLabel;

        if (speed > 0 || downloadedBytes != lastTorrentDownloadedBytes) {
          lastTorrentDownloadedBytes = downloadedBytes;
          lastTorrentProgressTime = DateTime.now();
        } else if (speed == 0) {
          final elapsed = DateTime.now().difference(lastTorrentProgressTime);
          final isNonDownloadPhase = stateLabel.contains('checking') ||
              stateLabel.contains('downloading_metadata') ||
              stateLabel.contains('allocating');
          if (stateLabel != 'seeding' &&
              stateLabel != 'paused' &&
              stateLabel != 'stopped' &&
              stateLabel != 'error' &&
              !isNonDownloadPhase) {
            if (elapsed >= const Duration(minutes: 5)) {
              if (stateLabel == 'downloading' && torrent.peerCount == 0) {
                resolvedStatusMessage = 'Stalled (no peers)';
                resolvedCycleState = CycleState.stalled;
              }
            } else if (elapsed >= const Duration(seconds: 60)) {
              resolvedStatusMessage = 'Looking for peers…';
              resolvedCycleState = CycleState.stalled;
            }
          }
        }

        // Fix 4: Emit retrying cycle when transitioning from stalled/error back to active
        final isRecovering =
            (previousState == 'stalled' || previousState == 'error') &&
                (stateLabel == 'downloading' ||
                    stateLabel == 'downloading_metadata' ||
                    stateLabel == 'checking_files' ||
                    stateLabel == 'checking_resume_data');
        if (isRecovering) {
          lastRecoveryEmit = DateTime.now();
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

        if (lastRecoveryEmit == null ||
            DateTime.now().difference(lastRecoveryEmit!).inMilliseconds >=
                2000) {
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
        }

        if (stateLabel == 'seeding' ||
            (totalSize > 0 && downloadedBytes >= totalSize)) {
          final isSeedingEnabled = TorrentService.seedingEnabled;
          final finalCycleState = (stateLabel == 'seeding' && isSeedingEnabled)
              ? CycleState.seeding
              : CycleState.completed;
          final finalStatusMessage =
              (stateLabel == 'seeding' && isSeedingEnabled)
                  ? 'Seeding…'
                  : 'Completed';

          onProgress(DownloadProgress(
            downloadedBytes: totalSize > 0 ? totalSize : downloadedBytes,
            fileSize: totalSize,
            speed: isSeedingEnabled ? speed : 0,
            eta: 0,
            torrentFiles: resolvedFiles ?? cachedAccurateFiles,
            cycleState: finalCycleState,
            totalPieces: torrent.piecesTotal,
            completedPieces: torrent.piecesTotal,
            statusMessage: finalStatusMessage,
            torrentId: id,
          ));

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
      _stallWatchdog?.cancel();
      _stallWatchdog = null;
      _completionGuard = null;
      await sub?.cancel();
      _activeSubs.remove(id);
      TorrentSubscriptionRegistry.instance.unregister(id, this);
    }
  }
}
