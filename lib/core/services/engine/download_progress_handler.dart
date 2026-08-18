import 'dart:async';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import '../../di/injection.dart';
import '../download_engine.dart';
import '../engines/http_download_engine.dart';
import '../yt_counterpart_coordinator.dart';
import 'cycle_state_resolver.dart';
import 'engine_utils.dart';
import 'torrent_file_normalizer.dart';

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
  int _lastEmittedBytes = 0;
  int _lastEmittedFileSize = 0;
  String _lastEmittedStatusMessage = '';
  int _lastEmittedPeerCount = 0;
  int _lastEmittedSeedCount = 0;
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
  int _lastChunkDetailsHash = 0;
  int _emittedChunkDetailsHash = -1;

  int get chunkFingerprint => _lastChunkDetailsHash;

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
  set selfActuallyFinalizedForTesting(bool val) => _selfActuallyFinalized = val;

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

  /// Handles URL expiration with a rolling 5-minute window.
  /// After 3 expirations within the window, emits [CycleState.failed]
  /// and throws [DownloadIntegrityException] (terminal).
  /// On the 1st and 2nd, returns normally so the caller can emit
  /// [CycleState.updatingLinks] and throw [UrlExpiredException] (recoverable).
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

  YtCounterpartCoordinator? _cachedYtCoordinator;
  bool _ytCoordinatorResolved = false;
  static final _log = Logger('DownloadProgressHandler');

  YtCounterpartCoordinator? get _ytCoordinator {
    if (!_ytCoordinatorResolved) {
      _ytCoordinatorResolved = true;
      try {
        if (getIt.isRegistered<YtCounterpartCoordinator>()) {
          _cachedYtCoordinator = getIt<YtCounterpartCoordinator>();
        }
      } catch (e, st) {
        _log.fine('Failed to resolve YtCounterpartCoordinator: $e', e, st);
      }
    }
    return _cachedYtCoordinator;
  }

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
  }) {
    try {
      if (getIt.isRegistered<YtCounterpartCoordinator>()) {
        _cachedYtCoordinator = getIt<YtCounterpartCoordinator>();
        _ytCoordinatorResolved = true;
      }
    } catch (e, st) {
      _log.fine('Initial YtCounterpartCoordinator resolve skipped: $e', e, st);
    }
  }

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

  /// Main progress processing entry point.
  ///
  /// The [isCounterpartStale] parameter was removed — it was never passed
  /// by any caller and its only effect was a dead assignment to
  /// [lastHasEstimatedFileProgress].
  Future<void> handleWorkerProgress(
    Map<String, dynamic> p, {
    int? ytCounterpartDownloadedOverride,
    bool adaptiveThreads = false,
    int effectiveThreadCount = 1,
    HttpDownloadEngine? httpEngine,
    bool isCounterpartUnregistered = false,
  }) async {
    if (cancelToken.isCancelled) return;

    if (adaptiveThreads && httpEngine != null) {
      final speed = (p['speed'] as num?)?.toDouble() ?? 0.0;
      if (speed > 0) {
        httpEngine.recordSample(taskId, speed, effectiveThreadCount);
      }
    }

    List<ChunkDetail>? chunkDetails;
    if (p['chunkDetails'] is List) {
      chunkDetails = (p['chunkDetails'] as List)
          .whereType<Map>()
          .map((c) => ChunkDetail.fromMap(Map<String, dynamic>.from(c)))
          .toList();
    }

    lastDownloadedBytes =
        (p['downloadedBytes'] as num?)?.toInt() ?? lastDownloadedBytes;
    // FIX v2.0.0-BugFileSize: Don't overwrite a known file size with 0.
    // v2.0.0 emits fileSize: 0 during pre-metadata/checking phases, which
    // caused the UI to show "0 B" total size even when knownFileSize was
    // previously set. Only update if the new value is positive or we have
    // no previous value.
    final newFileSize = (p['fileSize'] as num?)?.toInt();
    if (newFileSize != null && (newFileSize > 0 || lastFileSize == 0)) {
      lastFileSize = newFileSize;
    }

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

    if (p['done'] == true ||
        p['isDone'] == true ||
        p['selfActuallyFinalized'] == true) {
      _selfActuallyFinalized = true;
    }

    cycle ??= deriveCycleState(sm, cancelToken.isCancelled, isTorrent);

    // ── YouTube counterpart coordination ──────────────────────────────
    if (ytStreamKind != null && ytStreamKind != YtStreamKind.combined) {
      try {
        final coord = _ytCoordinator;
        if (coord != null) {
          final cpId = coord.getCounterpartId(taskId);
          if (cpId != null) {
            final live = coord.getLiveBytes(cpId);
            if (live != null) {
              ytCounterpartDownloadedOverride = live;
              isCounterpartUnregistered = false;
            }
          }
        }
      } catch (e, st) {
        _log.fine('Error looking up live bytes from coordinator: $e', e, st);
      }
    }

    final dynamicYtCounterpartSize =
        (p['ytCounterpartSize'] as num?)?.toInt() ?? ytCounterpartSize;
    final dynamicYtCounterpartDownloaded = ytCounterpartDownloadedOverride ??
        (p['ytCounterpartDownloadedBytes'] as num?)?.toInt() ??
        ytCounterpartDownloadedBytes;

    final isWaitingCycle = cycle == CycleState.downloading ||
        cycle == CycleState.starting ||
        cycle == CycleState.resuming;

    if (isCounterpartUnregistered && ytStreamKind != null && isWaitingCycle) {
      _counterpartWaitStart ??= DateTime.now();
      final waitDiff = DateTime.now().difference(_counterpartWaitStart!);

      // Try to refresh counterpart task ID from coordinator
      try {
        final coord = _ytCoordinator;
        if (coord != null) {
          final cpId = coord.getCounterpartId(taskId);
          if (cpId != null) {
            final live = coord.getLiveBytes(cpId);
            if (live != null) {
              isCounterpartUnregistered = false;
              ytCounterpartDownloadedOverride = live;
            }
          }
        }
      } catch (e, st) {
        _log.fine('Error refreshing counterpart task ID: $e', e, st);
      }

      if (!isCounterpartUnregistered) {
        _counterpartWaitStart = null;
      } else {
        if (waitDiff > const Duration(minutes: 5)) {
          _counterpartWaitStart = null;

          // FIX: Emit updatingLinks BEFORE _handleUrlExpired() so the UI
          // shows a consistent "Refreshing links…" transition even on the
          // final retry before failure. Previously, on the 3rd expiration,
          // _handleUrlExpired() would emit CycleState.failed and throw
          // DownloadIntegrityException, causing the UI to jump directly
          // from downloading → failed without ever showing updatingLinks.
          emit(DownloadProgress(
            downloadedBytes: lastDownloadedBytes,
            fileSize: lastFileSize,
            speed: 0,
            eta: null,
            cycleState: CycleState.updatingLinks,
            statusMessage: 'Refreshing links…',
            ytStreamKind: ytStreamKind,
            ytCounterpartSize: dynamicYtCounterpartSize,
            ytCounterpartDownloadedBytes: dynamicYtCounterpartDownloaded,
          ));

          // May throw DownloadIntegrityException if 3 retries exhausted
          _handleUrlExpired();

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
      }
    } else {
      _counterpartWaitStart = null;
    }

    // ── Completion gate for dual-stream YT ───────────────────────────
    if (cycle == CycleState.completed &&
        ytStreamKind != null &&
        ytStreamKind != YtStreamKind.combined) {
      final cpSize = dynamicYtCounterpartSize;
      final cpLive = dynamicYtCounterpartDownloaded ?? 0;
      final bool counterpartResolved = cpSize != null && cpSize > 0;
      final bool counterpartDone = counterpartResolved && cpLive >= cpSize;
      final bool selfFinalized = _selfActuallyFinalized ||
          (lastFileSize > 0 && lastDownloadedBytes >= lastFileSize);
      if (!selfFinalized || !counterpartDone) {
        cycle = counterpartDone ? CycleState.merging : CycleState.downloading;
      }
    }

    // ── Chunk detail aggregation (HTTP only) ─────────────────────────
    final pTotalChunks = (p['totalChunks'] as num?)?.toInt();
    final pCompletedChunks = (p['completedChunks'] as num?)?.toInt();
    final chunkList = chunkDetails;
    final totalParts =
        chunkList?.length ?? pTotalChunks ?? lastTotalChunks ?? 0;
    final isDone = cycle == CycleState.completed;
    final doneParts = chunkList != null
        ? (isDone
            ? chunkList.length
            : chunkList.where((c) => c.isComplete).length)
        : (pCompletedChunks ??
            (isDone ? totalParts : lastCompletedChunks ?? 0));

    lastChunkDetails = chunkDetails ?? lastChunkDetails;
    if (chunkDetails != null) {
      _lastChunkDetailsHash = chunkDetails.fold<int>(
        0,
        (h, c) => h ^ Object.hash(c.start, c.end, c.size, c.downloaded),
      );
    }
    lastTotalChunks = isTorrent
        ? lastTotalChunks
        : (chunkDetails != null
            ? chunkList?.length
            : (pTotalChunks ?? lastTotalChunks));
    lastCompletedChunks = isTorrent
        ? lastCompletedChunks
        : (chunkDetails != null
            ? doneParts
            : (pCompletedChunks ?? lastCompletedChunks));

    final rawPauseReason = p['pauseReason'];
    final PauseReason? pauseReason = rawPauseReason is PauseReason
        ? rawPauseReason
        : (rawPauseReason is String
            ? PauseReason.fromName(rawPauseReason)
            : null);

    final bool chunkHashChanged =
        _lastChunkDetailsHash != _emittedChunkDetailsHash;
    final List<ChunkDetail>? chunkDetailsToEmit;
    if (chunkHashChanged) {
      chunkDetailsToEmit = lastChunkDetails;
      _emittedChunkDetailsHash = _lastChunkDetailsHash;
    } else {
      chunkDetailsToEmit = null;
    }

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
      chunkDetails: chunkDetailsToEmit,
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
      downloadedFileBytes: lastDownloadedFileBytes,
      hasEstimatedFileProgress: (p['hasEstimatedFileProgress'] as bool?) ??
          lastHasEstimatedFileProgress,
      torrentId: torrentId,
      chunkFingerprint: _lastChunkDetailsHash,
    );

    // ── Throttled emission ────────────────────────────────────────────
    final int intervalMs = isTorrent
        ? (DownloadEngine.isInBackground ? 3000 : 500)
        : getEffectiveIntervalMs();
    final now = DateTime.now();
    final bool canEmitNow = lastProgressEmitTime == null ||
        now.difference(lastProgressEmitTime!) >=
            Duration(milliseconds: intervalMs);
    final isTerminalChange = cycle == CycleState.failed ||
        cycle == CycleState.completed ||
        cycle == CycleState.paused;
    final isCycleStateChange = cycle != _lastEmittedCycleState;

    bool isSubstantialDelta = false;
    if (isTorrent) {
      final size = progress.fileSize > 0 ? progress.fileSize : lastFileSize;
      final deltaBytes = (progress.downloadedBytes - _lastEmittedBytes).abs();
      final minTrigger = size > 0 ? (size * 0.01).ceil() : (1024 * 1024);
      // FIX v2.0.0-BugFiles: Include torrentFiles length change in the
      // substantial delta check. Previously, if only the file list changed
      // (not bytes/peers/seeds/status), the progress was throttled and
      // file info was delayed, causing "no files" on the details screen.
      isSubstantialDelta = deltaBytes >= math.max(minTrigger, 1024 * 1024) ||
          (sm != _lastEmittedStatusMessage) ||
          progress.fileSize != _lastEmittedFileSize ||
          ((p['numPeers'] as num?)?.toInt() ?? 0) != _lastEmittedPeerCount ||
          ((p['numSeeds'] as num?)?.toInt() ?? 0) != _lastEmittedSeedCount ||
          (progress.torrentFiles != null &&
              progress.torrentFiles!.length !=
                  (lastTorrentFiles?.length ?? -1));
    }

    if (canEmitNow ||
        isTerminalChange ||
        isCycleStateChange ||
        isSubstantialDelta) {
      _throttleTimer?.cancel();
      _throttleTimer = null;
      _pendingProgress = null;
      lastProgressEmitTime = now;
      _lastEmittedBytes = progress.downloadedBytes;
      _lastEmittedFileSize = progress.fileSize;
      _lastEmittedStatusMessage = sm ?? '';
      _lastEmittedPeerCount = (p['numPeers'] as num?)?.toInt() ?? 0;
      _lastEmittedSeedCount = (p['numSeeds'] as num?)?.toInt() ?? 0;
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
            _lastEmittedBytes = pending.downloadedBytes;
            _lastEmittedFileSize = pending.fileSize;
            _lastEmittedStatusMessage = pending.statusMessage ?? '';
            emit(pending);
          }
        });
      }
    }
  }

  void _handleTorrentFiles(List pTorrentFiles) {
    final result =
        TorrentFileNormalizer.normalizeTorrentFileList(pTorrentFiles);
    // FIX v2.0.0-Bug8: If normalization produced an empty list from a
    // non-empty input (all items were invalid/non-Map), do NOT update
    // any state. The previous code set lastTorrentFiles = [] which caused
    // the UI to show "0 files" instead of keeping the previous valid list
    // or showing "loading…".
    if (result.normalizedFiles.isEmpty) {
      // Input was non-empty but all items were invalid — keep existing state
      return;
    }
    lastTorrentFiles = result.normalizedFiles;
    lastTotalFiles = result.total;
    lastTotalFileBytes = result.bytes;
    lastCompletedFiles = result.done;
    lastDownloadedFileBytes = result.downloaded;
    lastHasEstimatedFileProgress = result.hasEstimated;
  }
}
