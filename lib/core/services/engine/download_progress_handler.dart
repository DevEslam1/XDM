import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../di/injection.dart';
import '../engines/http_download_engine.dart';
import '../yt_counterpart_coordinator.dart';
import 'cycle_state_resolver.dart';
import 'engine_exceptions.dart';
import 'engine_models.dart';
import 'engine_utils.dart';
import 'torrent_file_normalizer.dart';

/// Encapsulates progress state management and throttling for download tasks.
/// Non-locking throttle using plain timestamps and scheduled timers.
class DownloadProgressHandler {
  final String taskId;
  final ValueChangedProgress onProgress;
  final CancelToken cancelToken;
  final String? resolvedFileName;
  final bool resolvedSupportsResume;
  final YtStreamKind? ytStreamKind;
  final int? ytCounterpartSize;
  final int? ytCounterpartDownloadedBytes;
  final bool isTorrent;
  final int? torrentId;
  final int Function() getEffectiveIntervalMs;

  int lastDownloadedBytes;
  int lastFileSize;
  List<ChunkDetail>? lastChunkDetails;
  int? lastTotalChunks;
  int? lastCompletedChunks;
  List<Map<String, dynamic>>? lastTorrentFiles;
  int? lastTotalFiles;
  int? lastCompletedFiles;
  int? lastTotalFileBytes;
  int? lastDownloadedFileBytes;
  bool? lastHasEstimatedFileProgress;
  DateTime? lastProgressEmitTime;

  Timer? _throttleTimer;
  DownloadProgress? _pendingProgress;
  CycleState? _lastEmittedCycleState;
  DateTime? _counterpartWaitStart;
  int _urlExpireCount = 0;
  DateTime? _urlExpireWindowStart;
  bool _selfActuallyFinalized = false;

  @visibleForTesting
  DateTime? get counterpartWaitStartForTesting => _counterpartWaitStart;

  @visibleForTesting
  set counterpartWaitStartForTesting(DateTime? val) =>
      _counterpartWaitStart = val;

  @visibleForTesting
  int get urlExpireCountForTesting => _urlExpireCount;

  @visibleForTesting
  set urlExpireCountForTesting(int val) => _urlExpireCount = val;

  @visibleForTesting
  set urlExpireWindowStartForTesting(DateTime? val) =>
      _urlExpireWindowStart = val;

  @visibleForTesting
  bool get selfActuallyFinalizedForTesting => _selfActuallyFinalized;

  @visibleForTesting
  set selfActuallyFinalizedForTesting(bool val) =>
      _selfActuallyFinalized = val;

  void markDone() {
    _selfActuallyFinalized = true;
  }

  void handleEngineMessage(EngineMessageType type) {
    if (type == EngineMessageType.done) {
      _selfActuallyFinalized = true;
    }
  }

  @visibleForTesting
  void handleUrlExpired() => _handleUrlExpired();

  void _handleUrlExpired() {
    final now = DateTime.now();
    if (_urlExpireWindowStart == null ||
        now.difference(_urlExpireWindowStart!) > const Duration(minutes: 5)) {
      _urlExpireWindowStart = now;
      _urlExpireCount = 1;
    } else {
      _urlExpireCount++;
    }
    if (_urlExpireCount >= 3) {
      if (_urlExpireCount == 3) {
        emit(DownloadProgress(
          downloadedBytes: lastDownloadedBytes,
          fileSize: lastFileSize,
          speed: 0,
          eta: null,
          cycleState: CycleState.failed,
          statusMessage: 'Failed: Counterpart stream lost after 3 retries',
          ytStreamKind: ytStreamKind,
          ytCounterpartSize: ytCounterpartSize,
          ytCounterpartDownloadedBytes: ytCounterpartDownloadedBytes,
        ));
      }
      _urlExpireCount = 0;
      _urlExpireWindowStart = null;
      throw const DownloadIntegrityException(
        'Exceeded maximum URL expiration retries (3 within 5 minutes). '
        'The source may require re-authentication.',
      );
    }
  }

  final List<Map<String, dynamic>>? Function()? getTorrentFiles;

