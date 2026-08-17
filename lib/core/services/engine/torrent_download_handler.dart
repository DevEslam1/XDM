import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
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

final _log = LoggingService.logger('TorrentDownloadHandler');

class TorrentSubscriptionRegistry {
  TorrentSubscriptionRegistry._();
  static final TorrentSubscriptionRegistry instance =
      TorrentSubscriptionRegistry._();
  final Map<int, _TorrentSubEntry> _registry = {};

  void register(
      int torrentId, TorrentDownloadHandler handler, StreamSubscription sub) {
    final existing = _registry.remove(torrentId);
    if (existing != null) {
      try {
        existing.subscription.cancel();
      } catch (e, st) {
        _log.fine('Failed to cancel existing subscription: $e', e, st);
      }
    }
    _registry[torrentId] = _TorrentSubEntry(
      handler: handler,
      subscription: sub,
    );
  }

  StreamSubscription? getSubscription(int torrentId) {
    final entry = _registry[torrentId];
    return entry?.subscription;
  }

  void unregister(int torrentId, TorrentDownloadHandler handler) {
    final entry = _registry[torrentId];
    if (entry != null && identical(entry.handler, handler)) {
      _registry.remove(torrentId);
    }
  }

  void dispose(int torrentId) {
    final entry = _registry.remove(torrentId);
    if (entry == null) return;
    try {
      entry.subscription.cancel();
    } catch (e, st) {
      _log.fine('Failed to cancel disposed subscription: $e', e, st);
    }
    entry.handler.haltTorrent(torrentId).catchError((Object e, StackTrace st) {
      _log.warning('Failed to halt torrent $torrentId on dispose', e, st);
    });
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
  int get activeCountForTesting => _registry.length;

  @visibleForTesting
  Map<int, StreamSubscription> get subsMapForTesting {
    return _registry.map((k, v) => MapEntry(k, v.subscription));
  }
}

class _TorrentSubEntry {
  final TorrentDownloadHandler handler;
  final StreamSubscription subscription;
  _TorrentSubEntry({required this.handler, required this.subscription});
}

class TorrentDownloadHandler {
  final ITorrentService _torrentService;
  final Set<int> _activeTorrentIds = {};
  final Map<int, StreamSubscription> _activeSubs = {};
  Timer? _stallWatchdog;
  Timer? _alivenessWatchdog;
  Completer<void>? _completionGuard;
  Completer<void>? _pauseCompleter;

  @visibleForTesting
  Map<int, StreamSubscription> get activeSubsForTesting => _activeSubs;
  @visibleForTesting
  static Map<int, StreamSubscription> get globalActiveSubsForTesting =>
      TorrentSubscriptionRegistry.instance.subsMapForTesting;
  @visibleForTesting
  Timer? get stallWatchdogForTesting => _stallWatchdog;
  @visibleForTesting
  Completer<void>? get completionGuardForTesting => _completionGuard;
  @visibleForTesting
  Completer<void>? get pauseCompleterForTesting => _pauseCompleter;

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
    _alivenessWatchdog?.cancel();
    _alivenessWatchdog = null;
    _activeTorrentIds.remove(id);
    final sub = _activeSubs.remove(id);
    sub?.cancel();
    TorrentSubscriptionRegistry.instance.unregister(id, this);
    cachedAccurateFiles = null;
    lastStateLabel = '';
  }

