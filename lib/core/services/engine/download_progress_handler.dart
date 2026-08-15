import 'dart:async';
import 'package:dio/dio.dart';
import 'package:synchronized/synchronized.dart';
import '../engines/http_download_engine.dart';
import 'engine_models.dart';
import 'engine_utils.dart';

/// Encapsulates progress state management and throttling for download tasks.
/// Task 1.2: Decoupled progress handling.
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
  final Lock _lock = Lock();

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
    onProgress(progress);
  }

  static String deriveCycleState(
    String? statusMessage,
    bool isCancelled,
    bool isTorrent,
  ) {
    if (isCancelled) return 'paused';
    final sm = statusMessage?.toLowerCase() ?? '';
    if (sm.contains('completed') || sm.contains('done')) return 'completed';
    if (sm.contains('merg') || sm.contains('mux')) return 'merging';
    if (sm.contains('verif') || sm.contains('check')) return 'verifying';
    if (sm.contains('allocat')) return 'allocating';
    if (sm.contains('paus') || sm.contains('stop')) return 'paused';
    if (sm.contains('seed')) return 'seeding';
    if (sm.contains('error') || sm.contains('fail')) return 'failed';
    if (sm.contains('updating') || sm.contains('refresh')) return 'updating_links';
    if (sm.contains('retry')) return 'retrying';
    if (sm.contains('resum')) return 'resuming';
    if (sm.contains('starting') || sm.contains('prepar')) return 'starting';
    return 'downloading';
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
    if (override == null && ytLiveBytes != null && ytCounterpartTaskIds != null) {
      final cpId = ytCounterpartTaskIds[taskId];
      if (cpId != null) {
        override = ytLiveBytes[cpId];
      }
    }
    return handleWorkerProgress(
      p,
      ytCounterpartDownloadedOverride: override,
      adaptiveThreads: adaptiveThreads,
      effectiveThreadCount: effectiveThreadCount,
      httpEngine: httpEngine,
    );
  }

  Future<void> handleWorkerProgress(
    Map<String, dynamic> p, {
    int? ytCounterpartDownloadedOverride,
    bool adaptiveThreads = false,
    int effectiveThreadCount = 1,
    HttpDownloadEngine? httpEngine,
  }) async {
    if (cancelToken.isCancelled) return;

    await _lock.synchronized(() {
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

      final sm = p['statusMessage'] as String?;
      var cycle = deriveCycleState(sm, cancelToken.isCancelled, isTorrent);

      // YT Combined Sync Check
      if (cycle == 'completed' && ytStreamKind != null && ytStreamKind != YtStreamKind.combined) {
        final cpSize = (p['ytCounterpartSize'] as num?)?.toInt() ?? ytCounterpartSize;
        final cpLive = ytCounterpartDownloadedOverride ?? ytCounterpartDownloadedBytes ?? 0;
        
        final bool counterpartResolved = cpSize != null && cpSize > 0;
        final bool counterpartDone = counterpartResolved && cpLive >= cpSize;
        final bool selfDone = lastFileSize > 0 && lastDownloadedBytes >= lastFileSize;

        if (!counterpartResolved || !counterpartDone || !selfDone) {
          cycle = 'downloading';
        }
      }

      final chunkList = chunkDetails;
      final totalParts = chunkList?.length ?? 0;
      final isDone = cycle == 'completed';
      final doneParts = chunkList == null
          ? 0
          : (isDone ? totalParts : chunkList.where((c) => c.isComplete).length);

      lastChunkDetails = chunkDetails ?? lastChunkDetails;
      lastTotalChunks = (isTorrent || chunkDetails == null) ? lastTotalChunks : totalParts;
      lastCompletedChunks = (isTorrent || chunkDetails == null) ? lastCompletedChunks : doneParts;

      final nowEmit = DateTime.now();
      final shouldEmit = lastProgressEmitTime == null ||
          nowEmit.difference(lastProgressEmitTime!) >=
              Duration(milliseconds: getEffectiveIntervalMs());

      if (shouldEmit) {
        lastProgressEmitTime = nowEmit;
        onProgress(DownloadProgress(
          downloadedBytes: lastDownloadedBytes,
          fileSize: lastFileSize,
          speed: (p['speed'] as num?)?.toDouble() ?? 0.0,
          eta: (p['eta'] as num?)?.toInt(),
          chunks: p['chunks'] != null ? List<double>.from(p['chunks'] as List) : null,
          fileName: p['fileName'] as String? ?? resolvedFileName,
          supportsResume: p['supportsResume'] as bool? ?? resolvedSupportsResume,
          statusMessage: sm,
          ytStreamKind: ytStreamKind,
          ytCounterpartSize: (p['ytCounterpartSize'] as num?)?.toInt() ?? ytCounterpartSize,
          ytDownloadedBytes: (p['ytDownloadedBytes'] as num?)?.toInt() ?? (ytStreamKind != null ? lastDownloadedBytes : null),
          ytCounterpartDownloadedBytes: ytCounterpartDownloadedOverride ?? (p['ytCounterpartDownloadedBytes'] as num?)?.toInt() ?? ytCounterpartDownloadedBytes,
          chunkDetails: lastChunkDetails,
          cycleState: cycle,
          totalChunks: (isTorrent || lastChunkDetails == null) ? null : lastTotalChunks,
          completedChunks: (isTorrent || lastChunkDetails == null) ? null : lastCompletedChunks,
          torrentFiles: lastTorrentFiles,
          totalFiles: lastTotalFiles,
          completedFiles: lastCompletedFiles,
          totalFileBytes: lastTotalFileBytes,
          downloadedFileBytes: lastDownloadedFileBytes,
          torrentId: torrentId,
        ));
      }
    });
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
      map['percent'] = progress;
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
