import 'dart:async';
import 'package:dio/dio.dart';
import '../engines/http_download_engine.dart';
import 'cycle_state_resolver.dart';
import 'engine_models.dart';
import 'engine_utils.dart';

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
  DateTime? lastProgressEmitTime;

  Timer? _throttleTimer;
  DownloadProgress? _pendingProgress;
  CycleState? _lastEmittedCycleState;

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
    if (override == null && ytLiveBytes != null && ytCounterpartTaskIds != null) {
      final cpId = ytCounterpartTaskIds[taskId];
      if (cpId != null) {
        final lastAccess = ytLiveBytes.getLastAccessed(cpId);
        if (lastAccess == null ||
            DateTime.now().difference(lastAccess) <= const Duration(seconds: 15)) {
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

    lastDownloadedBytes = (p['downloadedBytes'] as num?)?.toInt() ?? lastDownloadedBytes;
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
    } else if (p['cycleState'] is String) {
      cycle = CycleState.fromName(p['cycleState'] as String);
    }
    cycle ??= deriveCycleState(sm, cancelToken.isCancelled, isTorrent);

    // Fix 2: Dynamic YouTube counterpart size & downloaded resolution
    final dynamicYtCounterpartSize =
        (p['ytCounterpartSize'] as num?)?.toInt() ?? ytCounterpartSize;
    final dynamicYtCounterpartDownloaded = ytCounterpartDownloadedOverride ??
        (p['ytCounterpartDownloadedBytes'] as num?)?.toInt() ??
        ytCounterpartDownloadedBytes;

    if (isCounterpartUnregistered && ytStreamKind != null && cycle == CycleState.downloading) {
      final cpSize = dynamicYtCounterpartSize;
      final cpDone = cpSize != null && cpSize > 0 && 
                     (dynamicYtCounterpartDownloaded ?? 0) >= cpSize;
      if (cpDone) {
        cycle = CycleState.merging;
        sm = 'Merging audio + video…';
      } else {
        cycle = CycleState.starting;
        sm = 'Waiting for counterpart stream…';
      }
    }

    // YT Combined Sync Check
    if (cycle == CycleState.completed && ytStreamKind != null && ytStreamKind != YtStreamKind.combined) {
      final cpSize = dynamicYtCounterpartSize;
      final cpLive = dynamicYtCounterpartDownloaded ?? 0;
      
      final bool counterpartResolved = cpSize != null && cpSize > 0;
      final bool counterpartDone = counterpartResolved && cpLive >= cpSize;
      final bool selfDone = lastFileSize > 0 && lastDownloadedBytes >= lastFileSize;

      if (!counterpartResolved || !counterpartDone || !selfDone) {
        cycle = CycleState.downloading;
      }
    }

    final chunkList = chunkDetails;
    final totalParts = chunkList?.length ?? 0;
    final isDone = cycle == CycleState.completed;
    final doneParts = chunkList == null
        ? 0
        : (isDone ? totalParts : chunkList.where((c) => c.isComplete).length);

    lastChunkDetails = chunkDetails ?? lastChunkDetails;
    lastTotalChunks = (isTorrent || chunkDetails == null) ? lastTotalChunks : totalParts;
    lastCompletedChunks = (isTorrent || chunkDetails == null) ? lastCompletedChunks : doneParts;

    final rawPauseReason = p['pauseReason'];
    final PauseReason? pauseReason = rawPauseReason is PauseReason
        ? rawPauseReason
        : (rawPauseReason is String ? PauseReason.fromName(rawPauseReason) : null);

    final progress = DownloadProgress(
      downloadedBytes: lastDownloadedBytes,
      fileSize: lastFileSize,
      speed: (p['speed'] as num?)?.toDouble() ?? 0.0,
      eta: (p['eta'] as num?)?.toInt(),
      chunks: p['chunks'] != null ? List<double>.from(p['chunks'] as List) : null,
      fileName: p['fileName'] as String? ?? resolvedFileName,
      supportsResume: p['supportsResume'] as bool? ?? resolvedSupportsResume,
      statusMessage: sm,
      ytStreamKind: ytStreamKind,
      ytCounterpartSize: dynamicYtCounterpartSize,
      ytDownloadedBytes: (p['ytDownloadedBytes'] as num?)?.toInt() ?? (ytStreamKind != null ? lastDownloadedBytes : null),
      ytCounterpartDownloadedBytes: dynamicYtCounterpartDownloaded,
      chunkDetails: lastChunkDetails,
      cycleState: cycle,
      pauseReason: pauseReason,
      totalChunks: (isTorrent || lastChunkDetails == null) ? null : lastTotalChunks,
      completedChunks: (isTorrent || lastChunkDetails == null) ? null : lastCompletedChunks,
      torrentFiles: lastTorrentFiles,
      totalFiles: lastTotalFiles,
      completedFiles: lastCompletedFiles,
      totalFileBytes: lastTotalFileBytes,
      downloadedFileBytes: lastDownloadedFileBytes,
      torrentId: torrentId,
    );

    final intervalMs = getEffectiveIntervalMs();
    final now = DateTime.now();
    final bool canEmitNow = lastProgressEmitTime == null ||
        now.difference(lastProgressEmitTime!) >= Duration(milliseconds: intervalMs);
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
        _throttleTimer = Timer(Duration(milliseconds: remainingMs.clamp(1, intervalMs)), () {
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
    lastTorrentFiles = pTorrentFiles.whereType<Map>().map((m) {
      final map = Map<String, dynamic>.from(m);
      final length = (map['length'] as num?)?.toInt() ?? 0;
      final dlRaw = (map['downloadedBytes'] as num?)?.toInt() ?? 0;
      final dl = length > 0 ? dlRaw.clamp(0, length) : 0;
      final progress = length > 0 ? (dl / length).clamp(0.0, 1.0) : 1.0;
      map['downloadedBytes'] = dl;
      map['progress'] = progress;
      map['isComplete'] = length == 0 || dl >= length;
      return map;
    }).toList();

    final selected = lastTorrentFiles!.where((f) => (f['selected'] as bool?) ?? true).toList();
    lastTotalFiles = selected.length;
    lastTotalFileBytes = selected.fold<int>(0, (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0));
    lastDownloadedFileBytes = selected.fold<int>(0, (sum, f) {
      final len = (f['length'] as num?)?.toInt() ?? 0;
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      return sum + (len > 0 ? dl.clamp(0, len) : 0);
    });
    lastCompletedFiles = selected.where((f) {
      final length = (f['length'] as num?)?.toInt() ?? 0;
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      return length == 0 || dl >= length;
    }).length;
  }
}