  Future<void> haltTorrent(int id) async {
    TorrentSubscriptionRegistry.instance.unregister(id, this);
    final sub = _activeSubs.remove(id);
    await sub?.cancel();
    if (!_torrentService.isTorrentAlive(id)) {
      _activeTorrentIds.remove(id);
      return;
    }
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await _torrentService.pauseTorrent(id);
      } catch (e, st) {
        _log.warning(
            'haltTorrent pause attempt $attempt failed for $id', e, st);
      }
      final verified = await _isTransmissionStopped(id);
      if (verified) {
        _activeTorrentIds.remove(id);
        return;
      }
      if (attempt < maxAttempts) {
        await Future.delayed(Duration(milliseconds: 150 * attempt));
      }
    }
    _log.warning(
        'haltTorrent: torrent $id still alive after $maxAttempts pause attempts; removing handle.');
    _activeTorrentIds.remove(id);
  }

  /// FIX v2.0.0: Save resume data with longer timeout and fallback.
  /// v2.0.0's async save can take longer during heavy I/O.
  Future<void> _saveResumeDataBeforePause(int id, String sourceUrl) async {
    try {
      await _torrentService.saveResumeData(id).timeout(
        const Duration(seconds: 20),
        onTimeout: () => _log.warning(
            'saveResumeData timed out for torrent $id — pause proceeding'),
      );
    } catch (e, st) {
      _log.warning('Failed to save resume data for torrent $id: $e', e, st);
      // FIX v2.0.0-Bug4: The previous fallback used TorrentService.resumeBlobFor(id)
      // which is SYNCHRONOUS and always returns null in v2.0.0 (the sync
      // saveResumeData returns null because the native call returns a Future).
      // Use the async path directly via saveAndWait with the async fetcher.
      try {
        final files = _torrentService.getFiles(id);
        final torrentFiles = files.isNotEmpty
            ? files
                .map((f) => {
                      'name': f.name,
                      'length': f.size,
                      'priority': f.priority,
                      'selected': f.selected,
                      'downloadedBytes': f.safeDownloadedBytes,
                    })
                .toList()
            : null;
        await TorrentResumeStore.saveAndWait(
          torrentId: id,
          sourceUrl: sourceUrl,
          fetchResumeData: () async {
            // Use a longer timeout for the fallback async save
            final blob = _torrentService.resumeBlobFor(id);
            if (blob != null && blob.isNotEmpty) return blob;
            // If sync cache is empty, wait briefly for async save to populate
            await Future.delayed(const Duration(milliseconds: 500));
            return _torrentService.resumeBlobFor(id);
          },
          files: torrentFiles,
        ).timeout(const Duration(seconds: 15));
      } catch (e2, st2) {
        _log.warning('Fallback resume save also failed for $id: $e2', e2, st2);
      }
    }
  }

  Future<bool> _isTransmissionStopped(int id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (!_torrentService.isTorrentAlive(id)) return true;
      final stats = _torrentService.latestStats[id];
      if (stats != null) {
        final label = stats.stateLabel.toLowerCase();
        if (label.contains('paused') || label.contains('stopped')) return true;
        // FIX v2.0.0: Recognize additional v2.0.0 state labels.
        if ((stats.downloadRate <= 0 && stats.uploadRate <= 0) &&
            (label.contains('checking') ||
                label.contains('checking_files') ||
                label.contains('checking_resume_data') ||
                label.contains('queued_for_checking') ||
                label.contains('allocating') ||
                label.contains('downloading_metadata') ||
                label.contains('fetching_metadata'))) {
          return true;
        }
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

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

  /// Compares two torrent file lists for structural equality.
  static bool _torrentFileListsDiffer(
    List<Map<String, dynamic>>? a,
    List<Map<String, dynamic>>? b,
  ) {
    if (a == null && b == null) return false;
    if (a == null || b == null) return true;
    if (a.length != b.length) return true;
    for (int i = 0; i < a.length; i++) {
      final am = a[i];
      final bm = b[i];
      if (am['name'] != bm['name'] ||
          am['length'] != bm['length'] ||
          am['downloadedBytes'] != bm['downloadedBytes'] ||
          am['selected'] != bm['selected'] ||
          am['priority'] != bm['priority']) {
        return true;
      }
    }
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
    }
  }

  /// FIX v2.0.0: Treat downloadedBytes == 0 as "no data yet" (estimated),
  /// not as "accurate zero". In v2.0.0 the engine reports 0 before the
  /// first piece arrives, and marking it as accurate blocks the estimation
  /// fallback, causing all files to show 0% forever.
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
          // FIX: If length is unknown (<= 0), progress should be 0.0, not 1.0 (100%)
          f['progress'] = 0.0;
          f['isComplete'] = false;
          f['progressEstimated'] = true; // Mark as estimated since size is unknown
          continue;
        }
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? -1;
      final wasEstimated = (f['progressEstimated'] as bool?) ?? false;
      // FIX v2.0.0: dl == 0 with wasEstimated means engine hasn't
      // provided real data yet — keep it as estimated so the
      // distribution logic can fill in from totalDownloadedBytes.
      if (dl > 0 && dl <= len) {
        f['progress'] = (dl / len).clamp(0.0, 1.0);
        f['isComplete'] = dl >= len;
        f['progressEstimated'] = false;
      } else if (dl == 0 && !wasEstimated && totalDownloadedBytes > 0) {
        // Engine explicitly reported 0 and we have aggregate bytes —
        // let estimation distribute them.
        final est = (len * progress).clamp(0.0, len.toDouble()).toInt();
        f['downloadedBytes'] = est;
        f['progress'] = len > 0 ? (est / len).clamp(0.0, 1.0) : 1.0;
        f['isComplete'] = est >= len;
        f['progressEstimated'] = true;
      } else if (dl >= 0 && dl <= len) {
        f['progress'] = (dl / len).clamp(0.0, 1.0);
        f['isComplete'] = dl >= len;
        f['progressEstimated'] = false;
      } else {
        final est = (len * progress).clamp(0.0, len.toDouble()).toInt();
        f['downloadedBytes'] = est;
        f['progress'] = len > 0 ? (est / len).clamp(0.0, 1.0) : 1.0;
        f['isComplete'] = est >= len;
        f['progressEstimated'] = true;
      }
    }
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

  /// Distributes estimated downloaded bytes across files that need progress
  /// estimation, weighted by file size and priority.
  ///
  /// FIX: When [totalWeightedNeedingSize] is zero (all needing files have
  /// priority 0, producing zero weight via [_priorityWeight]), the previous
  /// code would set every file's estimated bytes to 0, silently masking
  /// all progress. This rewrite adds a fallback to even distribution when
  /// weights sum to zero, ensuring progress is always visible.
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

    // FIX v2.0.0: Guard against division by zero when needing is empty
    // after filtering, and use safe even distribution.
    if (totalWeightedNeedingSize <= 0) {
      final evenShare = needing.isNotEmpty ? (remaining ~/ needing.length) : 0;
      var leftover = remaining - (evenShare * needing.length);
      for (var i = 0; i < needing.length; i++) {
        final f = needing[i];
        final length = (f['length'] as num?)?.toInt() ?? 0;
        if (length <= 0) {
          f['downloadedBytes'] = 0;
          continue;
        }
        final extra = leftover > 0 ? 1 : 0;
        if (leftover > 0) leftover--;
        final est = (evenShare + extra).clamp(0, length);
        f['downloadedBytes'] = est;
        f['progressEstimated'] = true;
        f['progress'] = length > 0 ? (est / length).clamp(0.0, 1.0) : 1.0;
        f['isComplete'] = est >= length;
      }
      _reconcileEstimatedFiles(files, totalDownloadedBytes);
      return;
    }

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
      _log.warning(
          'Stale torrent handle $id detected; re-adding. (FIX #2 Part A & Fix #5)');
      try {
        _torrentService.removeTorrent(id, deleteFiles: false);
      } catch (e) {
        _log.fine('Failed to remove stale torrent $id from service: $e');
      }
      try {
        TorrentSubscriptionRegistry.instance.dispose(id);
      } catch (e) {
        _log.fine('Failed to dispose subscription registry for stale $id: $e');
      }
      try {
        TorrentResumeStore.unregisterSource(id);
      } catch (e) {
        _log.fine('Failed to unregister source for stale $id: $e');
      }
      _activeTorrentIds.remove(id);
      final sub = _activeSubs.remove(id);
      sub?.cancel();
      id = -1;
    }

    if (id == -1) {
      final dir = Directory(saveDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      // FIX v2.0.0-Bug7: Preload resume data from disk BEFORE adding the
      // torrent so it can be applied immediately after addMagnet/addTorrentFile
      // returns. Previously the torrent started downloading for the duration
      // of the async loadResumeDataForSource call, re-downloading pieces that
      // were already on disk.
      Uint8List? preloadedResume;
      List<Map<String, dynamic>>? preloadedFiles;
      try {
        if (await TorrentService.hasResumeData(url)) {
          preloadedResume =
              await TorrentResumeStore.loadResumeDataForSource(url);
          if (preloadedResume != null) {
            preloadedFiles = await TorrentResumeStore.loadFilesForSource(url);
          }
        }
      } catch (e, st) {
        _log.fine('Preload resume data failed: $e', e, st);
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

      // FIX v2.0.0-Bug7: Use preloaded resume data (loaded before adding
      // the torrent) to eliminate the window where the torrent downloads
      // before fast-resume is applied.
      if (id >= 0 && preloadedResume != null) {
        final resumeBytes = preloadedResume;
        hasLoadedResume = true;
        if (preloadedFiles != null && preloadedFiles.isNotEmpty) {
          cachedAccurateFiles = preloadedFiles;
        }
        final activeFiles = preloadedFiles ?? initFiles;
        final activeSummary = normalizeTorrentFiles(activeFiles);
        onProgress(DownloadProgress(
          downloadedBytes: activeSummary.downloaded > 0 ? activeSummary.downloaded : initSummary.downloaded,
          fileSize: activeSummary.bytes > 0 ? activeSummary.bytes : (initSummary.bytes > 0 ? initSummary.bytes : knownFileSize),
          speed: 0,
          eta: null,
          supportsResume: true,
          torrentFiles: activeFiles,
          statusMessage: 'Verifying resume data…',
          cycleState: CycleState.verifying,
          torrentId: id,
          totalFiles: activeSummary.total > 0 ? activeSummary.total : (initSummary.total > 0 ? initSummary.total : null),
          completedFiles: activeSummary.total > 0 ? activeSummary.done : (initSummary.total > 0 ? initSummary.done : null),
          totalFileBytes: activeSummary.bytes > 0 ? activeSummary.bytes : (initSummary.bytes > 0 ? initSummary.bytes : null),
          downloadedFileBytes:
              activeSummary.bytes > 0 ? activeSummary.downloaded : (initSummary.bytes > 0 ? initSummary.downloaded : null),
        ));
        TorrentService.loadResumeData(id, resumeBytes.toList());
      } else if (id >= 0) {
        // Fallback: try the original path if preload didn't have data
        try {
          if (await TorrentService.hasResumeData(url)) {
            // FIX v2.0.0-BugFallback: fetchResumeBytes triggers an async
            // saveResumeData call which is wasteful and can't return a
            // result synchronously in v2.0.0 (it always returns null from
            // the sync path). Load directly from disk instead.
            final fallbackBytes =
                await TorrentResumeStore.loadResumeDataForSource(url);
            if (fallbackBytes != null) {
              hasLoadedResume = true;
              onProgress(DownloadProgress(
                downloadedBytes: initSummary.downloaded,
                fileSize:
                    initSummary.bytes > 0 ? initSummary.bytes : knownFileSize,
                speed: 0,
                eta: null,
                supportsResume: true,
                torrentFiles: initFiles,
                statusMessage: 'Verifying resume data…',
                cycleState: CycleState.verifying,
                torrentId: id,
                totalFiles:
                    initSummary.total > 0 ? initSummary.total : null,
                completedFiles:
                    initSummary.total > 0 ? initSummary.done : null,
                totalFileBytes:
                    initSummary.bytes > 0 ? initSummary.bytes : null,
                downloadedFileBytes:
                    initSummary.bytes > 0 ? initSummary.downloaded : null,
              ));
              TorrentService.loadResumeData(id, fallbackBytes.toList());
            }
          }
        } catch (e, st) {
          _log.fine('Fallback resume data load failed: $e', e, st);
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
    bool pauseInitiated = false;

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
    _pauseCompleter = cancelCompleter;
    final pauseHandled = <bool>[false];

    cancelToken.whenCancel.then((cancelReason) async {
      if (pauseHandled[0] || torrentCompleted || cancelCompleter.isCompleted) {
        return;
      }
      pauseHandled[0] = true;
      pauseInitiated = true;
      _log.info(
          'Pause/cancel requested for torrent $id — executing pause actions');
      await _saveResumeDataBeforePause(id, url);
      _stallWatchdog?.cancel();
      _stallWatchdog = null;
      _alivenessWatchdog?.cancel();
      _alivenessWatchdog = null;
      final sub = _activeSubs.remove(id);
      await sub?.cancel();
      await haltTorrent(id);
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
        // FIX: Improved warning message clarifying that the estimated
        // snapshot is being used as a fallback, so users and developers
        // can diagnose inaccurate pause-state progress more easily.
        _log.warning(
          'Accurate file progress fetch on pause failed for torrent $id; '
          'falling back to last known file snapshot (progress may be '
          'estimated): $e',
          e,
          st,
        );
      }
      final pauseSummary = normalizeTorrentFiles(pauseFiles);
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
      if (!cancelCompleter.isCompleted) {
        cancelCompleter.complete();
      }
    });

    try {
      if (cancelToken.isCancelled) {
        if (!pauseHandled[0]) {
          pauseHandled[0] = true;
          pauseInitiated = true;
          try {
            TorrentService.pauseTorrent(id);
          } catch (e, st) {
            _log.warning('Immediate pause failed: $e', e, st);
          }
        }
        throw DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel,
          message: 'Download paused',
        );
      }
      if (!cancelToken.isCancelled) {
        try {
          TorrentService.resumeTorrent(id);
        } catch (e, st) {
          _log.warning('resumeTorrent failed: $e', e, st);
        }
      }
      await _listenForCompletion(
        id,
        url,
        currentLocalFilePath,
        cancelToken,
        onProgress,
        getTorrentFiles: getTorrentFiles,
        knownFileSize: knownFileSize,
      );
      torrentCompleted = true;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        if (!cancelCompleter.isCompleted) {
          await cancelCompleter.future.timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              _log.warning('Pause handler timed out for torrent $id');
              return null;
            },
          );
        }
      }
      rethrow;
    } finally {
      if (torrentCompleted && !cancelCompleter.isCompleted) {
        cancelCompleter.complete();
      }
      if (pauseInitiated && !cancelCompleter.isCompleted) {
        await cancelCompleter.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () => null,
        );
      }
      final sub = _activeSubs.remove(id);
      await sub?.cancel();
      _stallWatchdog?.cancel();
      _stallWatchdog = null;
      _alivenessWatchdog?.cancel();
      _alivenessWatchdog = null;
      _activeTorrentIds.remove(id);
      TorrentSubscriptionRegistry.instance.unregister(id, this);
      _pauseCompleter = null;
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
    int knownFileSize = 0,
  }) {
    return _listenForCompletion(
      id,
      url,
      localFilePath,
      cancelToken,
      onProgress,
      getTorrentFiles: getTorrentFiles,
      knownFileSize: knownFileSize,
    );
  }

  Future<void> _listenForCompletion(
    int id,
    String url,
    String localFilePath,
    CancelToken cancelToken,
    ValueChangedProgress onProgress, {
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int knownFileSize = 0,
  }) async {
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    if (_completionGuard != null && !_completionGuard!.isCompleted) {
      await _completionGuard!.future;
      return;
    }
    final completer = Completer<void>();
    StreamSubscription? sub;
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
        if (cancelToken.isCancelled) return;
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
      _alivenessWatchdog?.cancel();
      _alivenessWatchdog = Timer.periodic(const Duration(seconds: 10), (_) {
        if (cancelToken.isCancelled) return;
        if (!_torrentService.isTorrentAlive(id)) {
          _alivenessWatchdog?.cancel();
          _alivenessWatchdog = null;
          sub?.cancel();
          _activeSubs.remove(id);
          _activeTorrentIds.remove(id);
          TorrentSubscriptionRegistry.instance.unregister(id, this);
          if (!completer.isCompleted) {
            completer.completeError(DioException(
              requestOptions: RequestOptions(path: url),
              type: DioExceptionType.unknown,
              error: 'Torrent handle lost (aliveness poll).',
            ));
          }
        }
      });
      sub = _torrentService.torrentUpdates.listen((torrents) async {
        if (cancelToken.isCancelled) return;
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
        List<Map<String, dynamic>>? resolvedFiles = getTorrentFiles?.call() ?? cachedAccurateFiles;
        // FIX v2.0.0: Always fetch files from engine when metadata is available,
        // and only update if the list has changed.
        if (torrent.hasMetadata) {
          try {
            final nativeFiles = _torrentService.getFiles(id);
            if (nativeFiles.isNotEmpty) {
              final newResolved = nativeFiles.map((f) {
                final bool isEstimated = f.downloadedBytes < 0 ||
                    (f.downloadedBytes == 0 && f.size > 0);
                final dl =
                    f.safeDownloadedBytes < 0 ? 0 : f.safeDownloadedBytes;
                return {
                  'name': f.name,
                  'length': f.size,
                  'downloadedBytes': dl,
                  'selected': f.selected,
                  'priority': f.priority,
                  // FIX v2.0.0-Bug1: size==0 means unknown, NOT 100% complete.
                  'progress': f.size > 0 ? (dl / f.size).clamp(0.0, 1.0) : 0.0,
                  'isComplete': f.size > 0 && dl >= f.size,
                  'progressEstimated': isEstimated,
                };
              }).toList();
              // Only update if different from cached or resolvedFiles
              if (cachedAccurateFiles == null ||
                  _torrentFileListsDiffer(cachedAccurateFiles, newResolved)) {
                resolvedFiles = newResolved;
                cachedAccurateFiles = resolvedFiles;
              } else {
                resolvedFiles = cachedAccurateFiles;
              }
            }
          } catch (e, st) {
            _log.fine('Failed to fetch native file list: $e', e, st);
          }
        }
        resolvedFiles ??= cachedAccurateFiles;
        // FIX v2.0.0: total size must ALWAYS be computed from the full file list.
        // Added fallback to torrent.totalDone when totalWanted is 0 (pre-metadata).
        // FIX v2.0.0-Bug11: Prefer selectedFilesSum over allFilesSum for
        // totalSize because the user only cares about selected files' size.
        // Also added totalWantedDone as a last-resort fallback for v2.0.0
        // where totalWanted can be 0 even with active downloads.
        final effectiveFiles = resolvedFiles ?? cachedAccurateFiles;
        final int allFilesSum = effectiveFiles?.fold<int>(
                0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0)) ??
            0;
        final int selectedFilesSum = effectiveFiles
                ?.where((f) => (f['selected'] as bool?) ?? true)
                .fold<int>(
                    0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0)) ??
            0;
        // FIX v2.0.0-BugTotalSize: Added knownFileSize as final fallback.
        // When files are not yet available (null/empty) AND torrent stats
        // report 0 for all size fields, fall back to the known file size
        // passed from handleTorrentDownload. This prevents the UI from
        // showing "0 B" total size during metadata/checking phases.
        // FIX v2.0.0-BugFalse100: Never fall back to a "bytes done" counter
        // (totalWantedDone / totalDone) when computing the TOTAL size.
        // Both totalSize and downloadedBytes derived from the same "done"
        // field whenever totalWanted was still 0 (pre-metadata/checking
        // phase), which made totalSize == downloadedBytes and tripped the
        // completion check instantly — showing 100% before the download
        // had actually started.
        final totalSize = selectedFilesSum > 0
            ? selectedFilesSum
            : (allFilesSum > 0
                ? allFilesSum
                : (torrent.totalWanted > 0
                    ? torrent.totalWanted
                    : (knownFileSize > 0
                        ? knownFileSize
                        : selectedFilesSum)));
        currentTotalSize = totalSize;
        final bool hasReliableTotalSize = selectedFilesSum > 0 ||
            allFilesSum > 0 ||
            torrent.totalWanted > 0;
        final fileCount =
            effectiveFiles?.length ?? (cachedAccurateFiles?.length ?? 0);
        final inBg = DownloadEngine.isInBackground;
        if (fileCount > 0 &&
            !shouldSkipPerFileSync(fileCount, inBackground: inBg)) {
          final syncInterval =
              computeAdaptiveSyncInterval(fileCount, inBackground: inBg);
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
                  if (effectiveFiles != null)
                    for (final f in effectiveFiles)
                      if (f['name'] != null)
                        normKey(f['name'] as String):
                            (f['selected'] as bool?) ?? true
                };
                final previousPriorityMap = <String, int>{
                  if (effectiveFiles != null)
                    for (final f in effectiveFiles)
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
              _log.warning('Accurate file sync failed: $e', e, st);
            }
          }
        }
        // FIX v2.0.0: Fall back to totalDone when totalWantedDone is 0.
        // v2.0.0 may report 0 for totalWantedDone before the first piece
        // completes, but totalDone tracks actual bytes received.
        final rawDownloaded = torrent.totalWantedDone > 0
            ? torrent.totalWantedDone
            : (torrent.totalDone > 0 ? torrent.totalDone : 0);
        final safeProgress =
            torrent.progress.isFinite ? torrent.progress.clamp(0.0, 1.0) : 0.0;
        final filesToUpdate = resolvedFiles ?? cachedAccurateFiles;
        if (filesToUpdate != null && filesToUpdate.isNotEmpty) {
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
                      filesToUpdate, pieceRatio, rawDownloaded);
                  pieceMapped = true;
                }
              }
            } catch (e, st) {
              _log.fine('Piece progress query failed: $e', e, st);
            }
          }
          if (!pieceMapped) {
            updateFilesWithNativeProgress(
                filesToUpdate, safeProgress, rawDownloaded);
          }
          resolvedFiles = filesToUpdate;
          cachedAccurateFiles = filesToUpdate;
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
        // FIX v2.0.0-BugFalse100: Completion detection must be strict to
        // avoid premature 100% before the download starts. Requires:
        //  1) metadata is actually resolved (torrent.hasMetadata), and
        //  2) totalSize came from a reliable source (real file list or a
        //     genuine totalWanted from libtorrent — never a stale
        //     knownFileSize/knownFileSize==0 combo), and
        //  3) downloadedBytes actually reached that total.
        final bool isCompleted = torrent.hasMetadata &&
            hasReliableTotalSize &&
            (stateLabel == 'seeding' ||
                (totalSize > 0 && downloadedBytes >= totalSize) ||
                (torrent.progress >= 1.0 &&
                    totalSize > 0 &&
                    torrent.totalWanted > 0 &&
                    torrent.totalWantedDone >= torrent.totalWanted));
        if (isCompleted) {
          final isSeedingEnabled = TorrentService.seedingEnabled;
          final finalCycleState = (stateLabel == 'seeding' && isSeedingEnabled)
              ? CycleState.seeding
              : CycleState.completed;
          final finalStatusMessage =
              (stateLabel == 'seeding' && isSeedingEnabled)
                  ? 'Seeding…'
                  : 'Completed';
          final List<Map<String, dynamic>>? finalFiles =
              resolvedFiles ?? cachedAccurateFiles;
          if (finalFiles != null && finalFiles.isNotEmpty) {
            for (final f in finalFiles) {
              final len = (f['length'] as num?)?.toInt() ?? 0;
              if (len > 0) {
                f['downloadedBytes'] = len;
                f['progress'] = 1.0;
                f['isComplete'] = true;
                f['progressEstimated'] = false;
              }
            }
          }
          onProgress(DownloadProgress(
            downloadedBytes: totalSize > 0 ? totalSize : downloadedBytes,
            fileSize: totalSize,
            speed: isSeedingEnabled ? speed : 0,
            eta: 0,
            torrentFiles: finalFiles,
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
      await completer.future;
    } finally {
      _stallWatchdog?.cancel();
      _stallWatchdog = null;
      _alivenessWatchdog?.cancel();
      _alivenessWatchdog = null;
      _completionGuard = null;
      await sub?.cancel();
      _activeSubs.remove(id);
      TorrentSubscriptionRegistry.instance.unregister(id, this);
    }
  }
}