  DownloadProgressHandler({
    required this.taskId,
    required this.onProgress,
    required this.cancelToken,
    required this.resolvedFileName,
    required this.resolvedSupportsResume,
    required this.ytStreamKind,
    required this.ytCounterpartSize,
    required this.ytCounterpartDownloadedBytes,
    required this.isTorrent,
    required this.getEffectiveIntervalMs,
    required this.lastDownloadedBytes,
    required this.lastFileSize,
    this.torrentId,
    this.lastChunkDetails,
    this.lastTotalChunks,
    this.lastCompletedChunks,
    this.getTorrentFiles,
  });

  void emit(DownloadProgress progress) {
    if (cancelToken.isCancelled) return;
    _lastEmittedCycleState = progress.cycleState;
    onProgress(progress);
  }

  void dispose() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _pendingProgress = null;
  }

  static CycleState deriveCycleState(
    String? statusMessage,
    bool isCancelled,
    bool isTorrent,
  ) {
    return CycleStateResolver.resolve(
      statusMessage: statusMessage,
      isCancelled: isCancelled,
      isTorrent: isTorrent,
    );
  }

  Future<void> handleProgress(
    Map<String, dynamic> p, {
    int? ytCounterpartDownloadedOverride,
    bool adaptiveThreads = false,
    int effectiveThreadCount = 1,
    HttpDownloadEngine? httpEngine,
    TimestampedLruMap<String, String>? ytCounterpartTaskIds,
    TimestampedLruMap<String, int>? ytLiveBytes,
  }) async {
    int? override = ytCounterpartDownloadedOverride;
    bool isCounterpartUnregistered = false;
    if (override == null &&
        ytLiveBytes != null &&
        ytCounterpartTaskIds != null) {
      final cpId = ytCounterpartTaskIds[taskId];
      if (cpId != null) {
        final lastAccess = ytLiveBytes.getLastAccessed(cpId);
        if (lastAccess == null ||
            DateTime.now().difference(lastAccess) <=
                const Duration(seconds: 15)) {
          override = ytLiveBytes[cpId];
        }
      } else if (ytStreamKind != null) {
        isCounterpartUnregistered = true;
      }
    }
    return handleWorkerProgress(
      p,
      ytCounterpartDownloadedOverride: override,
      adaptiveThreads: adaptiveThreads,
      effectiveThreadCount: effectiveThreadCount,
      httpEngine: httpEngine,
      isCounterpartUnregistered: isCounterpartUnregistered,
    );
  }

  Future<void> handleWorkerProgress(
    Map<String, dynamic> p, {
    int? ytCounterpartDownloadedOverride,
    bool adaptiveThreads = false,
    int effectiveThreadCount = 1,
    HttpDownloadEngine? httpEngine,
    bool isCounterpartUnregistered = false,
    bool isCounterpartStale = false,
  }) async {
    if (cancelToken.isCancelled) return;

    if (adaptiveThreads && httpEngine != null) {
      final speed = (p['speed'] as num?)?.toDouble() ?? 0.0;
      if (speed > 0) {
        httpEngine.recordSample(taskId, speed, effectiveThreadCount);
      }
    }

    // Chunk details mapping
    List<ChunkDetail>? chunkDetails;
    if (p['chunkDetails'] is List) {
      chunkDetails = (p['chunkDetails'] as List)
          .whereType<Map>()
          .map((c) => ChunkDetail.fromMap(Map<String, dynamic>.from(c)))
          .toList();
    }

    lastDownloadedBytes =
        (p['downloadedBytes'] as num?)?.toInt() ?? lastDownloadedBytes;
    lastFileSize = (p['fileSize'] as num?)?.toInt() ?? lastFileSize;

    // Torrent file handling
    final pTorrentFiles = p['torrentFiles'];
    if (pTorrentFiles is List && pTorrentFiles.isNotEmpty) {
      _handleTorrentFiles(pTorrentFiles);
    }

    var sm = p['statusMessage'] as String?;
    CycleState? cycle;
    if (cancelToken.isCancelled) {
      cycle = CycleState.paused;
    } else if (p['cycleState'] is CycleState) {
      cycle = p['cycleState'] as CycleState;
      if (cycle == CycleState.completed) _selfActuallyFinalized = true;
    } else if (p['cycleState'] is String) {
      cycle = CycleState.fromName(p['cycleState'] as String);
      if (cycle == CycleState.completed) _selfActuallyFinalized = true;
    }
    if (p['done'] == true || p['isDone'] == true || p['selfActuallyFinalized'] == true) {
      _selfActuallyFinalized = true;
    }
    cycle ??= deriveCycleState(sm, cancelToken.isCancelled, isTorrent);

    // Fix 1: Live lookup for YouTube counterpart downloaded bytes regardless of registration status
    if (ytStreamKind != null && ytStreamKind != YtStreamKind.combined) {
      try {
        if (getIt.isRegistered<YtCounterpartCoordinator>()) {
          final coord = getIt<YtCounterpartCoordinator>();
          final cpId = coord.getCounterpartId(taskId);
          if (cpId != null) {
            final live = coord.getLiveBytes(cpId);
            if (live != null) {
              ytCounterpartDownloadedOverride = live;
              isCounterpartUnregistered = false;
            }
          }
        }
      } catch (_) {}
    }

    // Fix 2: Dynamic YouTube counterpart size & downloaded resolution
    final dynamicYtCounterpartSize =
        (p['ytCounterpartSize'] as num?)?.toInt() ?? ytCounterpartSize;
    final dynamicYtCounterpartDownloaded = ytCounterpartDownloadedOverride ??
        (p['ytCounterpartDownloadedBytes'] as num?)?.toInt() ??
        ytCounterpartDownloadedBytes;

    final isWaitingCycle = cycle == CycleState.downloading ||
        cycle == CycleState.starting ||
        cycle == CycleState.resuming;

    if (isCounterpartStale) {
      lastHasEstimatedFileProgress = true;
    }

    if (isCounterpartUnregistered &&
        ytStreamKind != null &&
        isWaitingCycle) {
      _counterpartWaitStart ??= DateTime.now();
      final waitDiff = DateTime.now().difference(_counterpartWaitStart!);

      // Trigger re-check of counterpart task ID via YtCounterpartCoordinator if accessible
      try {
        if (getIt.isRegistered<YtCounterpartCoordinator>()) {
          final coord = getIt<YtCounterpartCoordinator>();
          final cpId = coord.getCounterpartId(taskId);
          if (cpId != null) {
            final live = coord.getLiveBytes(cpId);
            if (live != null) {
              isCounterpartUnregistered = false;
              ytCounterpartDownloadedOverride = live;
            }
          }
        }
      } catch (_) {}

      // Decouple slow-start: extend timeout to 5 minutes before throwing UrlExpiredException
      if (waitDiff > const Duration(minutes: 5)) {
        _counterpartWaitStart = null;
        _handleUrlExpired();
        emit(DownloadProgress(
          downloadedBytes: lastDownloadedBytes,
          fileSize: lastFileSize,
          speed: 0,
          eta: null,
          cycleState: CycleState.updatingLinks,
          statusMessage: 'Refreshing links…',
        ));
        throw const UrlExpiredException(
          'Counterpart stream lost — refresh required',
          refreshAllMirrors: true,
        );
      }
      final cpSize = dynamicYtCounterpartSize;
      final cpDone = cpSize != null &&
          cpSize > 0 &&
          (dynamicYtCounterpartDownloaded ?? 0) >= cpSize;
      if (cpDone) {
        _counterpartWaitStart = null;
        final bool selfDone =
            lastFileSize > 0 && lastDownloadedBytes >= lastFileSize;
        if (selfDone) {
          cycle = CycleState.merging;
          sm = 'Merging audio + video…';
        } else {
          cycle = CycleState.downloading;
          sm = 'Downloading (counterpart ready)…';
        }
      } else if (waitDiff > const Duration(seconds: 30)) {
        cycle = CycleState.retrying;
        sm = 'Waiting for counterpart stream…';
      } else {
        cycle = CycleState.starting;
        sm = 'Waiting for counterpart stream…';
      }
    } else {
      _counterpartWaitStart = null;
    }

    // YT Combined Sync Check
    if (cycle == CycleState.completed &&
        ytStreamKind != null &&
        ytStreamKind != YtStreamKind.combined) {
      final cpSize = dynamicYtCounterpartSize;
      final cpLive = dynamicYtCounterpartDownloaded ?? 0;

      final bool counterpartResolved = cpSize != null && cpSize > 0;
      final bool counterpartDone = counterpartResolved && cpLive >= cpSize;
      final bool selfFinalized =
          _selfActuallyFinalized || (lastFileSize > 0 && lastDownloadedBytes >= lastFileSize);

      if (!selfFinalized || !counterpartDone) {
        cycle = counterpartDone ? CycleState.merging : CycleState.downloading;
      }
    }

    final chunkList = chunkDetails;
    final totalParts = chunkList?.length ?? 0;
    final isDone = cycle == CycleState.completed;
    final doneParts = chunkList == null
        ? 0
        : (isDone ? totalParts : chunkList.where((c) => c.isComplete).length);

    lastChunkDetails = chunkDetails ?? lastChunkDetails;
    lastTotalChunks =
        (isTorrent || chunkDetails == null) ? lastTotalChunks : totalParts;
    lastCompletedChunks =
        (isTorrent || chunkDetails == null) ? lastCompletedChunks : doneParts;

    final rawPauseReason = p['pauseReason'];
    final PauseReason? pauseReason = rawPauseReason is PauseReason
        ? rawPauseReason
        : (rawPauseReason is String
            ? PauseReason.fromName(rawPauseReason)
            : null);

    final progress = DownloadProgress(
      downloadedBytes: lastDownloadedBytes,
      fileSize: lastFileSize,
      speed: (p['speed'] as num?)?.toDouble() ?? 0.0,
      eta: (p['eta'] as num?)?.toInt(),
      chunks:
          p['chunks'] != null ? List<double>.from(p['chunks'] as List) : null,
      fileName: p['fileName'] as String? ?? resolvedFileName,
      supportsResume: p['supportsResume'] as bool? ?? resolvedSupportsResume,
      statusMessage: sm,
      ytStreamKind: ytStreamKind,
      ytCounterpartSize: dynamicYtCounterpartSize,
      ytDownloadedBytes: (p['ytDownloadedBytes'] as num?)?.toInt() ??
          (ytStreamKind != null ? lastDownloadedBytes : null),
      ytCounterpartDownloadedBytes: dynamicYtCounterpartDownloaded,
      chunkDetails: lastChunkDetails,
      cycleState: cycle,
      pauseReason: pauseReason,
      totalChunks:
          (isTorrent || lastChunkDetails == null) ? null : lastTotalChunks,
      completedChunks:
          (isTorrent || lastChunkDetails == null) ? null : lastCompletedChunks,
      torrentFiles: lastTorrentFiles,
      totalFiles: lastTotalFiles,
      completedFiles: lastCompletedFiles,
      totalFileBytes: lastTotalFileBytes,
      hasEstimatedFileProgress: (p['hasEstimatedFileProgress'] as bool?) ??
          lastHasEstimatedFileProgress,
      torrentId: torrentId,
    );

    final intervalMs = getEffectiveIntervalMs();
    final now = DateTime.now();
    final bool canEmitNow = lastProgressEmitTime == null ||
        now.difference(lastProgressEmitTime!) >=
            Duration(milliseconds: intervalMs);
    final isTerminalChange = cycle == CycleState.failed ||
        cycle == CycleState.completed ||
        cycle == CycleState.paused;
    final isCycleStateChange = cycle != _lastEmittedCycleState;

    if (canEmitNow || isTerminalChange || isCycleStateChange) {
      _throttleTimer?.cancel();
      _throttleTimer = null;
      _pendingProgress = null;
      lastProgressEmitTime = now;
      emit(progress);
    } else {
      _pendingProgress = progress;
      if (_throttleTimer == null) {
        final elapsed = now.difference(lastProgressEmitTime!).inMilliseconds;
        final remainingMs = intervalMs - elapsed;
        _throttleTimer =
            Timer(Duration(milliseconds: remainingMs.clamp(1, intervalMs)), () {
          _throttleTimer = null;
          if (cancelToken.isCancelled) {
            _pendingProgress = null;
            return;
          }
          final pending = _pendingProgress;
          if (pending != null) {
            _pendingProgress = null;
            lastProgressEmitTime = DateTime.now();
            emit(pending);
          }
        });
      }
    }
  }

  void _handleTorrentFiles(List pTorrentFiles) {
    final result =
        TorrentFileNormalizer.normalizeTorrentFileList(pTorrentFiles);
    lastTorrentFiles = result.normalizedFiles;
    lastTotalFiles = result.total;
    lastTotalFileBytes = result.bytes;
    lastDownloadedFileBytes = result.downloaded;
    lastCompletedFiles = result.done;
    lastHasEstimatedFileProgress = result.hasEstimated;
  }
}
