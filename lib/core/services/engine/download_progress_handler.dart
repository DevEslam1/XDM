import 'dart:async';
import 'package:dio/dio.dart';
import 'package:synchronized/synchronized.dart';
import '../engines/http_download_engine.dart';
import 'engine_models.dart';

// FIX: P0-01 — DownloadProgressHandler encapsulates all progress state with synchronized lock

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
  final List<Map<String, dynamic>>? Function()? getTorrentFiles;
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
    required this.getTorrentFiles,
    required this.torrentId,
    required this.getEffectiveIntervalMs,
    required this.lastDownloadedBytes,
    required this.lastFileSize,
    this.lastChunkDetails,
    this.lastTotalChunks,
    this.lastCompletedChunks,
  }) {
    if (isTorrent) {
      lastTorrentFiles = getTorrentFiles?.call();
    }
  }

  void emit(DownloadProgress progress) {
    if (cancelToken.isCancelled) return;
    onProgress(progress);
  }

  static String deriveCycleState(
    String? statusMessage,
    bool isCancelled,
    bool isTorrent,
  ) {
    if (isCancelled) return 'cancelled';
    final sm = statusMessage?.toLowerCase() ?? '';
    if (sm.contains('completed') || sm.contains('done')) return 'completed';
    if (sm.contains('merg') || sm.contains('mux')) return 'merging';
    if (sm.contains('verif') || sm.contains('check')) return 'verifying';
    if (sm.contains('allocat')) return 'allocating';
    if (sm.contains('paus') || sm.contains('stop')) return 'paused';
    if (sm.contains('seed')) return 'seeding';
    if (sm.contains('error') || sm.contains('fail')) return 'failed';
    return 'downloading';
  }

  Future<void> handleProgress(
    Map<String, dynamic> p, {
    required Map<String, String> ytCounterpartTaskIds,
    Map<String, int>? ytLiveBytes,
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
      List<ChunkDetail>? chunkDetails;
      if (p['chunkDetails'] is List) {
        chunkDetails = (p['chunkDetails'] as List)
            .whereType<Map<String, dynamic>>()
            .map((c) {
          final rawSize = (c['size'] as num?)?.toInt() ?? -1;
          final rawRatio = (c['ratio'] as num?)?.toDouble() ?? 0.0;
          final safeRatio =
              (rawRatio.isNaN || rawRatio.isInfinite || rawRatio < 0.0)
                  ? 0.0
                  : rawRatio.clamp(0.0, 1.0);
          return ChunkDetail(
            index: (c['index'] as num?)?.toInt() ?? 0,
            start: (c['start'] as num?)?.toInt() ?? 0,
            end: (c['end'] as num?)?.toInt() ?? -1,
            downloaded: (c['downloaded'] as num?)?.toInt() ?? 0,
            size: rawSize,
            ratio: safeRatio,
          );
        }).toList();
      }
      final ytLive = (p['ytDownloadedBytes'] as num?)?.toInt();
      final ytEffectiveLive = ytLive ??
          (ytStreamKind != null
              ? (p['downloadedBytes'] as num?)?.toInt()
              : null);
      if (ytEffectiveLive != null && ytLiveBytes != null) {
        ytLiveBytes[taskId] = ytEffectiveLive;
      }
      final counterpartId = ytCounterpartTaskIds[taskId];
      int? liveCounterpart = counterpartId != null && ytLiveBytes != null
          ? ytLiveBytes[counterpartId]
          : null;
      if (liveCounterpart == null && counterpartId != null) {
        liveCounterpart = ytCounterpartDownloadedBytes ?? 0;
      }
      lastDownloadedBytes =
          (p['downloadedBytes'] as num?)?.toInt() ?? lastDownloadedBytes;
      final ytCounterpart = (p['ytCounterpartDownloadedBytes'] as num?)?.toInt();
      if (ytCounterpart != null) {
        liveCounterpart = ytCounterpart;
      }
      lastFileSize = (p['fileSize'] as num?)?.toInt() ?? lastFileSize;
      final pTorrentFiles = p['torrentFiles'];
      if (pTorrentFiles is List && pTorrentFiles.isNotEmpty) {
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
        final selected = lastTorrentFiles!
            .where((f) => (f['selected'] as bool?) ?? true)
            .toList();
        lastTotalFiles = selected.length;
        lastTotalFileBytes = selected.fold<int>(
          0,
          (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0),
        );
        lastDownloadedFileBytes = selected.fold<int>(
          0,
          (sum, f) {
            final len = (f['length'] as num?)?.toInt() ?? 0;
            final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
            return sum + (len > 0 ? dl.clamp(0, len) : 0);
          },
        );
        lastCompletedFiles = selected.where((f) {
          final length = (f['length'] as num?)?.toInt() ?? 0;
          final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
          return length == 0 || dl >= length;
        }).length;
      }
      final sm = p['statusMessage'] as String?;
      var cycle = deriveCycleState(
        sm,
        cancelToken.isCancelled,
        isTorrent,
      );
      if (cycle == 'completed' &&
          ytStreamKind != null &&
          ytStreamKind != YtStreamKind.combined) {
        final cpId = ytCounterpartTaskIds[taskId];
        final cpLive =
            cpId != null && ytLiveBytes != null ? ytLiveBytes[cpId] : null;
        final cpSize =
            (p['ytCounterpartSize'] as num?)?.toInt() ?? ytCounterpartSize;
        final bool counterpartResolved = cpSize != null && cpSize > 0;
        final bool counterpartDone = counterpartResolved &&
            cpLive != null &&
            cpLive >= cpSize;
        final bool selfDone = lastFileSize > 0 &&
            lastDownloadedBytes >= lastFileSize;

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
      lastTotalChunks =
          (isTorrent || chunkDetails == null) ? lastTotalChunks : totalParts;
      lastCompletedChunks =
          (isTorrent || chunkDetails == null) ? lastCompletedChunks : doneParts;
      final nowEmit = DateTime.now();
      final shouldEmit = lastProgressEmitTime == null ||
          nowEmit.difference(lastProgressEmitTime!) >=
              Duration(milliseconds: getEffectiveIntervalMs());
      if (shouldEmit) {
        lastProgressEmitTime = nowEmit;
        if (!cancelToken.isCancelled) {
          onProgress(DownloadProgress(
            downloadedBytes: lastDownloadedBytes,
            fileSize: lastFileSize,
            speed: (p['speed'] as num?)?.toDouble() ?? 0.0,
            eta: (p['eta'] as num?)?.toInt(),
            chunks: p['chunks'] != null
                ? List<double>.from(p['chunks'] as List)
                : null,
            fileName: p['fileName'] as String?,
            supportsResume: p['supportsResume'] as bool?,
            statusMessage: sm,
            ytStreamKind: p['ytStreamKind'] != null
                ? YtStreamKind.values.firstWhere(
                    (k) => k.name == p['ytStreamKind'],
                    orElse: () => YtStreamKind.combined,
                  )
                : null,
            ytCounterpartSize: (p['ytCounterpartSize'] as num?)?.toInt(),
            ytDownloadedBytes: ytEffectiveLive,
            ytCounterpartDownloadedBytes: liveCounterpart ??
                (p['ytCounterpartDownloadedBytes'] as num?)?.toInt(),
            chunkDetails: chunkDetails,
            cycleState: cycle,
            totalChunks:
                (isTorrent || chunkDetails == null) ? null : totalParts,
            completedChunks:
                (isTorrent || chunkDetails == null) ? null : doneParts,
            totalFiles: lastTotalFiles,
            completedFiles: lastCompletedFiles,
            totalFileBytes: lastTotalFileBytes,
            downloadedFileBytes: lastDownloadedFileBytes,
            torrentFiles: lastTorrentFiles,
            torrentId: torrentId,
          ));
        }
      }
    });
  }
}
