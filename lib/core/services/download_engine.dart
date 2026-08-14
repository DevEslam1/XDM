import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dmx/core/services/connection_manager.dart';
import 'package:synchronized/synchronized.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/mirror_failover.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/retry_interceptor.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'engines/http_download_engine.dart';
import '../utils/bencode_decoder.dart';
import '../utils/file_utils.dart';
import '../utils/url_utils.dart';
part 'download_isolate_pool.dart';

class DownloadMetadata {
  final String fileName;
  final String category;
  final int fileSize;
  final bool supportsResume;
  final List<Map<String, dynamic>>? torrentFiles;
  final int? torrentId;
  final String? etag;
  final String? lastModified;
  bool get isValid => fileName.isNotEmpty || fileSize > 0;

  const DownloadMetadata({
    required this.fileName,
    required this.category,
    required this.fileSize,
    required this.supportsResume,
    this.torrentFiles,
    this.torrentId,
    this.etag,
    this.lastModified,
  });
}

class IsolateSpawnTimeoutException implements Exception {
  final String message;
  const IsolateSpawnTimeoutException([
    this.message = 'Download engine failed to initialize. Please retry.',
  ]);
  @override
  String toString() => 'IsolateSpawnTimeoutException: $message';
}

class InsufficientStorageException implements Exception {
  final String message;
  const InsufficientStorageException([
    this.message =
        'Not enough storage space to download this file. Please free up space and try again.',
  ]);
  @override
  String toString() => 'InsufficientStorageException: $message';
}

class InvalidPathException implements Exception {
  final String message;
  const InvalidPathException(this.message);
  @override
  String toString() => 'InvalidPathException: $message';
}

class DownloadIntegrityException implements Exception {
  final String message;
  const DownloadIntegrityException(this.message);
  @override
  String toString() => 'DownloadIntegrityException: $message';
}

class UrlExpiredException implements Exception {
  final String message;
  final bool refreshAllMirrors;
  const UrlExpiredException(this.message, {this.refreshAllMirrors = false});
  @override
  String toString() => 'UrlExpiredException: $message';
}

class TorrentEnginePauseException implements Exception {
  final String message;
  final String url;
  const TorrentEnginePauseException(this.message, {required this.url});
  @override
  String toString() => 'TorrentEnginePauseException: $message';
}

enum MergeFailureKind {
  missingBinary,
  formatMismatch,
  diskFull,
  processCrash,
  incompleteInput,
  unknown,
}

MergeFailureKind classifyMergeFailure(Object error) {
  final msg = error.toString().toLowerCase();
  if (msg.contains('no such file') ||
      msg.contains('ffmpeg_kit') && msg.contains('not initialized') ||
      msg.contains('binary') && msg.contains('missing')) {
    return MergeFailureKind.missingBinary;
  }
  if (msg.contains('no space left') ||
      msg.contains('enospc') ||
      msg.contains('disk full')) {
    return MergeFailureKind.diskFull;
  }
  if (msg.contains('invalid data') ||
      msg.contains('does not contain any stream') ||
      msg.contains('could not open') ||
      msg.contains('invalid argument')) {
    return MergeFailureKind.formatMismatch;
  }
  if (msg.contains('incomplete') || msg.contains('truncated')) {
    return MergeFailureKind.incompleteInput;
  }
  if (msg.contains('crash') ||
      msg.contains('signal') ||
      msg.contains('exit code')) {
    return MergeFailureKind.processCrash;
  }
  return MergeFailureKind.unknown;
}

enum YtStreamKind { video, audio, combined }

class ChunkDetail {
  final int index;
  final int start;
  final int end;
  final int downloaded;
  final int size;
  final double ratio;
  bool get isIndeterminate => size < 0;
  bool get isComplete => size >= 0 && downloaded >= size;
  String get percentLabel {
    if (isIndeterminate) return '—';
    if (size == 0) return '100%';
    return '${(ratio * 100).toStringAsFixed(0)}%';
  }

  const ChunkDetail({
    required this.index,
    required this.start,
    required this.end,
    required this.downloaded,
    required this.size,
    required this.ratio,
  });
  factory ChunkDetail.fromMap(Map<String, dynamic> m) {
    final rawRatio = (m['ratio'] as num?)?.toDouble() ?? 0.0;
    return ChunkDetail(
      index: (m['index'] as num?)?.toInt() ?? 0,
      start: (m['start'] as num?)?.toInt() ?? 0,
      end: (m['end'] as num?)?.toInt() ?? -1,
      downloaded: (m['downloaded'] as num?)?.toInt() ?? 0,
      size: (m['size'] as num?)?.toInt() ?? -1,
      ratio: (rawRatio.isNaN || rawRatio.isInfinite || rawRatio < 0.0)
          ? 0.0
          : rawRatio.clamp(0.0, 1.0),
    );
  }
}

class DownloadProgress {
  final int downloadedBytes;
  final int fileSize;
  final double speed;
  final int? eta;
  final List<double>? chunks;
  final String? fileName;
  final List<Map<String, dynamic>>? torrentFiles;
  final bool? supportsResume;
  final String? statusMessage;
  final int? torrentId;
  final List<ChunkDetail>? chunkDetails;
  final String? cycleState;
  final int? totalChunks;
  final int? completedChunks;
  final int? totalFiles;
  final int? completedFiles;
  final int? totalFileBytes;
  final int? downloadedFileBytes;
  final YtStreamKind? ytStreamKind;
  final int? ytCounterpartSize;
  final int? ytCounterpartDownloadedBytes;
  final int? ytDownloadedBytes;
  DownloadProgress({
    required this.downloadedBytes,
    required this.fileSize,
    required this.speed,
    required this.eta,
    this.chunks,
    this.fileName,
    this.torrentFiles,
    this.supportsResume,
    this.statusMessage,
    this.torrentId,
    this.ytStreamKind,
    this.ytCounterpartSize,
    this.ytCounterpartDownloadedBytes,
    this.ytDownloadedBytes,
    this.chunkDetails,
    this.cycleState,
    this.totalChunks,
    this.completedChunks,
    this.totalFiles,
    this.completedFiles,
    this.totalFileBytes,
    this.downloadedFileBytes,
  });
  factory DownloadProgress.fromWorkerMap(Map<String, dynamic> data) {
    final chunkDetailsRaw = data['chunkDetails'];
    List<ChunkDetail>? chunkDetails;
    if (chunkDetailsRaw is List) {
      chunkDetails = chunkDetailsRaw.whereType<Map>().map((m) {
        final rawRatio = (m['ratio'] as num?)?.toDouble() ?? 0.0;
        return ChunkDetail(
          index: (m['index'] as num?)?.toInt() ?? 0,
          start: (m['start'] as num?)?.toInt() ?? 0,
          end: (m['end'] as num?)?.toInt() ?? -1,
          downloaded: (m['downloaded'] as num?)?.toInt() ?? 0,
          size: (m['size'] as num?)?.toInt() ?? -1,
          ratio: (rawRatio.isNaN || rawRatio.isInfinite || rawRatio < 0.0)
              ? 0.0
              : rawRatio.clamp(0.0, 1.0),
        );
      }).toList();
    }
    final ytKindName = data['ytStreamKind'] as String?;
    final ytStreamKind = ytKindName != null
        ? YtStreamKind.values.firstWhere(
            (k) => k.name == ytKindName,
            orElse: () => YtStreamKind.combined,
          )
        : null;
    final torrentFilesRaw = data['torrentFiles'];
    List<Map<String, dynamic>>? torrentFiles;
    if (torrentFilesRaw is List) {
      torrentFiles = torrentFilesRaw.whereType<Map>().map((m) {
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
    }
    int? totalFiles = (data['totalFiles'] as num?)?.toInt();
    int? completedFiles = (data['completedFiles'] as num?)?.toInt();
    int? totalFileBytes = (data['totalFileBytes'] as num?)?.toInt();
    int? downloadedFileBytes = (data['downloadedFileBytes'] as num?)?.toInt();
    if (torrentFiles != null && torrentFiles.isNotEmpty) {
      final selectedFiles = torrentFiles.where((f) {
        return (f['selected'] as bool?) ?? true;
      }).toList();
      totalFiles ??= selectedFiles.length;
      totalFileBytes ??= selectedFiles.fold<int>(
        0,
        (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0),
      );
      downloadedFileBytes ??= selectedFiles.fold<int>(
        0,
        (sum, f) {
          final len = (f['length'] as num?)?.toInt() ?? 0;
          final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
          return sum + (len > 0 ? dl.clamp(0, len) : 0);
        },
      );
      completedFiles ??= selectedFiles.where((f) {
        final length = (f['length'] as num?)?.toInt() ?? 0;
        final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        return length == 0 || dl >= length;
      }).length;
    }
    return DownloadProgress(
      downloadedBytes: (data['downloadedBytes'] as num?)?.toInt() ?? 0,
      fileSize: (data['fileSize'] as num?)?.toInt() ?? 0,
      speed: (data['speed'] as num?)?.toDouble() ?? 0.0,
      eta: (data['eta'] as num?)?.toInt(),
      chunks: (data['chunks'] as List?)
          ?.map((e) => (e as num?)?.toDouble() ?? 0.0)
          .toList(),
      fileName: data['fileName'] as String?,
      torrentFiles: torrentFiles,
      supportsResume: data['supportsResume'] as bool?,
      statusMessage: data['statusMessage'] as String?,
      cycleState: data['cycleState'] as String?,
      torrentId: (data['torrentId'] as num?)?.toInt(),
      chunkDetails: chunkDetails,
      totalChunks: (data['totalChunks'] as num?)?.toInt(),
      completedChunks: (data['completedChunks'] as num?)?.toInt(),
      totalFiles: totalFiles,
      completedFiles: completedFiles,
      totalFileBytes: totalFileBytes,
      downloadedFileBytes: downloadedFileBytes,
      ytStreamKind: ytStreamKind,
      ytCounterpartSize: (data['ytCounterpartSize'] as num?)?.toInt(),
      ytCounterpartDownloadedBytes:
          (data['ytCounterpartDownloadedBytes'] as num?)?.toInt(),
      ytDownloadedBytes: (data['ytDownloadedBytes'] as num?)?.toInt() ??
          (ytStreamKind != null
              ? (data['downloadedBytes'] as num?)?.toInt()
              : null),
    );
  }
  double? get ytCombinedProgress {
    if (ytStreamKind == null) return null;
    if (ytCounterpartSize == null) {
      if (fileSize <= 0) return null;
      final selfBytes = ytDownloadedBytes ?? downloadedBytes;
      return (selfBytes / fileSize).clamp(0.0, 1.0);
    }
    final counterpartSize = ytCounterpartSize!;
    final counterpartDownloaded = ytCounterpartDownloadedBytes ?? 0;
    final selfDownloaded = ytDownloadedBytes ?? downloadedBytes;
    if (counterpartSize > 0 && counterpartDownloaded == 0) {
      if (fileSize <= 0) {
        return null;
      }
      final totalSize = fileSize + counterpartSize;
      if (totalSize == 0) return null;
      return (selfDownloaded / totalSize).clamp(0.0, 1.0);
    }
    final totalSize = fileSize + counterpartSize;
    if (totalSize == 0) return null;
    final totalDownloaded = selfDownloaded + counterpartDownloaded;
    return (totalDownloaded / totalSize).clamp(0.0, 1.0);
  }

  int get ytCombinedDownloadedBytes {
    if (ytStreamKind == null) return downloadedBytes;
    final selfBytes = ytDownloadedBytes ?? downloadedBytes;
    return selfBytes + (ytCounterpartDownloadedBytes ?? 0);
  }

  int get ytCombinedFileSize {
    if (ytStreamKind == null) return fileSize;
    return fileSize + (ytCounterpartSize ?? 0);
  }

  ({
    int totalFiles,
    int completedFiles,
    int totalFileBytes,
    int downloadedFileBytes
  }) get torrentFileAggregates {
    if (torrentFiles == null || torrentFiles!.isEmpty) {
      return (
        totalFiles: totalFiles ?? 0,
        completedFiles: completedFiles ?? 0,
        totalFileBytes: totalFileBytes ?? 0,
        downloadedFileBytes: downloadedFileBytes ?? 0,
      );
    }
    int total = 0;
    int completed = 0;
    int totalBytes = 0;
    int downloaded = 0;
    for (final f in torrentFiles!) {
      final selected = f['selected'] as bool? ?? true;
      if (!selected) continue;
      final length = (f['length'] as num?)?.toInt() ?? 0;
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final clampedDl = length > 0 ? dl.clamp(0, length) : 0;
      total++;
      totalBytes += length;
      downloaded += clampedDl;
      if (length == 0 || clampedDl >= length) {
        completed++;
      }
    }
    return (
      totalFiles: total,
      completedFiles: completed,
      totalFileBytes: totalBytes,
      downloadedFileBytes: downloaded,
    );
  }

  double get torrentOverallPercent {
    if (totalFileBytes != null && totalFileBytes! > 0) {
      final dl = downloadedFileBytes ?? 0;
      return (dl / totalFileBytes!).clamp(0.0, 1.0);
    }
    final agg = torrentFileAggregates;
    if (agg.totalFileBytes > 0) {
      return (agg.downloadedFileBytes / agg.totalFileBytes).clamp(0.0, 1.0);
    }
    if (fileSize > 0) {
      return (downloadedBytes / fileSize).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  List<Map<String, dynamic>>? get torrentFilePercents {
    if (torrentFiles == null || torrentFiles!.isEmpty) return null;
    final overall = torrentOverallPercent;
    return torrentFiles!.map((f) {
      final length = (f['length'] as num?)?.toInt() ?? 0;
      final dlRaw = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final dl = length > 0 ? dlRaw.clamp(0, length) : 0;
      final progress = length > 0 ? (dl / length).clamp(0.0, 1.0) : 1.0;
      final fileSpeed = (f['speed'] as num?)?.toDouble() ?? 0.0;
      return <String, dynamic>{
        'name': f['name'] ?? '',
        'length': length,
        'downloadedBytes': dl,
        'progress': progress,
        'percent': progress,
        'isComplete': length == 0 || dl >= length,
        'selected': f['selected'] as bool? ?? true,
        'priority': (f['priority'] as num?)?.toInt() ?? 4,
        'speed': fileSpeed < 0 ? 0.0 : fileSpeed,
        'progressEstimated':
            (f['progressEstimated'] as bool?) ?? (length > 0 && dl <= 0),
        'overallPercent': overall,
      };
    }).toList();
  }
}

typedef ValueChangedProgress = void Function(DownloadProgress progress);

class TimestampedEntry<V> {
  TimestampedEntry(this.value, [DateTime? time])
      : lastAccessed = time ?? DateTime.now();
  final V value;
  DateTime lastAccessed;
}

class TimestampedLruMap<K, V> {
  TimestampedLruMap({this.maxCapacity = 100});
  final int maxCapacity;
  final LinkedHashMap<K, TimestampedEntry<V>> _map = LinkedHashMap();

  int get length => _map.length;

  V? get(K key) {
    final entry = _map.remove(key);
    if (entry == null) return null;
    entry.lastAccessed = DateTime.now();
    _map[key] = entry;
    return entry.value;
  }

  void put(K key, V value) {
    _map.remove(key);
    if (_map.length >= maxCapacity) {
      _map.remove(_map.keys.first);
    }
    _map[key] = TimestampedEntry(value);
  }

  V? operator [](K key) => get(key);
  void operator []=(K key, V value) => put(key, value);

  V putIfAbsent(K key, V Function() ifAbsent) {
    final existing = get(key);
    if (existing != null) return existing;
    final val = ifAbsent();
    put(key, val);
    return val;
  }

  V? remove(K key) {
    final entry = _map.remove(key);
    return entry?.value;
  }

  bool containsKey(K key) => _map.containsKey(key);

  void clear() => _map.clear();

  int removeStale(Duration threshold) {
    final now = DateTime.now();
    final toRemove = <K>[];
    _map.forEach((key, entry) {
      if (now.difference(entry.lastAccessed) > threshold) {
        toRemove.add(key);
      }
    });
    for (final k in toRemove) {
      _map.remove(k);
    }
    return toRemove.length;
  }

  List<K> get keys => _map.keys.toList();
}

// FIX-P3: DownloadProgressHandler encapsulates all progress state with synchronized lock
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

  Future<void> handleProgress(
    Map<String, dynamic> p, {
    required TimestampedLruMap<String, String> ytCounterpartTaskIds,
    TimestampedLruMap<String, int>? ytLiveBytes,
    bool adaptiveThreads = false,
    int effectiveThreadCount = 1,
    HttpDownloadEngine? httpEngine,
  }) async {
    // FIX-P3: Check cancelToken.isCancelled at TOP before processing
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
      // FIX-C5: Sync ytCounterpartDownloadedBytes from isolate progress payload in real-time
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
      var cycle = DownloadEngine._deriveCycleState(
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
        final cpSize = ytCounterpartSize;
        if (cpSize == null || cpSize <= 0) {
          cycle = 'downloading';
        } else if (cpLive == null || cpLive < cpSize) {
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
            torrentFiles: lastTorrentFiles,
            totalFiles: lastTotalFiles,
            completedFiles: lastCompletedFiles,
            totalFileBytes: lastTotalFileBytes,
            downloadedFileBytes: lastDownloadedFileBytes,
          ));
        }
      }
    });
  }
}

class DownloadEngine {
  static Future<void> validateSavePath(
    String savePath, {
    int requiredSizeBytes = 0,
    List<String>? allowedStorageRoots,
  }) async {
    if (savePath.contains('..')) {
      throw const InvalidPathException(
          'Path traversal attempt detected in save path');
    }

    final normalized = p.normalize(savePath);

    if (RegExp(r'[\*\?<>\|"\x00]').hasMatch(savePath)) {
      throw const InvalidPathException('Save path contains invalid characters');
    }

    final isWindows = Platform.isWindows;
    if (isWindows) {
      if (normalized.startsWith(r'\\')) {
        throw const InvalidPathException(
            'UNC network paths are not permitted as save directories');
      }
      final winReserved = RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
          caseSensitive: false);
      for (final segment in p.split(normalized)) {
        if (winReserved.hasMatch(segment)) {
          throw InvalidPathException(
              'Save path contains a reserved Windows device name: $segment');
        }
      }
    }

    final dir = Directory(normalized);
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (e) {
      throw InvalidPathException('Cannot create save directory: $e');
    }

    final randSuffix = Random().nextInt(100000);
    final testFile = File(p.join(dir.path, '.dmx_write_test_$randSuffix'));
    try {
      await testFile.writeAsString('test');
      if (await testFile.exists()) {
        await testFile.delete();
      }
    } catch (e) {
      throw InvalidPathException('Save directory is not writable: $e');
    }

    if (allowedStorageRoots != null && allowedStorageRoots.isNotEmpty) {
      final isAllowed = allowedStorageRoots.any((root) {
        final normRoot = p.normalize(root);
        return p.equals(normalized, normRoot) ||
            p.isWithin(normRoot, normalized);
      });
      if (!isAllowed) {
        throw const InvalidPathException(
            'Save path is outside allowed storage locations');
      }
    }

    if (requiredSizeBytes > 0) {
      try {
        final stat = await dir.stat();
        if (stat.type == FileSystemEntityType.notFound) {
          throw const InsufficientStorageException(
              'Target save directory stat failed');
        }
      } catch (e) {
        if (e is InsufficientStorageException) rethrow;
      }
    }
  }

  static bool appInForeground = true;
  static bool get isInBackground => !appInForeground;
  static set isInBackground(bool val) => appInForeground = !val;
  static const int _progressReportIntervalMs = 500;
  static const int _isolatePoolSize = 4;
  static const int _lowSpaceThresholdBytes = 500 * 1024 * 1024;
  int get effectiveProgressReportIntervalMs {
    if (PowerMonitor.screenOff) return 5000;
    if (!appInForeground) return 2000;
    if (PowerMonitor.throttleFactor < 1.0) return 1000;
    return _progressReportIntervalMs;
  }

  // FIX-P3: Map<String, CancelToken> instead of List<CancelToken>
  final Map<String, CancelToken> _activeCancelTokens = {};
  DownloadIsolatePool? _pool;
  Future<DownloadIsolatePool>? _poolInit;
  final _httpEngine = HttpDownloadEngine();
  final Set<int> _activeTorrentIds = <int>{};
  final Dio _sharedDio;
  final TimestampedLruMap<String, String> _ytCounterpartTaskIds =
      TimestampedLruMap<String, String>(maxCapacity: 100);
  final TimestampedLruMap<String, int> _ytLiveBytes =
      TimestampedLruMap<String, int>(maxCapacity: 100);
  final TimestampedLruMap<String, bool> _ytFinishedStreams =
      TimestampedLruMap<String, bool>(maxCapacity: 100);

  void registerYtCounterpart(String taskId, String counterpartTaskId) {
    _ytCounterpartTaskIds.put(taskId, counterpartTaskId);
    _ytCounterpartTaskIds.put(counterpartTaskId, taskId);
  }

  final Set<Timer> _ytCleanupTimers = {};
  Timer? _ytPeriodicTimer;

  void unregisterYtCounterpart(String taskId) {
    _ytFinishedStreams.put(taskId, true);
    final c = _ytCounterpartTaskIds.get(taskId);
    if (c != null && _ytFinishedStreams.containsKey(c)) {
      _ytCounterpartTaskIds.remove(taskId);
      _ytCounterpartTaskIds.remove(c);
      _ytLiveBytes.remove(taskId);
      _ytLiveBytes.remove(c);
      _ytFinishedStreams.remove(taskId);
      _ytFinishedStreams.remove(c);
    } else if (c == null) {
      _ytLiveBytes.remove(taskId);
      _ytFinishedStreams.remove(taskId);
    } else {
      Timer? timer;
      timer = Timer(const Duration(minutes: 10), () {
        _ytCleanupTimers.remove(timer);
        if (_ytFinishedStreams.containsKey(taskId) &&
            _ytCounterpartTaskIds.containsKey(taskId)) {
          _ytCounterpartTaskIds.remove(taskId);
          _ytCounterpartTaskIds.remove(c);
          _ytLiveBytes.remove(taskId);
          _ytLiveBytes.remove(c);
          _ytFinishedStreams.remove(taskId);
          _ytFinishedStreams.remove(c);
        }
      });
      _ytCleanupTimers.add(timer);
    }
  }

  final Set<Dio> _activeDioClients = {};
  final Set<Dio> _reservedDioClients = {};
  final Map<Dio, DateTime> _dioClientCreationTimes = {};
  final Map<Dio, Set<String>> _activeDownloadsPerClient = {};
  Timer? _cleanupTimer;
  bool _closed = false;
  bool _closing = false;

  void dispose() {
    unawaited(close());
  }

  final SettingsProvider? _injectedSettings;
  SettingsProvider get _settings =>
      _injectedSettings ?? SettingsProvider.instance;

  DownloadEngine({
    Dio? dio,
    SettingsProvider? settings,
    bool enableCleanupTimer = true,
  })  : _sharedDio = dio ?? ConnectionManager.createDownloadDio(),
        _injectedSettings = settings {
    if (enableCleanupTimer) {
      _ytPeriodicTimer = Timer.periodic(const Duration(minutes: 5), (_) {
        if (_closed) return;
        _ytCounterpartTaskIds.removeStale(const Duration(minutes: 10));
        _ytLiveBytes.removeStale(const Duration(minutes: 10));
        _ytFinishedStreams.removeStale(const Duration(minutes: 10));
      });
      _cleanupTimer = Timer.periodic(const Duration(seconds: 60), (_) {
        if (_closed) return;
        final now = DateTime.now();
        final isAggressiveSaver =
            PowerMonitor.batterySaverMode == BatterySaverMode.aggressive ||
                PowerMonitor.screenOff;
        final reservedMaxAge = isAggressiveSaver
            ? const Duration(minutes: 2)
            : const Duration(minutes: 10);
        final normalMaxAge = isAggressiveSaver
            ? const Duration(minutes: 1)
            : const Duration(minutes: 5);

        _activeDioClients.removeWhere((client) {
          final hasActiveDownloads =
              _activeDownloadsPerClient[client]?.isNotEmpty ?? false;
          final creationTime = _dioClientCreationTimes[client] ?? now;
          final age = now.difference(creationTime);
          final reserved = _reservedDioClients.contains(client);
          final stale =
              (reserved ? age > reservedMaxAge : age > normalMaxAge) &&
                  !hasActiveDownloads;
          if (stale) {
            try {
              client.close(force: true);
            } catch (_) {}
            _reservedDioClients.remove(client);
            _dioClientCreationTimes.remove(client);
            _activeDownloadsPerClient.remove(client);
            return true;
          }
          return false;
        });
      });
    }
  }
  Future<DownloadIsolatePool> _ensurePool() {
    final existing = _pool;
    if (existing != null) return Future.value(existing);
    return _poolInit ??= () async {
      final pool = DownloadIsolatePool(size: _isolatePoolSize);
      await pool.init();
      _pool = pool;
      return pool;
    }();
  }

  @visibleForTesting
  bool isLikelyHtmlResponse(String? contentType) {
    final normalized = (contentType ?? '').toLowerCase();
    return normalized.contains('text/html') ||
        normalized.contains('application/xhtml');
  }

  Dio _buildIsolatedClient({
    String? url,
    String? customUserAgent,
    String? referer,
    String? cookies,
    String? oauthToken,
  }) {
    // FIX-M6: Cap _activeDioClients at 20 entries, force-closing the oldest client if exceeded
    while (_activeDioClients.length >= 20) {
      Dio? oldestClient;
      DateTime? oldestTime;
      for (final client in _activeDioClients) {
        final created = _dioClientCreationTimes[client] ?? DateTime.now();
        if (oldestTime == null || created.isBefore(oldestTime)) {
          oldestTime = created;
          oldestClient = client;
        }
      }
      if (oldestClient != null) {
        _releaseClient(oldestClient);
      } else {
        break;
      }
    }

    final client = buildTransferDio(
      url: url,
      customUserAgent: customUserAgent,
      referer: referer,
      cookies: cookies,
      oauthToken: oauthToken,
    );
    _activeDioClients.add(client);
    _reservedDioClients.add(client);
    _dioClientCreationTimes[client] = DateTime.now();
    _activeDownloadsPerClient[client] = {};
    return client;
  }

  void _releaseClient(Dio client) {
    _reservedDioClients.remove(client);
    _activeDioClients.remove(client);
    _dioClientCreationTimes.remove(client);
    _activeDownloadsPerClient.remove(client);
    client.close(force: true);
  }

  Future<DownloadMetadata> resolveMetadata({
    required String url,
    String? requestedFileName,
    String? customUserAgent,
    String? referer,
    String? cookies,
    String? oauthToken,
    CancelToken? cancelToken,
  }) async {
    final isTorrent = isTorrentUrl(url, fileName: requestedFileName);
    if (isTorrent) {
      return _resolveTorrentMetadata(
        url: url,
        requestedFileName: requestedFileName,
        cancelToken: cancelToken,
      );
    }
    final punyUrl = convertIdnToPunycode(url);
    final uri = Uri.tryParse(punyUrl);
    final host = uri?.host.toLowerCase() ?? '';
    final isYoutube = host.contains('youtube.com') ||
        host == 'youtu.be' ||
        host.endsWith('.googlevideo.com');
    final isolatedDio = _buildIsolatedClient(
      url: punyUrl,
      customUserAgent: customUserAgent,
      referer: referer,
      cookies: cookies,
      oauthToken: oauthToken,
    );
    final headFuture = _probeWithHead(
      punyUrl: punyUrl,
      client: isolatedDio,
      requestedFileName: requestedFileName,
      isYoutube: isYoutube,
      cancelToken: cancelToken,
    );
    final getFuture = _probeWithGet(
      punyUrl: punyUrl,
      client: isolatedDio,
      requestedFileName: requestedFileName,
      isYoutube: isYoutube,
      cancelToken: cancelToken,
    );

    try {
      final headResult = await headFuture;
      if (headResult.isValid) {
        getFuture.ignore();
        return headResult;
      }
      final getResult = await getFuture;
      if (getResult.isValid) return getResult;
      return headResult;
    } catch (_) {
      final getResult = await getFuture;
      if (getResult.isValid) return getResult;
      rethrow;
    } finally {
      _releaseClient(isolatedDio);
    }
  }

  Future<DownloadMetadata> _probeWithHead({
    required String punyUrl,
    required Dio client,
    String? requestedFileName,
    required bool isYoutube,
    CancelToken? cancelToken,
  }) async {
    var fileName = requestedFileName?.trim().isNotEmpty == true
        ? safeFileName(requestedFileName!.trim())
        : fileNameFromUrl(punyUrl);
    var fileSize = 0;
    var supportsResume = isYoutube;
    String? etag;
    String? lastModified;

    try {
      final response = await client.head<dynamic>(
        punyUrl,
        cancelToken: cancelToken,
        options: Options(followRedirects: true, validateStatus: (_) => true),
      );
      final headerName = fileNameFromContentDisposition(response.headers);
      if (requestedFileName?.trim().isNotEmpty != true && headerName != null) {
        fileName = headerName;
      }
      etag = response.headers.value('etag');
      lastModified = response.headers.value('last-modified');
      fileSize = int.tryParse(
              response.headers.value(Headers.contentLengthHeader) ?? '') ??
          0;
      final acceptRanges =
          response.headers.value('accept-ranges')?.toLowerCase();
      supportsResume = acceptRanges != null
          ? acceptRanges == 'bytes'
          : (isYoutube || response.statusCode == 206);
      final contentType = response.headers.value(Headers.contentTypeHeader);
      if (isLikelyHtmlResponse(contentType) && fileSize < 1024 * 1024) {
        fileSize = 0;
      }
      if (response.statusCode != null && response.statusCode! >= 400) {
        if (![400, 403, 405].contains(response.statusCode)) {
          fileSize = 0;
        }
      }
    } catch (e) {
      debugPrint('HEAD request failed for ${_redactUrl(punyUrl)}: $e');
    }

    return DownloadMetadata(
      fileName: fileName,
      category: categoryFromFileName(fileName),
      fileSize: fileSize,
      supportsResume: supportsResume,
      etag: etag,
      lastModified: lastModified,
    );
  }

  Future<DownloadMetadata> _probeWithGet({
    required String punyUrl,
    required Dio client,
    String? requestedFileName,
    required bool isYoutube,
    CancelToken? cancelToken,
  }) async {
    var fileName = requestedFileName?.trim().isNotEmpty == true
        ? safeFileName(requestedFileName!.trim())
        : fileNameFromUrl(punyUrl);
    var fileSize = 0;
    var supportsResume = isYoutube;
    String? etag;
    String? lastModified;

    try {
      final getResponse = await client.get<ResponseBody>(
        punyUrl,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          headers: {'Range': 'bytes=0-0'},
          validateStatus: (_) => true,
        ),
      );
      if (getResponse.statusCode == 200 || getResponse.statusCode == 206) {
        final getHeaderName =
            fileNameFromContentDisposition(getResponse.headers);
        if (requestedFileName?.trim().isNotEmpty != true &&
            getHeaderName != null) {
          fileName = getHeaderName;
        }
        etag = getResponse.headers.value('etag');
        lastModified = getResponse.headers.value('last-modified');
        final contentRange = getResponse.headers.value('content-range');
        if (contentRange != null) {
          final totalMatch = RegExp(r'/(\d+)').firstMatch(contentRange);
          fileSize = int.tryParse(totalMatch?.group(1) ?? '') ?? fileSize;
        }
        if (fileSize == 0) {
          fileSize = int.tryParse(
                  getResponse.headers.value(Headers.contentLengthHeader) ??
                      '') ??
              0;
        }
        final getContentType =
            getResponse.headers.value(Headers.contentTypeHeader);
        if (isLikelyHtmlResponse(getContentType) && fileSize < 1024 * 1024) {
          fileSize = 0;
        }
        supportsResume = isYoutube ||
            getResponse.statusCode == 206 ||
            getResponse.headers.value('accept-ranges') == 'bytes';
        await getResponse.data?.stream.listen((_) {}).cancel();
      }
    } catch (e) {
      debugPrint('[DownloadEngine] ranged GET probe failed: $e');
    }

    return DownloadMetadata(
      fileName: fileName,
      category: categoryFromFileName(fileName),
      fileSize: fileSize,
      supportsResume: supportsResume,
      etag: etag,
      lastModified: lastModified,
    );
  }

  Future<DownloadMetadata> _resolveTorrentMetadata({
    required String url,
    String? requestedFileName,
    CancelToken? cancelToken,
  }) async {
    if (url.startsWith('magnet:')) {
      final magnetParams = parseMagnetUrl(url);
      final resolvedName = requestedFileName?.trim().isNotEmpty == true
          ? safeFileName(requestedFileName!.trim())
          : ((magnetParams['name'])?.trim().isNotEmpty == true
              ? safeFileName((magnetParams['name'] as String).trim())
              : 'torrent_download.zip');
      final tempDir = (await getTemporaryDirectory()).path;
      final torrentId = TorrentService.addMagnet(url, tempDir);
      TorrentService.resumeTorrent(torrentId);
      TorrentResumeStore.registerSource(torrentId, url);
      final completer = Completer<DownloadMetadata>();
      StreamSubscription? sub;
      Timer? metadataTimer;
      bool cleanedUp = false;
      void handleCancel() {
        sub?.cancel();
        metadataTimer?.cancel();
        if (!cleanedUp) {
          cleanedUp = true;
          try {
            TorrentService.pauseTorrent(torrentId);
            TorrentService.removeTorrent(torrentId, deleteFiles: false);
          } catch (_) {}
        }
        if (!completer.isCompleted) {
          completer.completeError(DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
            message: 'Download cancelled during metadata resolution',
          ));
        }
      }

      cancelToken?.whenCancel.then((_) => handleCancel());
      if (cancelToken?.isCancelled == true) {
        handleCancel();
        return completer.future;
      }
      sub = TorrentService.torrentUpdates.listen((torrents) {
        final torrent = torrents[torrentId];
        if (torrent != null && torrent.hasMetadata && !completer.isCompleted) {
          metadataTimer?.cancel();
          sub?.cancel();
          final files = TorrentService.getFiles(torrentId);
          final resolvedFiles = files
              .map((f) => {
                    'name': f.name,
                    'length': f.size,
                    'selected': true,
                    'priority': 4,
                    'downloadedBytes': 0,
                    'speed': 0.0,
                    'progress': 0.0,
                    'percent': 0.0,
                    'isComplete': f.size == 0,
                  })
              .toList();
          final totalSize = resolvedFiles.fold<int>(
              0, (sum, f) => sum + (f['length'] as int));
          completer.complete(DownloadMetadata(
            fileName: torrent.name,
            category: categoryFromFileName(torrent.name),
            fileSize: totalSize,
            supportsResume: true,
            torrentFiles: resolvedFiles,
            torrentId: torrentId,
          ));
        }
      });
      metadataTimer = Timer(const Duration(seconds: 300), () {
        if (completer.isCompleted) return;
        sub?.cancel();
        if (!cleanedUp) {
          cleanedUp = true;
          try {
            TorrentService.pauseTorrent(torrentId);
            TorrentService.removeTorrent(torrentId, deleteFiles: false);
          } catch (_) {}
        }
        completer.complete(DownloadMetadata(
          fileName: resolvedName,
          category: 'Torrent',
          fileSize: 0,
          supportsResume: true,
        ));
      });
      return completer.future;
    }
    var fileName = requestedFileName?.trim().isNotEmpty == true
        ? safeFileName(requestedFileName!.trim())
        : 'torrent_download.zip';
    var fileSize = 0;
    List<Map<String, dynamic>>? torrentFiles;
    if (url.startsWith('file://')) {
      final file = File(Uri.parse(url).toFilePath());
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final meta = await compute(BencodeDecoder.parseTorrentBytes, bytes);
        if (meta != null) {
          fileName = meta['name'] ?? fileName;
          fileSize = meta['length'] ?? fileSize;
          torrentFiles = (meta['files'] as List? ?? []).map((f) {
            final fileMap = f as Map;
            final length = fileMap['length'] as int? ?? 0;
            return {
              'name': fileMap['name'] as String? ?? '',
              'length': length,
              'selected': true,
              'priority': 4,
              'downloadedBytes': 0,
              'speed': 0.0,
              'progress': 0.0,
              'percent': 0.0,
              'isComplete': length == 0,
            };
          }).toList();
          if (fileSize == 0) {
            fileSize = torrentFiles.fold<int>(
                0, (sum, f) => sum + ((f['length'] as int?) ?? 0));
          }
        }
      }
    }
    return DownloadMetadata(
      fileName: fileName,
      category: 'Torrent',
      fileSize: fileSize,
      supportsResume: true,
      torrentFiles: torrentFiles,
    );
  }

  void updateSpeedLimit(int bytesPerSecond, int activeCount) {
    TorrentService.setDownloadLimit(bytesPerSecond);
    _pool?.updateSpeedLimit(bytesPerSecond, activeCount);
  }

  Future<bool> hasEnoughDiskSpace(String savePath, int requiredBytes) async {
    try {
      final requiredWithMargin = (requiredBytes * 1.1).toInt();
      final dir = Directory(savePath);
      if (!await dir.exists()) await dir.create(recursive: true);
      final stat = await _getDiskSpace(savePath);
      if (stat == null) return true;
      return stat.freeBytes >= requiredWithMargin;
    } catch (e) {
      debugPrint('[DownloadEngine] disk space check failed: $e');
      return true;
    }
  }

  Future<void> checkLowStorageWarning(String savePath) async {
    try {
      final info = await _getDiskSpace(savePath);
      if (info != null && info.freeBytes < _lowSpaceThresholdBytes) {
        debugPrint('[DownloadEngine] WARNING: low disk space: '
            '${(info.freeBytes / 1024 / 1024).toStringAsFixed(0)} MB remaining');
      }
    } catch (_) {}
  }

  Future<_DiskSpaceInfo?> _getDiskSpace(String path) async {
    try {
      if (Platform.isAndroid || Platform.isLinux || Platform.isMacOS) {
        final result = await Process.run('df', ['-B1', path]);
        if (result.exitCode != 0) return null;
        final lines = (result.stdout as String).trim().split('\n');
        if (lines.length < 2) return null;
        final parts = lines[1].trim().split(RegExp(r'\s+'));
        if (parts.length < 4) return null;
        return _DiskSpaceInfo(freeBytes: int.tryParse(parts[3]) ?? 0);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<int> estimateOptimalThreads({
    required String url,
    required int requestedThreads,
    required int fileSize,
    Dio? dio,
    CancelToken? cancelToken,
  }) async {
    if (requestedThreads <= 1) return 1;
    if (fileSize > 0 && fileSize < ChunkScheduler.minSizeForMultithread) {
      return 1;
    }
    final client = dio ?? _sharedDio;
    try {
      final response = await client
          .head(
            url,
            cancelToken: cancelToken,
            options: Options(
              headers: const {'Range': 'bytes=0-0'},
              validateStatus: (_) => true,
            ),
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException('HEAD probe timed out'),
          );
      if (response.statusCode != null && response.statusCode! >= 400) {
        return 1;
      }
      if (response.headers.value('accept-ranges') == 'none') return 1;
      final conn = response.headers.value('connection')?.toLowerCase();
      if (conn == 'close') return 1;
      return requestedThreads;
    } catch (_) {
      return requestedThreads;
    }
  }

  String buildLocalFilePath(String directory, String fileName) {
    final safeName = safeFileName(fileName);
    final fullPath = p.join(directory, safeName);
    if (!p.isWithin(directory, fullPath)) {
      throw ArgumentError('Invalid file name: path traversal detected');
    }
    return fullPath;
  }

  String buildTempFilePath(String directory, String fileName) {
    final safeName = safeFileName(fileName);
    final fullPath = p.join(directory, '$safeName.dmxpart');
    if (!p.isWithin(directory, fullPath)) {
      throw ArgumentError('Invalid file name: path traversal detected');
    }
    return fullPath;
  }

  static Future<int> cleanupOrphanFiles(
    String tempFilePath, {
    bool mergeConfirmed = false,
  }) async {
    if (tempFilePath.trim().isEmpty) return 0;
    try {
      final dir = File(tempFilePath).parent;
      if (!await dir.exists()) return 0;
      final baseWithoutExt = p.withoutExtension(tempFilePath);
      final patterns = <String>{
        tempFilePath,
        '$tempFilePath.dmxstate',
        '$baseWithoutExt.dmxstate',
        '$tempFilePath.dmxstate.tmp',
        '$tempFilePath.journal',
        '$baseWithoutExt.journal',
      };
      if (mergeConfirmed) {
        patterns.addAll({
          '$tempFilePath.audio',
          '$baseWithoutExt.audio',
          '$tempFilePath.audio.dmxstate',
          '$baseWithoutExt.audio.dmxstate',
          '$tempFilePath.audio.journal',
          '$baseWithoutExt.audio.journal',
          '$tempFilePath.merged',
          '$baseWithoutExt.merged',
        });
      }
      int cleaned = 0;
      for (final path in patterns) {
        try {
          final f = File(path);
          if (await f.exists()) {
            await f.delete();
            cleaned++;
          }
        } catch (e) {
          debugPrint('[DownloadEngine] cleanup failed for $path: $e');
        }
      }

      final stem = p.basenameWithoutExtension(tempFilePath);
      final stemPartPrefix = '$stem.part';
      final dirPath = dir.path;

      final partPathsToDelete = await Isolate.run(() {
        final d = Directory(dirPath);
        if (!d.existsSync()) return <String>[];
        final orphans = <String>[];
        for (final entity in d.listSync(recursive: false)) {
          final basename = p.basename(entity.path);
          if (entity is File &&
              basename.startsWith(stemPartPrefix) &&
              entity.path != tempFilePath) {
            orphans.add(entity.path);
          }
        }
        return orphans;
      });

      for (final path in partPathsToDelete) {
        try {
          await File(path).delete();
          cleaned++;
        } catch (_) {}
      }
      return cleaned;
    } catch (e) {
      debugPrint('[DownloadEngine] cleanupOrphanFiles error: $e');
      return 0;
    }
  }

  Future<void> download({
    required String taskId,
    required String url,
    required String tempFilePath,
    required String localFilePath,
    required int knownFileSize,
    required bool supportsResume,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    required int Function() speedLimitBytesPerSecond,
    required int Function() activeDownloadCount,
    int threadCount = 0,
    String? customUserAgent,
    String? referer,
    String? cookies,
    String? oauthToken,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool isNameAutoGenerated = false,
    List<String>? mirrorUrls,
    bool adaptiveThreads = false,
    int speedLimitKbps = 0,
    YtStreamKind? ytStreamKind,
    int? ytCounterpartSize,
    int? ytCounterpartDownloadedBytes,
    bool isRetry = false,
  }) async {
    _activeCancelTokens[taskId] = cancelToken;
    final int defaultCount = _settings.effectiveDefaultThreadCount;
    final int effectiveThreadCount = (() {
      final base = (threadCount > 0 ? threadCount : defaultCount)
          .clamp(1, PowerMonitor.maxAllowedThreads);
      if (adaptiveThreads) {
        final recommended = _httpEngine.recommendedThreads(taskId, base);
        if (recommended != base) {
          debugPrint(
            '[AdaptiveThreads] task $taskId: using recommended '
            '$recommended threads (was $base)',
          );
        }
        return recommended;
      }
      return base;
    })();
    int resolvedFileSize = knownFileSize;
    bool resolvedSupportsResume = supportsResume;
    String? resolvedFileName;
    final isTorrent = isTorrentUrl(url, fileName: p.basename(localFilePath));
    if (!isTorrent && resolvedFileSize == 0 && isNameAutoGenerated) {
      try {
        final meta = await resolveMetadata(
          url: url,
          customUserAgent: customUserAgent,
          referer: referer,
          cookies: cookies,
          oauthToken: oauthToken,
        );
        resolvedFileSize = meta.fileSize;
        resolvedSupportsResume = meta.supportsResume;
        resolvedFileName = meta.fileName;
      } catch (e) {
        debugPrint('[DownloadEngine] resolveMetadata failed: $e');
      }
      if (resolvedFileName != null || resolvedFileSize > 0) {
        onProgress(DownloadProgress(
          downloadedBytes: 0,
          fileSize: resolvedFileSize,
          speed: 0.0,
          eta: null,
          fileName: resolvedFileName,
          supportsResume: resolvedSupportsResume,
          cycleState: 'starting',
          ytStreamKind: ytStreamKind,
          ytCounterpartSize: ytCounterpartSize,
          ytCounterpartDownloadedBytes: ytCounterpartDownloadedBytes,
        ));
      }
    }
    int alreadyOnDisk = 0;
    List<ChunkDetail>? startingChunkDetails;
    int? startingTotalChunks;
    int? startingCompletedChunks;
    if (resolvedFileSize > 0) {
      final saveDir = File(localFilePath).parent.path;
      try {
        final state = await StateStore.loadOrCreate(
          tempFilePath,
          url: url,
          threadCount: effectiveThreadCount,
          knownFileSize: resolvedFileSize,
        );
        alreadyOnDisk = state.state.downloadedBytes;
        if (!isTorrent && state.state.chunks.isNotEmpty) {
          startingChunkDetails = state.state.chunks.asMap().entries.map((e) {
            final c = e.value;
            final rawRatio = c.ratio;
            final safeRatio = rawRatio < 0.0 ? 0.0 : rawRatio.clamp(0.0, 1.0);
            return ChunkDetail(
              index: e.key,
              start: c.start,
              end: c.end,
              downloaded: c.downloaded,
              size: c.size,
              ratio: safeRatio,
            );
          }).toList();
          startingTotalChunks = startingChunkDetails.length;
          startingCompletedChunks =
              startingChunkDetails.where((c) => c.isComplete).length;
        }
      } catch (_) {}
      final remaining =
          (resolvedFileSize - alreadyOnDisk).clamp(0, resolvedFileSize);
      if (!await hasEnoughDiskSpace(saveDir, remaining)) {
        _activeCancelTokens.remove(taskId);
        throw const InsufficientStorageException();
      }
      await checkLowStorageWarning(saveDir);
    }
    if (isTorrent) {
      try {
        await _handleTorrentDownload(
          url: url,
          currentLocalFilePath: localFilePath,
          knownFileSize: resolvedFileSize,
          cancelToken: cancelToken,
          onProgress: onProgress,
          getTorrentFiles: getTorrentFiles,
          torrentId: torrentId,
          isRetry: isRetry,
        );
      } finally {
        _activeCancelTokens.remove(taskId);
      }
      return;
    }
    var finalUrl = url.replaceAll(RegExp(r'(?<=[?&])range=[^&]*&?'), '');
    if (finalUrl.endsWith('?') || finalUrl.endsWith('&')) {
      finalUrl = finalUrl.substring(0, finalUrl.length - 1);
    }
    final punyUrl = convertIdnToPunycode(finalUrl);
    final command = DownloadCommand(
      taskId: taskId,
      url: url,
      punyUrl: punyUrl,
      tempFilePath: tempFilePath,
      localFilePath: localFilePath,
      knownFileSize: resolvedFileSize,
      supportsResume: resolvedSupportsResume,
      threadCount: effectiveThreadCount,
      customUserAgent: customUserAgent,
      referer: referer,
      cookies: cookies,
      oauthToken: oauthToken,
      isNameAutoGenerated: isNameAutoGenerated,
      initialSpeedLimit: speedLimitBytesPerSecond(),
      initialActiveCount: activeDownloadCount(),
      mirrorUrls: mirrorUrls,
      adaptiveThreads: adaptiveThreads,
      speedLimitKbps: speedLimitKbps,
      resolvedFileName: resolvedFileName,
      ytStreamKind: ytStreamKind,
      ytCounterpartSize: ytCounterpartSize,
      ytCounterpartDownloadedBytes: ytCounterpartDownloadedBytes,
      ytCounterpartTaskId: _ytCounterpartTaskIds[taskId],
      throttleFactor: PowerMonitor.throttleFactor,
    );
    if (adaptiveThreads) {
      _httpEngine.startAdaptiveMonitorForTask(taskId, effectiveThreadCount);
    }
    int? ytStartingCounterpartBytes = ytCounterpartDownloadedBytes;
    if (ytStreamKind != null) {
      _ytLiveBytes[taskId] = alreadyOnDisk;
      final counterpartBytes = ytCounterpartDownloadedBytes;
      if (counterpartBytes != null && counterpartBytes > 0) {
        final counterpartId = _ytCounterpartTaskIds[taskId];
        if (counterpartId != null) {
          _ytLiveBytes.putIfAbsent(
            counterpartId,
            () => counterpartBytes,
          );
        }
      }
      final ytStartCid = _ytCounterpartTaskIds[taskId];
      if (ytStartCid != null) {
        final live = _ytLiveBytes[ytStartCid];
        if (live != null) {
          ytStartingCounterpartBytes = live;
        }
      }
    }
    if (!isTorrent) {
      onProgress(DownloadProgress(
        downloadedBytes: alreadyOnDisk,
        fileSize: resolvedFileSize,
        speed: 0.0,
        eta: null,
        fileName: resolvedFileName,
        supportsResume: resolvedSupportsResume,
        cycleState: isRetry
            ? 'retrying'
            : (alreadyOnDisk > 0 ? 'resuming' : 'starting'),
        ytStreamKind: ytStreamKind,
        ytCounterpartSize: ytCounterpartSize,
        ytCounterpartDownloadedBytes: ytStartingCounterpartBytes,
        ytDownloadedBytes: alreadyOnDisk,
        chunkDetails: startingChunkDetails,
        totalChunks: startingTotalChunks,
        completedChunks: startingCompletedChunks,
      ));
    }

    // FIX-P3: Use DownloadProgressHandler
    final progressHandler = DownloadProgressHandler(
      taskId: taskId,
      onProgress: onProgress,
      cancelToken: cancelToken,
      resolvedFileName: resolvedFileName,
      resolvedSupportsResume: resolvedSupportsResume,
      ytStreamKind: ytStreamKind,
      ytCounterpartSize: ytCounterpartSize,
      ytCounterpartDownloadedBytes: ytStartingCounterpartBytes,
      isTorrent: isTorrent,
      getTorrentFiles: getTorrentFiles,
      torrentId: torrentId,
      getEffectiveIntervalMs: () => effectiveProgressReportIntervalMs,
      lastDownloadedBytes: alreadyOnDisk,
      lastFileSize: resolvedFileSize,
      lastChunkDetails: startingChunkDetails,
      lastTotalChunks: startingTotalChunks,
      lastCompletedChunks: startingCompletedChunks,
    );

    final pool = await _ensurePool();
    final PoolJob job;
    try {
      job = pool.submit(command);
    } catch (e) {
      _activeCancelTokens.remove(taskId);
      rethrow;
    }
    final completer = Completer<void>();
    bool acked = false;
    bool cancelRequested = false;
    Timer? watchdog;
    Timer? inactivityTimer;
    void resetInactivityTimer() {
      inactivityTimer?.cancel();
      inactivityTimer = Timer(const Duration(minutes: 30), () {
        if (!completer.isCompleted) {
          completer.completeError(DioException(
            requestOptions: RequestOptions(path: punyUrl),
            type: DioExceptionType.receiveTimeout,
            message: 'Download job timed out after 30 minutes of inactivity.',
          ));
        }
      });
    }

    resetInactivityTimer();
    watchdog = Timer(const Duration(seconds: 30), () {
      if (!acked && !completer.isCompleted) {
        inactivityTimer?.cancel();
        completer.completeError(const IsolateSpawnTimeoutException());
      }
    });
    void requestCancel() {
      if (completer.isCompleted) return;
      cancelRequested = true;
      job.cancel();
      // FIX-H2: YouTube pause — also cancel active counterpart audio/video token
      final counterpartId = _ytCounterpartTaskIds[taskId];
      if (counterpartId != null) {
        final counterpartToken = _activeCancelTokens[counterpartId];
        if (counterpartToken != null && !counterpartToken.isCancelled) {
          counterpartToken.cancel('paused');
        }
      }
      // FIX-1: Do NOT delete file here. File cleanup happens in the 'done'/'error'
      // handler after isolate confirms stop.
      final ytPauseCid = _ytCounterpartTaskIds[taskId];
      int? ytPauseLiveCp =
          ytPauseCid != null ? _ytLiveBytes[ytPauseCid] : null;
      if (ytPauseLiveCp == null && ytPauseCid != null) {
        ytPauseLiveCp = ytCounterpartDownloadedBytes ?? 0;
      }
      onProgress(DownloadProgress(
        downloadedBytes: progressHandler.lastDownloadedBytes,
        fileSize: progressHandler.lastFileSize,
        speed: 0.0,
        eta: null,
        fileName: resolvedFileName,
        supportsResume: resolvedSupportsResume,
        statusMessage: 'Paused',
        cycleState: 'paused',
        ytStreamKind: ytStreamKind,
        ytCounterpartSize: ytCounterpartSize,
        ytCounterpartDownloadedBytes:
            ytPauseLiveCp ?? ytCounterpartDownloadedBytes,
        ytDownloadedBytes: _ytLiveBytes[taskId],
        chunkDetails: progressHandler.lastChunkDetails,
        totalChunks: progressHandler.lastTotalChunks,
        completedChunks: progressHandler.lastCompletedChunks,
        torrentFiles: progressHandler.lastTorrentFiles,
        totalFiles: progressHandler.lastTotalFiles,
        completedFiles: progressHandler.lastCompletedFiles,
        totalFileBytes: progressHandler.lastTotalFileBytes,
        downloadedFileBytes: progressHandler.lastDownloadedFileBytes,
        torrentId: torrentId,
      ));
      if (!completer.isCompleted) {
        completer.completeError(DioException(
          requestOptions: RequestOptions(path: punyUrl),
          type: DioExceptionType.cancel,
          message: 'Download was cancelled.',
        ));
      }
    }

    final cancelFuture = cancelToken.whenCancel.then((_) => requestCancel());
    if (cancelToken.isCancelled) requestCancel();
    final sub = job.messages.listen((message) async {
      switch (message.type) {
        case 'ack':
          acked = true;
          watchdog?.cancel();
          if (cancelRequested) job.cancel();
          break;
        case 'error':
          // FIX-P3: Check cancelToken.isCancelled
          if (cancelToken.isCancelled) break;
          resetInactivityTimer();
          final errData = message.data;
          final errorType = errData['errorType'] as String? ?? 'uncaught';
          final errorMsg =
              errData['errorMessage'] as String? ?? 'Unknown error';
          if (errorType == 'cancel') {
            if (!completer.isCompleted) {
              completer.completeError(DioException(
                requestOptions: RequestOptions(path: punyUrl),
                type: DioExceptionType.cancel,
                message: errorMsg,
              ));
            }
            break;
          }
          if (errorType == 'urlExpired') {
            final ytUlcId = _ytCounterpartTaskIds[taskId];
            int? ytUlcLiveCp =
                ytUlcId != null ? _ytLiveBytes[ytUlcId] : null;
            if (ytUlcLiveCp == null && ytUlcId != null) {
              ytUlcLiveCp = ytCounterpartDownloadedBytes ?? 0;
            }
            final ytUlcLiveSelf = _ytLiveBytes[taskId];
            onProgress(DownloadProgress(
              downloadedBytes:
                  ytUlcLiveSelf ?? progressHandler.lastDownloadedBytes,
              fileSize: progressHandler.lastFileSize,
              speed: 0.0,
              eta: null,
              fileName: resolvedFileName,
              supportsResume: resolvedSupportsResume,
              statusMessage: 'Updating links (URL expired)…',
              cycleState: 'updating_links',
              ytStreamKind: ytStreamKind,
              ytCounterpartSize: ytCounterpartSize,
              ytCounterpartDownloadedBytes:
                  ytUlcLiveCp ?? ytCounterpartDownloadedBytes,
              ytDownloadedBytes: ytUlcLiveSelf,
              chunkDetails: progressHandler.lastChunkDetails,
              totalChunks: progressHandler.lastTotalChunks,
              completedChunks: progressHandler.lastCompletedChunks,
              torrentFiles: progressHandler.lastTorrentFiles,
              totalFiles: progressHandler.lastTotalFiles,
              completedFiles: progressHandler.lastCompletedFiles,
              totalFileBytes: progressHandler.lastTotalFileBytes,
              downloadedFileBytes: progressHandler.lastDownloadedFileBytes,
            ));
            if (!completer.isCompleted) {
              completer.completeError(_mapWorkerError(message, punyUrl));
            }
            break;
          }
          final isRetryable = errorType == 'connectionTimeout' ||
              errorType == 'connectionError' ||
              errorType == 'receiveTimeout' ||
              errorType == 'sendTimeout';
          final ytFailCid = _ytCounterpartTaskIds[taskId];
          int? ytFailLiveCp =
              ytFailCid != null ? _ytLiveBytes[ytFailCid] : null;
          if (ytFailLiveCp == null && ytFailCid != null) {
            ytFailLiveCp = ytCounterpartDownloadedBytes ?? 0;
          }
          onProgress(DownloadProgress(
            downloadedBytes: progressHandler.lastDownloadedBytes,
            fileSize: progressHandler.lastFileSize,
            speed: 0.0,
            eta: null,
            fileName: resolvedFileName,
            supportsResume: resolvedSupportsResume,
            statusMessage: isRetryable ? 'Retrying: $errorMsg' : errorMsg,
            cycleState: isRetryable ? 'retrying' : 'failed',
            ytStreamKind: ytStreamKind,
            ytCounterpartSize: ytCounterpartSize,
            ytCounterpartDownloadedBytes:
                ytFailLiveCp ?? ytCounterpartDownloadedBytes,
            ytDownloadedBytes: _ytLiveBytes[taskId],
            chunkDetails: progressHandler.lastChunkDetails,
            totalChunks: progressHandler.lastTotalChunks,
            completedChunks: progressHandler.lastCompletedChunks,
            torrentFiles: progressHandler.lastTorrentFiles,
            totalFiles: progressHandler.lastTotalFiles,
            completedFiles: progressHandler.lastCompletedFiles,
            totalFileBytes: progressHandler.lastTotalFileBytes,
            downloadedFileBytes: progressHandler.lastDownloadedFileBytes,
          ));
          if (!completer.isCompleted) {
            if (errorType == 'diskFull') {
              completer.completeError(InsufficientStorageException(errorMsg));
            } else if (errorType == 'integrity') {
              completer.completeError(DownloadIntegrityException(errorMsg));
            } else if (errorType == 'fileChanged') {
              completer.completeError(DownloadIntegrityException(errorMsg));
            } else if (errorType == 'badResponse') {
              final status = errData['errorStatus'] as int?;
              completer.completeError(DioException(
                requestOptions: RequestOptions(path: punyUrl),
                type: DioExceptionType.badResponse,
                message: errorMsg,
                response: Response(
                  requestOptions: RequestOptions(path: punyUrl),
                  statusCode: status,
                ),
              ));
            } else if (errorType == 'connectionTimeout' ||
                errorType == 'connectionError' ||
                errorType == 'receiveTimeout' ||
                errorType == 'sendTimeout') {
              final dioType = switch (errorType) {
                'connectionTimeout' => DioExceptionType.connectionTimeout,
                'connectionError' => DioExceptionType.connectionError,
                'receiveTimeout' => DioExceptionType.receiveTimeout,
                'sendTimeout' => DioExceptionType.sendTimeout,
                _ => DioExceptionType.unknown,
              };
              completer.completeError(DioException(
                requestOptions: RequestOptions(path: punyUrl),
                type: dioType,
                message: errorMsg,
              ));
            } else if (errorType == 'workerDied') {
              completer.completeError(DioException(
                requestOptions: RequestOptions(path: punyUrl),
                type: DioExceptionType.unknown,
                message: 'Download engine worker crashed: $errorMsg',
              ));
            } else {
              completer.completeError(Exception(errorMsg));
            }
          }
          break;
        case 'progress':
          // FIX-P3: Check cancelToken.isCancelled and process via progressHandler
          if (cancelToken.isCancelled) break;
          resetInactivityTimer();
          await progressHandler.handleProgress(
            message.data,
            ytCounterpartTaskIds: _ytCounterpartTaskIds,
            ytLiveBytes: _ytLiveBytes,
            adaptiveThreads: adaptiveThreads,
            effectiveThreadCount: effectiveThreadCount,
            httpEngine: _httpEngine,
          );
          break;
        case 'done':
          if (ytStreamKind != null && progressHandler.lastFileSize > 0) {
            _ytLiveBytes[taskId] = progressHandler.lastFileSize;
          }
          watchdog?.cancel();
          inactivityTimer?.cancel();
          if (cancelRequested || cancelToken.isCancelled) {
            try {
              final finalFile = File(localFilePath);
              if (finalFile.existsSync()) finalFile.deleteSync();
            } catch (_) {}
            if (!completer.isCompleted) {
              completer.completeError(DioException(
                requestOptions: RequestOptions(path: punyUrl),
                type: DioExceptionType.cancel,
                message: 'Download cancelled.',
              ));
            }
          } else {
            final ytDoneCid = _ytCounterpartTaskIds[taskId];
            int? ytDoneLiveCp = ytDoneCid != null
                ? _ytLiveBytes[ytDoneCid]
                : null;
            if (ytDoneLiveCp == null && ytDoneCid != null) {
              ytDoneLiveCp = ytCounterpartDownloadedBytes ?? 0;
            }
            if (progressHandler.lastFileSize > 0) {
              progressHandler.lastDownloadedBytes =
                  progressHandler.lastFileSize;
            }
            if (progressHandler.lastChunkDetails != null &&
                progressHandler.lastTotalChunks != null) {
              progressHandler.lastCompletedChunks =
                  progressHandler.lastTotalChunks;
            }
            if (progressHandler.lastTotalFiles != null) {
              progressHandler.lastCompletedFiles =
                  progressHandler.lastTotalFiles;
            }
            if (progressHandler.lastTotalFileBytes != null) {
              progressHandler.lastDownloadedFileBytes =
                  progressHandler.lastTotalFileBytes;
            }
            var doneCycle = 'completed';
            if (ytStreamKind != null && ytStreamKind != YtStreamKind.combined) {
              final cpSize = ytCounterpartSize;
              if (cpSize == null || cpSize <= 0) {
                if (ytDoneLiveCp == null) {
                  doneCycle = 'completed';
                } else {
                  doneCycle = 'downloading';
                }
              } else {
                final cpDl = ytDoneLiveCp ?? 0;
                if (cpDl < cpSize) {
                  doneCycle = 'downloading';
                }
              }
            }
            onProgress(DownloadProgress(
              downloadedBytes: progressHandler.lastDownloadedBytes,
              fileSize: progressHandler.lastFileSize,
              speed: 0.0,
              eta: null,
              fileName: resolvedFileName,
              supportsResume: resolvedSupportsResume,
              statusMessage: doneCycle == 'completed'
                  ? 'Completed'
                  : (ytStreamKind == YtStreamKind.video
                      ? 'Video stream completed, downloading audio…'
                      : 'Audio stream completed, downloading video…'),
              cycleState: doneCycle,
              ytStreamKind: ytStreamKind,
              ytCounterpartSize: ytCounterpartSize,
              ytCounterpartDownloadedBytes:
                  ytDoneLiveCp ?? ytCounterpartDownloadedBytes,
              ytDownloadedBytes: _ytLiveBytes[taskId] ??
                  progressHandler.lastDownloadedBytes,
              chunkDetails: progressHandler.lastChunkDetails,
              totalChunks: progressHandler.lastTotalChunks,
              completedChunks: progressHandler.lastCompletedChunks,
              torrentFiles: progressHandler.lastTorrentFiles,
              totalFiles: progressHandler.lastTotalFiles,
              completedFiles: progressHandler.lastCompletedFiles ??
                  progressHandler.lastTotalFiles,
              totalFileBytes: progressHandler.lastTotalFileBytes,
              downloadedFileBytes: progressHandler.lastDownloadedFileBytes ??
                  progressHandler.lastTotalFileBytes,
            ));
            if (!completer.isCompleted) {
              completer.complete();
            }
          }
          break;
      }
    });
    try {
      await completer.future;
    } finally {
      cancelFuture.catchError((_) {});
      watchdog.cancel();
      inactivityTimer?.cancel();
      await sub.cancel();
      job.dispose();
      _activeCancelTokens.remove(taskId);
      if (ytStreamKind != null) {
        unregisterYtCounterpart(taskId);
      }
      if (adaptiveThreads) {
        if (_httpEngine.activeTrackerCount == 0) {
          _httpEngine.stopAdaptiveThreadMonitor();
        }
      }
    }
  }

  Object _mapWorkerError(EngineMessage message, String url) {
    final data = message.data;
    final errType = data['errorType'] as String? ?? 'uncaught';
    final errMsg = data['errorMessage']?.toString() ?? 'Unknown engine error';
    final errStatus = data['errorStatus'] as int?;
    switch (errType) {
      case 'integrity':
        return DownloadIntegrityException(errMsg);
      case 'diskFull':
        return const InsufficientStorageException();
      case 'fileChanged':
        return DownloadIntegrityException(errMsg);
      case 'workerDied':
        return DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.unknown,
          message: 'Download engine worker crashed: $errMsg',
        );
      case 'urlExpired':
        return UrlExpiredException(
          errMsg,
          refreshAllMirrors: data['refreshAllMirrors'] == true,
        );
      default:
        final DioExceptionType dioType = switch (errType) {
          'cancel' => DioExceptionType.cancel,
          'badResponse' => DioExceptionType.badResponse,
          'connectionTimeout' => DioExceptionType.connectionTimeout,
          'receiveTimeout' => DioExceptionType.receiveTimeout,
          'sendTimeout' => DioExceptionType.sendTimeout,
          'connectionError' => DioExceptionType.connectionError,
          _ => DioExceptionType.unknown,
        };
        return DioException(
          requestOptions: RequestOptions(path: url),
          type: dioType,
          message: errMsg,
          response: errStatus != null
              ? Response(
                  requestOptions: RequestOptions(path: url),
                  statusCode: errStatus,
                )
              : null,
        );
    }
  }

  Future<void> _handleTorrentDownload({
    required String url,
    required String currentLocalFilePath,
    required int knownFileSize,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool isRetry = false,
  }) async {
    final initialTorrentFiles = getTorrentFiles?.call();
    final initSummary = normalizeTorrentFiles(initialTorrentFiles);
    onProgress(DownloadProgress(
      downloadedBytes: initSummary.downloaded,
      fileSize: initSummary.bytes > 0 ? initSummary.bytes : knownFileSize,
      speed: 0.0,
      eta: null,
      supportsResume: true,
      torrentFiles: initialTorrentFiles,
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
    final saveDir = File(currentLocalFilePath).parent.path;
    if (id >= 0 && !TorrentService.isTorrentAlive(id)) {
      debugPrint('[DMX] Stale torrent handle $id detected; re-adding.');
      id = -1;
    }
    if (id == -1) {
      await validateSavePath(saveDir);
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
          final torrentDio = _buildIsolatedClient(
            url: url,
          );
          try {
            await torrentDio.download(url, tempTorrentPath);
            filePath = tempTorrentPath;
            id = TorrentService.addTorrentFile(filePath, saveDir,
                sourceKey: url);
          } finally {
            _releaseClient(torrentDio);
            try {
              if (await tempTorrentFile.exists()) {
                await tempTorrentFile.delete();
              }
            } catch (_) {}
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
      } catch (_) {}
      // FIX-H3: Torrent pause — 200ms delay and disk-accurate bytes
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
                    'downloadedBytes':
                        f.downloadedBytes >= 0 ? f.downloadedBytes : 0,
                    'selected': f.isComplete || f.downloadedBytes > 0,
                    'progress': f.progress,
                  })
              .toList();
        }
      } catch (_) {}
      final pSummary = normalizeTorrentFiles(pauseFiles);
      onProgress(DownloadProgress(
        downloadedBytes: pSummary.downloaded,
        fileSize: pSummary.bytes > 0 ? pSummary.bytes : knownFileSize,
        speed: 0.0,
        eta: null,
        supportsResume: true,
        torrentFiles: pauseFiles,
        statusMessage: 'Paused',
        cycleState: 'paused',
        totalFiles: pSummary.total > 0 ? pSummary.total : null,
        completedFiles: pSummary.total > 0 ? pSummary.done : null,
        totalFileBytes: pSummary.bytes > 0 ? pSummary.bytes : null,
        downloadedFileBytes: pSummary.bytes > 0 ? pSummary.downloaded : null,
        torrentId: id,
      ));
    });
    try {
      await _waitForMetadata(id, url, cancelToken, onProgress,
          initialFileSize: knownFileSize, getTorrentFiles: getTorrentFiles);
      _applyFilePriorities(id, getTorrentFiles?.call());
      final resumeBlob = await TorrentResumeStore.loadResumeDataForSource(url);
      final nativeLoaded =
          resumeBlob != null && TorrentService.loadResumeData(id, resumeBlob);
      if (nativeLoaded) {
        // FIX-H4: Torrent resume — per-file bytes re-read after loadResumeData succeeds
        final freshFiles = TorrentService.getFiles(id);
        if (freshFiles.isNotEmpty) {
          final updatedFiles = freshFiles.map((f) => {
            'name': f.name,
            'length': f.size,
            'downloadedBytes': f.downloadedBytes >= 0 ? f.downloadedBytes : 0,
            'selected': f.selected,
            'priority': f.priority,
            'progress': f.size > 0
                ? (f.downloadedBytes / f.size).clamp(0.0, 1.0)
                : 0.0,
          }).toList();
          // Emit progress with fresh file data
          onProgress(DownloadProgress(
            downloadedBytes: freshFiles.fold<int>(0, (s, f) =>
                s + (f.downloadedBytes >= 0 ? f.downloadedBytes : 0)),
            fileSize: freshFiles.fold<int>(0, (s, f) => s + f.size),
            speed: 0,
            eta: null,
            torrentFiles: updatedFiles,
            statusMessage: 'Resuming from saved state…',
            cycleState: 'resuming',
          ));
        }
      } else {
        if (resumeBlob != null) {
          debugPrint(
              '[DMX] stored resume data rejected by engine — rechecking');
        }
        TorrentService.recheckTorrent(id);
        int effectiveSize = knownFileSize;
        try {
          final sizeCompleter = Completer<int>();
          final sizeSub = TorrentService.torrentUpdates.listen((torrents) {
            final t = torrents[id];
            if (t != null && t.hasMetadata && t.totalWanted > 0) {
              if (!sizeCompleter.isCompleted) {
                sizeCompleter.complete(t.totalWanted);
              }
            }
          });
          effectiveSize = await sizeCompleter.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () => knownFileSize,
          );
          await sizeSub.cancel();
        } catch (_) {}
        final recheckTimeout = Duration(
          minutes: max(5, (effectiveSize ~/ (100 * 1024 * 1024)) + 5),
        );
        await _waitForState(
          id,
          cancelToken,
          predicate: (label) =>
              !label.contains('checking') &&
              !label.contains('metadata') &&
              !label.contains('allocating'),
          timeout: recheckTimeout,
          onProgress: onProgress,
          knownFileSize: effectiveSize,
          getTorrentFiles: getTorrentFiles,
        );
        final postCheckFiles = getTorrentFiles?.call();
        final postCheckSummary = normalizeTorrentFiles(postCheckFiles);
        onProgress(DownloadProgress(
          downloadedBytes: postCheckSummary.downloaded,
          fileSize: postCheckSummary.bytes > 0
              ? postCheckSummary.bytes
              : effectiveSize,
          speed: 0.0,
          eta: null,
          supportsResume: true,
          torrentFiles: postCheckFiles,
          statusMessage: 'Starting download…',
          cycleState: 'starting',
          torrentId: id,
          totalFiles:
              postCheckSummary.total > 0 ? postCheckSummary.total : null,
          completedFiles:
              postCheckSummary.total > 0 ? postCheckSummary.done : null,
          totalFileBytes:
              postCheckSummary.bytes > 0 ? postCheckSummary.bytes : null,
          downloadedFileBytes:
              postCheckSummary.bytes > 0 ? postCheckSummary.downloaded : null,
        ));
      }
      if (cancelToken.isCancelled) return;
      TorrentService.resumeTorrent(id);
      await _listenForCompletion(
        id,
        url,
        cancelToken,
        onProgress,
        getTorrentFiles,
        knownFileSize,
      );
    } catch (e) {
      if (!cancelToken.isCancelled) {
        if (e is! TorrentEnginePauseException) {
          final isRetryable = e is DioException &&
              (e.type == DioExceptionType.connectionTimeout ||
                  e.type == DioExceptionType.connectionError ||
                  e.type == DioExceptionType.receiveTimeout ||
                  e.type == DioExceptionType.sendTimeout);
          final failedFiles = getTorrentFiles?.call();
          final fSummary = normalizeTorrentFiles(failedFiles);
          onProgress(DownloadProgress(
            downloadedBytes: fSummary.downloaded,
            fileSize: fSummary.bytes > 0 ? fSummary.bytes : knownFileSize,
            speed: 0.0,
            eta: null,
            supportsResume: true,
            torrentFiles: failedFiles,
            statusMessage: isRetryable
                ? 'Retrying: ${e.toString()}'
                : 'Failed: ${e.toString()}',
            cycleState: isRetryable ? 'retrying' : 'failed',
            totalFiles: fSummary.total > 0 ? fSummary.total : null,
            completedFiles: fSummary.total > 0 ? fSummary.done : null,
            totalFileBytes: fSummary.bytes > 0 ? fSummary.bytes : null,
            downloadedFileBytes:
                fSummary.bytes > 0 ? fSummary.downloaded : null,
            torrentId: id,
          ));
        }
        try {
          // FIX-TORR-RESTART-1: Use pauseTorrent instead of removeTorrent here.
          // removeTorrent deletes the fast-resume blob from TorrentResumeStore,
          // so next launch finds no resume data and rechecks from piece 0
          // ("start over"). Pausing preserves the blob so the next resume
          // uses it for instant fast-resume without a full recheck.
          TorrentService.pauseTorrent(id);
        } catch (_) {}
      }
      rethrow;
    } finally {
      torrentCompleted = true;
      _activeTorrentIds.remove(id);
      // FIX-TORR-RESTART-2: Only unregister the source URL when the download
      // truly completed (status == completed / seeding). If this cycle ended
      // via cancel (pause) or error, keep the registry entry so the periodic
      // TorrentResumeStore.saveAll() can still find the source and persist
      // fresh resume blobs. Without this, saveAll silently skips the torrent
      // ("no source registered for id X") and next launch has no resume data.
      if (torrentCompleted && !cancelToken.isCancelled) {
        TorrentResumeStore.unregisterSource(url);
      }
      _lastConcurrentLimitApply.remove(id);
      _lastIncompleteSnapshot.remove(id);
    }
  }

  Future<void> _waitForMetadata(
    int id,
    String url,
    CancelToken cancelToken,
    ValueChangedProgress onProgress, {
    int initialFileSize = 0,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
  }) async {
    final completer = Completer<void>();
    StreamSubscription? sub;
    Timer? heartbeat;
    var elapsed = 0;
    sub = TorrentService.torrentUpdates.listen((torrents) {
      final torrent = torrents[id];
      if (torrent != null && torrent.hasMetadata && !completer.isCompleted) {
        completer.complete();
      }
    });
    cancelToken.whenCancel.then((_) {
      if (!completer.isCompleted) {
        try {
          TorrentService.removeTorrent(id, deleteFiles: false);
        } catch (_) {}
        completer.completeError(DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel,
          error: 'cancelled',
        ));
      }
    });
    heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      if (completer.isCompleted) return;
      elapsed += 10;
      final metaFiles = getTorrentFiles?.call();
      final mfSummary = normalizeTorrentFiles(metaFiles);
      onProgress(DownloadProgress(
        downloadedBytes: mfSummary.downloaded,
        fileSize: initialFileSize > 0 ? initialFileSize : 0,
        speed: 0,
        eta: null,
        statusMessage: 'Fetching metadata… (${elapsed}s / 300s)',
        cycleState: 'fetching_metadata',
        torrentFiles: metaFiles,
        totalFiles: mfSummary.total > 0 ? mfSummary.total : null,
        completedFiles: mfSummary.total > 0 ? mfSummary.done : null,
        totalFileBytes: mfSummary.bytes > 0 ? mfSummary.bytes : null,
        downloadedFileBytes: mfSummary.bytes > 0 ? mfSummary.downloaded : null,
        torrentId: id,
      ));
    });
    final timeout = Timer(const Duration(seconds: 300), () {
      if (completer.isCompleted) return;
      sub?.cancel();
      if (!cancelToken.isCancelled) {
        try {
          TorrentService.removeTorrent(id, deleteFiles: false);
        } catch (_) {}
      }
      completer.completeError(DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.receiveTimeout,
        error: 'Timed out waiting for torrent metadata.',
      ));
    });
    try {
      await completer.future;
    } finally {
      heartbeat.cancel();
      timeout.cancel();
      await sub.cancel();
    }
  }

  void _applyFilePriorities(
    int id,
    List<Map<String, dynamic>>? currentTorrentFiles,
  ) {
    if (currentTorrentFiles == null || currentTorrentFiles.isEmpty) return;
    final engineFileCount = TorrentService.getFileCount(id);
    if (engineFileCount != currentTorrentFiles.length) {
      debugPrint(
        '[DMX] T-2 FIX: File count mismatch (stored='
        '${currentTorrentFiles.length}, engine=$engineFileCount). '
        'Attempting name-based reconciliation...',
      );
      final engineFiles = TorrentService.getFiles(id);
      String normalizeName(String name) {
        var decoded = name;
        try {
          // FIX: Only decode if it looks URL-encoded (contains % patterns)
          if (name.contains('%')) {
            decoded = Uri.decodeComponent(name);
          }
        } catch (_) {}
        return decoded.replaceAll('\\', '/').trim().toLowerCase();
      }

      final storedByName = <String, Map<String, dynamic>>{};
      for (final f in currentTorrentFiles) {
        storedByName[normalizeName(f['name'] as String? ?? '')] = f;
      }
      final anyUserDeselected =
          currentTorrentFiles.any((f) => !isTorrentFileSelected(f));
      final priorities = <int>[];
      final preservedBytes = <String, int>{};
      var userDeselectedCount = 0;
      for (final ef in engineFiles) {
        final key = normalizeName(ef.name);
        var stored = storedByName[key];
        // FIX-H5: After storedByName lookup fails, try size-based match
        if (stored == null) {
          final sizeMatches = currentTorrentFiles.where(
            (f) => (f['length'] as num?)?.toInt() == ef.size,
          ).toList();
          if (sizeMatches.length == 1) {
            stored = sizeMatches.first;
          }
        }
        if (stored != null) {
          final selected = isTorrentFileSelected(stored);
          if (!selected) userDeselectedCount++;
          priorities.add(selected ? (stored['priority'] as int? ?? 4) : 0);
          final storedBytes = (stored['downloadedBytes'] as num?)?.toInt() ?? 0;
          if (storedBytes > 0) {
            preservedBytes[key] =
                storedBytes.clamp(0, ef.size > 0 ? ef.size : storedBytes);
          }
        } else {
          priorities.add(anyUserDeselected ? 0 : 4);
        }
      }
      debugPrint(
        '[DMX] FIX-RECONCILE-BYTES: preserved bytes for '
        '${preservedBytes.length} file(s) across reconciliation.',
      );
      if (priorities.length == engineFileCount) {
        TorrentService.setFilePriorities(id, priorities);
        debugPrint(
            '[DMX] FIX-6/T-2: Reconciled priorities ($userDeselectedCount user-deselected).');
      } else {
        final fallback = List<int>.generate(engineFileCount, (i) {
          final ef = i < engineFiles.length ? engineFiles[i] : null;
          if (ef == null) return 4;
          final stored = storedByName[normalizeName(ef.name)];
          return stored != null && isTorrentFileSelected(stored)
              ? (stored['priority'] as int? ?? 4)
              : 0;
        });
        TorrentService.setFilePriorities(id, fallback);
        debugPrint(
            '[DMX] FIX-6/T-2: Reconciliation mismatch — preserved user selection.');
      }
      return;
    }
    final priorities = currentTorrentFiles.map((f) {
      final selected = isTorrentFileSelected(f);
      if (!selected) return 0;
      return f['priority'] as int? ?? 4;
    }).toList();
    TorrentService.setFilePriorities(id, priorities);
  }

  Future<void> _listenForCompletion(
    int id,
    String url,
    CancelToken cancelToken,
    ValueChangedProgress onProgress,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int knownFileSize,
  ) async {
    final completer = Completer<void>();
    StreamSubscription? sub;
    sub = TorrentService.torrentUpdates.listen((torrents) {
      final torrent = torrents[id];
      if (torrent == null || completer.isCompleted) return;
      final stateLabel = torrent.stateLabel.toLowerCase();
      final isCheckingOrMetadata = stateLabel.contains('checking') ||
          stateLabel.contains('metadata') ||
          stateLabel.contains('allocating');
      List<Map<String, dynamic>>? resolvedFiles;
      String? resolvedName;
      if (torrent.hasMetadata) {
        resolvedName = torrent.name;
        try {
          final files = TorrentService.getFiles(id);
          final existingFiles = getTorrentFiles?.call() ?? [];
          String normalizeName(String name) {
            var decoded = name;
            try {
              // FIX: Only decode if it looks URL-encoded (contains % patterns)
              if (name.contains('%')) {
                decoded = Uri.decodeComponent(name);
              }
            } catch (_) {}
            return decoded.replaceAll('\\', '/').trim().toLowerCase();
          }

          resolvedFiles = files.map((f) {
            final existing =
                existingFiles.cast<Map<String, dynamic>?>().firstWhere(
                      (e) =>
                          normalizeName(e?['name'] as String? ?? '') ==
                          normalizeName(f.name),
                      orElse: () => null,
                    );
            int resolvedBytes;
            bool isEstimated;
            double fileProgress;
            if (f.hasProgressData) {
              resolvedBytes =
                  f.size > 0 ? f.safeDownloadedBytes.clamp(0, f.size) : 0;
              isEstimated = false;
              fileProgress =
                  f.size > 0 ? (resolvedBytes / f.size).clamp(0.0, 1.0) : 1.0;
            } else {
              final prevStored =
                  (existing?['downloadedBytes'] as num?)?.toInt() ?? 0;
              resolvedBytes = f.size > 0
                  ? prevStored.clamp(0, f.size)
                  : prevStored.clamp(0, 1 << 62);
              isEstimated = true;
              fileProgress =
                  f.size > 0 ? (resolvedBytes / f.size).clamp(0.0, 1.0) : 1.0;
            }
            return <String, dynamic>{
              'name': f.name,
              'length': f.size,
              'selected': existing?['selected'] as bool? ?? f.selected,
              'priority': existing?['priority'] as int? ?? f.priority,
              'downloadedBytes': resolvedBytes,
              'speed': 0.0,
              'progressEstimated': isEstimated,
              'progress': fileProgress,
              'percent': fileProgress,
              'isComplete': f.size == 0 || resolvedBytes >= f.size,
            };
          }).toList();
        } catch (e) {
          debugPrint('[DownloadEngine] getFiles failed: $e');
        }
      }
      if (resolvedFiles == null) {
        resolvedFiles = getTorrentFiles?.call();
        if (resolvedFiles != null) {
          normalizeTorrentFiles(resolvedFiles);
        }
      }
      if (resolvedFiles != null) {
        final activeFiles = resolvedFiles.where((f) {
          if (!isTorrentFileSelected(f)) return false;
          final length = (f['length'] as num?)?.toInt() ?? 0;
          final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
          return length > 0 && dl < length;
        }).toList();
        if (activeFiles.isNotEmpty) {
          final aggregateRate = (stateLabel == 'seeding')
              ? torrent.uploadRate.toDouble()
              : torrent.downloadRate.toDouble();
          final perFileSpeed = aggregateRate / activeFiles.length;
          for (final f in activeFiles) {
            f['speed'] = perFileSpeed;
          }
        }
      }
      int calculatedTotal = 0;
      int calculatedDownloaded = 0;
      if (resolvedFiles != null) {
        for (final f in resolvedFiles) {
          if (isTorrentFileSelected(f)) {
            calculatedTotal += (f['length'] as num?)?.toInt() ?? 0;
            final engineBytes = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
            if (engineBytes >= 0) {
              calculatedDownloaded += engineBytes;
            }
          }
        }
      }
      final totalSize = calculatedTotal > 0
          ? calculatedTotal
          : (torrent.totalWanted > 0
              ? torrent.totalWanted
              : (knownFileSize > 0 ? knownFileSize : 0));
      if (totalSize <= 0 && !torrent.hasMetadata) {
        final fmFiles = getTorrentFiles?.call() ?? resolvedFiles;
        int fmTotal = 0, fmDone = 0, fmBytes = 0, fmDl = 0;
        if (fmFiles != null) {
          for (final f in fmFiles) {
            final len = (f['length'] as num?)?.toInt() ?? 0;
            var dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
            if (len > 0) {
              dl = dl.clamp(0, len);
              f['downloadedBytes'] = dl;
              f['progress'] = (dl / len).clamp(0.0, 1.0);
            } else {
              f['downloadedBytes'] = 0;
              f['progress'] = 1.0;
            }
            if (isTorrentFileSelected(f)) {
              fmTotal++;
              fmBytes += len;
              fmDl += dl;
              if (len == 0 || dl >= len) fmDone++;
            }
          }
        }
        onProgress(DownloadProgress(
          downloadedBytes: fmDl,
          fileSize: fmBytes > 0 ? fmBytes : 0,
          speed: (stateLabel == 'seeding')
              ? torrent.uploadRate.toDouble()
              : torrent.downloadRate.toDouble(),
          eta: null,
          fileName: resolvedName,
          torrentFiles: fmFiles,
          supportsResume: true,
          statusMessage: 'Fetching metadata…',
          cycleState: 'fetching_metadata',
          totalFiles: fmTotal > 0 ? fmTotal : null,
          completedFiles: fmTotal > 0 ? fmDone : null,
          totalFileBytes: fmBytes > 0 ? fmBytes : null,
          downloadedFileBytes: fmBytes > 0 ? fmDl : null,
          torrentId: id,
        ));
        return;
      }
      final int torrentAggregate = torrent.totalWantedDone > 0
          ? torrent.totalWantedDone
          : (torrent.totalDone > 0
              ? torrent.totalDone
              : (torrent.progress > 0 && totalSize > 0
                  ? (torrent.progress * totalSize).round()
                  : 0));
      final int rawDownloaded;
      if (torrentAggregate > 0) {
        rawDownloaded = torrentAggregate;
      } else if (calculatedDownloaded > 0) {
        rawDownloaded = calculatedDownloaded;
      } else {
        rawDownloaded = 0;
      }
      final downloadedBytes = totalSize > 0
          ? rawDownloaded.clamp(0, totalSize)
          : max(0, rawDownloaded);
      if (resolvedFiles != null) {
        _distributeEstimatedBytes(resolvedFiles, downloadedBytes);
        for (final f in resolvedFiles) {
          final len = (f['length'] as num?)?.toInt() ?? 0;
          var dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
          if (len > 0) {
            dl = dl.clamp(0, len);
            f['downloadedBytes'] = dl;
            f['progress'] = (dl / len).clamp(0.0, 1.0);
            if (dl >= len && f['progressEstimated'] == true) {
              f['progressEstimated'] = false;
            }
          } else {
            f['downloadedBytes'] = 0;
            f['progress'] = 1.0;
            f['progressEstimated'] = false;
          }
          final pf = f['progress'];
          if (pf == null || pf is! num || pf.isNaN || pf.isInfinite) {
            f['progress'] = 0.0;
          } else {
            f['progress'] = pf.toDouble().clamp(0.0, 1.0);
          }
        }
        final isPausedState = stateLabel == 'paused' ||
            stateLabel == 'stopped' ||
            stateLabel == 'error';
        if (isPausedState || isCheckingOrMetadata) {
          for (final f in resolvedFiles) {
            f['speed'] = 0.0;
          }
        } else {
          for (final f in resolvedFiles) {
            f['speed'] = 0.0;
          }
          final isSeedingNow = stateLabel == 'seeding';
          final aggregateRate = isSeedingNow
              ? torrent.uploadRate.toDouble()
              : torrent.downloadRate.toDouble();
          if (aggregateRate > 0) {
            if (isSeedingNow) {
              final seedingFiles =
                  resolvedFiles.where((f) => isTorrentFileSelected(f)).length;
              if (seedingFiles > 0) {
                final perFileSpeed = aggregateRate / seedingFiles;
                for (final f in resolvedFiles) {
                  if (isTorrentFileSelected(f)) {
                    f['speed'] = perFileSpeed;
                  }
                }
              }
            } else {
              final activeFileList = resolvedFiles.where((f) {
                final selected = isTorrentFileSelected(f);
                final len = (f['length'] as num?)?.toInt() ?? 0;
                final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
                return selected && len > 0 && dl < len;
              }).toList();
              if (activeFileList.isNotEmpty) {
                final totalRemaining = activeFileList.fold<double>(
                  0.0,
                  (sum, f) {
                    final len = (f['length'] as num?)?.toInt() ?? 0;
                    final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
                    return sum + (len - dl).clamp(0, len);
                  },
                );
                if (totalRemaining > 0) {
                  for (final f in activeFileList) {
                    final len = (f['length'] as num?)?.toInt() ?? 0;
                    final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
                    final remaining = (len - dl).clamp(0, len);
                    f['speed'] =
                        (aggregateRate * remaining / totalRemaining).toDouble();
                  }
                } else {
                  final perFileSpeed = aggregateRate / activeFileList.length;
                  for (final f in activeFileList) {
                    f['speed'] = perFileSpeed.toDouble();
                  }
                }
              }
            }
          }
        }
        final maxConcurrent = _settings.maxConcurrentFilesPerTorrent;
        if (maxConcurrent > 0 && !isCheckingOrMetadata) {
          _applyMaxConcurrentFilesLimit(id, resolvedFiles, maxConcurrent);
        }
      }
      final isUserPaused = stateLabel == 'paused' || stateLabel == 'stopped';
      if (isUserPaused && !cancelToken.isCancelled && !isCheckingOrMetadata) {
        if (totalSize > 0 && downloadedBytes >= totalSize) {
          int cFiles = 0, cDoneFiles = 0, cTotalBytes = 0, cDlBytes = 0;
          if (resolvedFiles != null) {
            for (final f in resolvedFiles) {
              if (isTorrentFileSelected(f)) {
                final len = (f['length'] as num?)?.toInt() ?? 0;
                final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
                cFiles++;
                cTotalBytes += len;
                cDlBytes += dl.clamp(0, len);
                if (len == 0 || dl >= len) cDoneFiles++;
              }
            }
          }
          onProgress(DownloadProgress(
            downloadedBytes: downloadedBytes,
            fileSize: totalSize,
            speed: 0.0,
            eta: null,
            fileName: resolvedName,
            torrentFiles: resolvedFiles,
            supportsResume: true,
            statusMessage: 'Completed',
            cycleState: 'completed',
            totalFiles: cFiles > 0 ? cFiles : null,
            completedFiles: cFiles > 0 ? cDoneFiles : null,
            totalFileBytes: cTotalBytes > 0 ? cTotalBytes : null,
            downloadedFileBytes: cTotalBytes > 0 ? cDlBytes : null,
            torrentId: id,
          ));
          if (!completer.isCompleted) completer.complete();
          return;
        }
        int rFiles = 0, rDoneFiles = 0, rTotalBytes = 0, rDlBytes = 0;
        if (resolvedFiles != null) {
          for (final f in resolvedFiles) {
            if (isTorrentFileSelected(f)) {
              final len = (f['length'] as num?)?.toInt() ?? 0;
              final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
              rFiles++;
              rTotalBytes += len;
              rDlBytes += dl.clamp(0, len);
              if (len == 0 || dl >= len) rDoneFiles++;
            }
          }
        }
        onProgress(DownloadProgress(
          downloadedBytes: downloadedBytes,
          fileSize: totalSize,
          speed: 0.0,
          eta: null,
          fileName: resolvedName,
          torrentFiles: resolvedFiles,
          supportsResume: true,
          statusMessage: 'Paused (engine — retry to resume)',
          cycleState: 'retrying',
          totalFiles: rFiles > 0 ? rFiles : null,
          completedFiles: rFiles > 0 ? rDoneFiles : null,
          totalFileBytes: rTotalBytes > 0 ? rTotalBytes : null,
          downloadedFileBytes: rTotalBytes > 0 ? rDlBytes : null,
          torrentId: id,
        ));
        if (!completer.isCompleted) {
          sub?.cancel();
          TorrentResumeStore.saveAndWait(
            torrentId: id,
            sourceUrl: url,
            fetchResumeData: () => TorrentService.fetchResumeBytes(id),
            files: getTorrentFiles?.call(),
          ).then((_) {
            if (!completer.isCompleted) {
              completer.completeError(TorrentEnginePauseException(
                'Torrent entered paused state without an explicit cancel — '
                'possible I/O error or external pause. Resume data saved; '
                'retry to resume.',
                url: url,
              ));
            }
          }).catchError((e) {
            debugPrint('[DMX] non-cancel-pause resume save failed: $e');
            if (!completer.isCompleted) {
              completer.completeError(TorrentEnginePauseException(
                'Torrent entered paused state without an explicit cancel — '
                'possible I/O error or external pause. Resume data saved; '
                'retry to resume.',
                url: url,
              ));
            }
          });
        }
        return;
      }
      if (stateLabel == 'error' && !completer.isCompleted) {
        final eSummary = normalizeTorrentFiles(resolvedFiles);
        onProgress(DownloadProgress(
          downloadedBytes: downloadedBytes,
          fileSize: totalSize,
          speed: 0.0,
          eta: null,
          fileName: resolvedName,
          torrentFiles: resolvedFiles,
          supportsResume: true,
          statusMessage: 'Torrent entered error state',
          cycleState: 'failed',
          totalFiles: eSummary.total > 0 ? eSummary.total : null,
          completedFiles: eSummary.total > 0 ? eSummary.done : null,
          totalFileBytes: eSummary.bytes > 0 ? eSummary.bytes : null,
          downloadedFileBytes: eSummary.bytes > 0 ? eSummary.downloaded : null,
          torrentId: id,
        ));
        if (!completer.isCompleted) {
          completer.completeError(DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.unknown,
            message: 'Torrent entered error state.',
          ));
        }
        return;
      }
      final isStableFinished = stateLabel == 'seeding' ||
          stateLabel == 'completed' ||
          stateLabel == 'finished';
      final isFullyDownloaded =
          totalSize > 0 ? downloadedBytes >= totalSize : isStableFinished;
      final shouldComplete = isFullyDownloaded && !isCheckingOrMetadata;
      final isSeedingNow = stateLabel == 'seeding';
      final speed = isSeedingNow
          ? torrent.uploadRate.toDouble()
          : torrent.downloadRate.toDouble();
      final remaining =
          totalSize > downloadedBytes ? totalSize - downloadedBytes : 0;
      final eta = speed.isFinite && speed > 0 && remaining > 0
          ? (remaining / speed).round().clamp(0, 86400 * 365)
          : null;
      if (isCheckingOrMetadata) {
        final isMetadataState = stateLabel.contains('metadata');
        final isAllocatingState = stateLabel.contains('allocating');
        final recheckPct = torrent.progress.clamp(0.0, 1.0);
        final checkCycle = isMetadataState
            ? 'fetching_metadata'
            : isAllocatingState
                ? 'starting'
                : 'checking';
        final checkMsg = isMetadataState
            ? 'Fetching metadata…'
            : isAllocatingState
                ? 'Allocating disk space…'
                : 'Checking pieces… ${(recheckPct * 100).toInt()}%';
        int tFiles = 0, dFiles = 0, tBytes = 0, dBytes = 0;
        if (resolvedFiles != null) {
          for (final f in resolvedFiles) {
            final sel = isTorrentFileSelected(f);
            final len = (f['length'] as num?)?.toInt() ?? 0;
            final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
            if (sel) {
              tFiles++;
              tBytes += len;
              dBytes += dl.clamp(0, len);
              if (len == 0 || dl >= len) dFiles++;
            }
          }
        }
        onProgress(DownloadProgress(
          downloadedBytes: downloadedBytes,
          fileSize: totalSize,
          speed: 0.0,
          eta: null,
          fileName: resolvedName,
          torrentFiles: resolvedFiles,
          supportsResume: true,
          statusMessage: checkMsg,
          cycleState: checkCycle,
          totalFiles: tFiles > 0 ? tFiles : null,
          completedFiles: tFiles > 0 ? dFiles : null,
          totalFileBytes: tBytes > 0 ? tBytes : null,
          downloadedFileBytes: tBytes > 0 ? dBytes : null,
          torrentId: id,
        ));
      } else {
        int tFiles = 0, dFiles = 0, tBytes = 0, dBytes = 0;
        if (resolvedFiles != null) {
          for (final f in resolvedFiles) {
            final sel = isTorrentFileSelected(f);
            final len = (f['length'] as num?)?.toInt() ?? 0;
            final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
            if (sel) {
              tFiles++;
              tBytes += len;
              dBytes += dl.clamp(0, len);
              if (len == 0 || dl >= len) dFiles++;
            }
          }
        }
        final torCycle = shouldComplete
            ? 'completed'
            : stateLabel == 'seeding'
                ? 'seeding'
                : stateLabel == 'paused' || stateLabel == 'stopped'
                    ? 'paused'
                    : stateLabel == 'downloading' ||
                            stateLabel.contains('stalled')
                        ? 'downloading'
                        : stateLabel == 'error'
                            ? 'failed'
                            : stateLabel == 'finished' ||
                                    stateLabel == 'completed'
                                ? 'completed'
                                : stateLabel == 'queued' ||
                                        stateLabel == 'allocating'
                                    ? 'starting'
                                    : 'downloading';
        onProgress(DownloadProgress(
          downloadedBytes: downloadedBytes,
          fileSize: totalSize,
          speed: speed,
          eta: eta,
          fileName: resolvedName,
          torrentFiles: resolvedFiles,
          supportsResume: true,
          cycleState: torCycle,
          statusMessage: torCycle == 'seeding'
              ? 'Seeding'
              : torCycle == 'downloading'
                  ? 'Downloading'
                  : torCycle == 'paused'
                      ? 'Paused'
                      : torCycle == 'completed'
                          ? 'Completed'
                          : 'Processing…',
          totalFiles: tFiles > 0 ? tFiles : null,
          completedFiles: tFiles > 0 ? dFiles : null,
          totalFileBytes: tBytes > 0 ? tBytes : null,
          downloadedFileBytes: tBytes > 0 ? dBytes : null,
          torrentId: id,
        ));
      }
      if (shouldComplete && !completer.isCompleted) completer.complete();
    });
    cancelToken.whenCancel.then((_) async {
      if (completer.isCompleted) return;
      await sub?.cancel();
      try {
        TorrentService.pauseTorrent(id);
      } catch (_) {}
      try {
        await TorrentResumeStore.saveAndWait(
          torrentId: id,
          sourceUrl: url,
          fetchResumeData: () => TorrentService.fetchResumeBytes(id),
          files: getTorrentFiles?.call(),
        );
      } catch (e) {
        debugPrint('[DMX] cancel-time resume save failed: $e');
      }
      if (!completer.isCompleted) {
        completer.completeError(DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel,
          message: 'Torrent download cancelled by user.',
        ));
      }
    });
    try {
      await completer.future;
    } finally {
      await sub.cancel();
    }
  }

  static final Map<int, DateTime> _lastConcurrentLimitApply = {};
  static final Map<int, Set<int>> _lastIncompleteSnapshot = {};
  static const Duration _concurrentLimitThrottle = Duration(seconds: 5);
  static void _applyMaxConcurrentFilesLimit(
    int torrentId,
    List<Map<String, dynamic>> files,
    int maxConcurrentFiles,
  ) {
    if (maxConcurrentFiles <= 0) return;
    final sortedIndices = List.generate(files.length, (i) => i)
      ..sort((a, b) {
        final pa = (files[a]['priority'] as int?) ?? 4;
        final pb = (files[b]['priority'] as int?) ?? 4;
        if (pa != pb) return pb.compareTo(pa);
        return a.compareTo(b);
      });
    final incompleteSelected = <int>[];
    final incompleteSet = <int>{};
    for (final idx in sortedIndices) {
      final f = files[idx];
      final selected = isTorrentFileSelected(f);
      final length = (f['length'] as num?)?.toInt() ?? 0;
      final downloaded = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      if (selected && (length == 0 || downloaded < length)) {
        incompleteSelected.add(idx);
        incompleteSet.add(idx);
      }
    }
    final now = DateTime.now();
    final lastApply = _lastConcurrentLimitApply[torrentId];
    final prev = _lastIncompleteSnapshot[torrentId];
    var fileCompleted = false;
    if (prev != null) {
      for (final idx in prev) {
        if (!incompleteSet.contains(idx)) {
          fileCompleted = true;
          break;
        }
      }
    }
    if (!fileCompleted &&
        lastApply != null &&
        now.difference(lastApply) < _concurrentLimitThrottle) {
      return;
    }
    final priorities = List<int>.generate(files.length, (i) {
      final f = files[i];
      final selected = isTorrentFileSelected(f);
      if (!selected) return 0;
      return (f['priority'] as int?) ?? 4;
    });
    for (var i = 0; i < incompleteSelected.length; i++) {
      final idx = incompleteSelected[i];
      if (i >= maxConcurrentFiles) {
        priorities[idx] = 0;
      } else {
        priorities[idx] = (files[idx]['priority'] as int?) ?? 4;
      }
    }
    _lastConcurrentLimitApply[torrentId] = now;
    _lastIncompleteSnapshot[torrentId] = incompleteSet;
    TorrentService.setFilePriorities(torrentId, priorities);
  }

  static void normalizeTorrentFile(Map<String, dynamic> f) {
    final len = (f['length'] as num?)?.toInt() ?? 0;
    var dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
    if (len > 0) {
      dl = dl.clamp(0, len);
      f['downloadedBytes'] = dl;
      f['progress'] = (dl / len).clamp(0.0, 1.0);
    } else {
      f['downloadedBytes'] = 0;
      f['progress'] = 1.0;
    }
    final pf = f['progress'];
    if (pf == null || pf is! num || pf.isNaN || pf.isInfinite) {
      f['progress'] = 0.0;
    } else {
      f['progress'] = pf.toDouble().clamp(0.0, 1.0);
    }
  }

  static ({int total, int done, int bytes, int downloaded})
      normalizeTorrentFiles(
    List<Map<String, dynamic>>? files,
  ) {
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

  static void _distributeEstimatedBytes(
      List<Map<String, dynamic>> files, int totalDownloadedBytes) {
    final needing = files
        .where((f) => (f['progressEstimated'] as bool? ?? true) == true)
        .toList();
    if (needing.isEmpty) return;
    int confirmedBytes = 0;
    for (final f in files) {
      if ((f['progressEstimated'] as bool? ?? true) == false) {
        confirmedBytes += (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      }
    }
    final remainingForEstimation =
        max(0, totalDownloadedBytes - confirmedBytes);
    final totalNeedingSize = needing.fold<int>(
        0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0));
    for (var i = 0; i < needing.length; i++) {
      final length = (needing[i]['length'] as num?)?.toInt() ?? 0;
      if (length <= 0) {
        needing[i]['downloadedBytes'] = 0;
      } else if (totalNeedingSize > 0 && remainingForEstimation > 0) {
        final estimated =
            ((length / totalNeedingSize) * remainingForEstimation).round();
        needing[i]['downloadedBytes'] = estimated.clamp(0, length);
      } else {
        final prev = (needing[i]['downloadedBytes'] as num?)?.toInt() ?? 0;
        needing[i]['downloadedBytes'] = prev.clamp(0, length);
      }
      needing[i]['progressEstimated'] = true;
    }
  }

  Future<void> _waitForState(
    int id,
    CancelToken cancelToken, {
    required bool Function(String) predicate,
    required Duration timeout,
    ValueChangedProgress? onProgress,
    int knownFileSize = 0,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
  }) async {
    final completer = Completer<void>();
    StreamSubscription? sub;
    Timer? t;
    Timer? heartbeat;
    String? lastSeen;
    var elapsed = 0;
    int lastCheckedBytes = 0;
    int lastCheckedTotal = 0;
    sub = TorrentService.torrentUpdates.listen((torrents) {
      final tor = torrents[id];
      if (tor != null) {
        lastSeen = tor.stateLabel;
        if (tor.stateLabel.toLowerCase().contains('checking')) {
          final sz = tor.totalWanted > 0 ? tor.totalWanted : knownFileSize;
          lastCheckedTotal = sz;
          lastCheckedBytes = (tor.progress.clamp(0.0, 1.0) * sz).round();
        }
        if (onProgress != null && !completer.isCompleted) {
          final label = tor.stateLabel.toLowerCase();
          if (label.contains('checking')) {
            final recheckPct = tor.progress.clamp(0.0, 1.0);
            final rcFiles = getTorrentFiles?.call();
            int rcTotal = 0, rcDone = 0, rcBytes = 0, rcDl = 0;
            if (rcFiles != null) {
              for (final f in rcFiles) {
                final len = (f['length'] as num?)?.toInt() ?? 0;
                var dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
                if (len > 0) {
                  dl = dl.clamp(0, len);
                  f['downloadedBytes'] = dl;
                  f['progress'] = (dl / len).clamp(0.0, 1.0);
                } else {
                  f['downloadedBytes'] = 0;
                  f['progress'] = 1.0;
                }
                if (isTorrentFileSelected(f)) {
                  rcTotal++;
                  rcBytes += len;
                  rcDl += dl;
                  if (len == 0 || dl >= len) rcDone++;
                }
              }
            }
            onProgress(DownloadProgress(
              downloadedBytes: (recheckPct *
                      (tor.totalWanted > 0 ? tor.totalWanted : knownFileSize))
                  .round(),
              fileSize: tor.totalWanted > 0 ? tor.totalWanted : knownFileSize,
              speed: 0.0,
              eta: null,
              statusMessage: 'Checking pieces… ${(recheckPct * 100).toInt()}%',
              cycleState: 'checking',
              torrentFiles: rcFiles,
              totalFiles: rcTotal > 0 ? rcTotal : null,
              completedFiles: rcTotal > 0 ? rcDone : null,
              totalFileBytes: rcBytes > 0 ? rcBytes : null,
              downloadedFileBytes: rcBytes > 0 ? rcDl : null,
              torrentId: id,
            ));
          }
        }
        if (predicate(tor.stateLabel.toLowerCase()) && !completer.isCompleted) {
          completer.complete();
        }
      }
    });
    if (onProgress != null) {
      heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
        if (completer.isCompleted) return;
        elapsed += 5;
        final lowerSeen = lastSeen?.toLowerCase() ?? '';
        final isChecking = lowerSeen.contains('checking');
        final isMetadata = lowerSeen.contains('metadata');
        final isAllocating = lowerSeen.contains('allocating');
        final hbCycle = isChecking
            ? 'checking'
            : isMetadata
                ? 'fetching_metadata'
                : isAllocating
                    ? 'starting'
                    : 'starting';
        final hbMsg = isChecking
            ? 'Verifying downloaded data… (${elapsed}s)'
            : isMetadata
                ? 'Fetching metadata… (${elapsed}s)'
                : isAllocating
                    ? 'Allocating disk space… (${elapsed}s)'
                    : 'Preparing… (${elapsed}s)';
        final hbFiles = getTorrentFiles?.call();
        int hbTotal = 0, hbDone = 0, hbBytes = 0, hbDl = 0;
        if (hbFiles != null) {
          for (final f in hbFiles) {
            final len = (f['length'] as num?)?.toInt() ?? 0;
            var dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
            if (len > 0) {
              dl = dl.clamp(0, len);
              f['downloadedBytes'] = dl;
              f['progress'] = (dl / len).clamp(0.0, 1.0);
            } else {
              f['downloadedBytes'] = 0;
              f['progress'] = 1.0;
            }
            if (isTorrentFileSelected(f)) {
              hbTotal++;
              hbBytes += len;
              hbDl += dl;
              if (len == 0 || dl >= len) hbDone++;
            }
          }
        }
        onProgress(DownloadProgress(
          downloadedBytes: isChecking ? lastCheckedBytes : hbDl,
          fileSize: lastCheckedTotal > 0
              ? lastCheckedTotal
              : (knownFileSize > 0 ? knownFileSize : hbBytes),
          speed: 0.0,
          eta: null,
          statusMessage: hbMsg,
          cycleState: hbCycle,
          torrentFiles: hbFiles,
          totalFiles: hbTotal > 0 ? hbTotal : null,
          completedFiles: hbTotal > 0 ? hbDone : null,
          totalFileBytes: hbBytes > 0 ? hbBytes : null,
          downloadedFileBytes: hbBytes > 0 ? hbDl : null,
        ));
      });
    }
    t = Timer(timeout, () {
      if (completer.isCompleted) return;
      try {
        TorrentService.pauseTorrent(id);
      } catch (_) {}
      completer.completeError(DioException(
        requestOptions: RequestOptions(path: 'torrent:$id'),
        type: DioExceptionType.receiveTimeout,
        message:
            'Torrent state check timed out (last: "$lastSeen"). Download paused for safety.',
      ));
    });
    cancelToken.whenCancel.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(DioException(
          requestOptions: RequestOptions(path: 'torrent:$id'),
          type: DioExceptionType.cancel,
          error: 'cancelled',
        ));
      }
    });
    try {
      await completer.future;
    } finally {
      t.cancel();
      heartbeat?.cancel();
      await sub.cancel();
    }
  }

  final Lock _closeLock = Lock();

  Future<void> close() async {
    await _closeLock.synchronized(() async {
      if (_closing) return;
      _closing = true;
      _closed = true;

      _cleanupTimer?.cancel();
      _cleanupTimer = null;
      _ytPeriodicTimer?.cancel();
      _ytPeriodicTimer = null;

      for (final timer in _ytCleanupTimers) {
        timer.cancel();
      }
      _ytCleanupTimers.clear();

      for (final token in List<CancelToken>.from(_activeCancelTokens.values)) {
        try {
          token.cancel('Engine closing');
        } catch (_) {}
      }
      _activeCancelTokens.clear();

      try {
        _sharedDio.close(force: true);
      } catch (_) {}

      for (final client in List<Dio>.from(_activeDioClients)) {
        try {
          client.close(force: true);
        } catch (_) {}
      }
      _activeDioClients.clear();
      _reservedDioClients.clear();
      _dioClientCreationTimes.clear();
      _activeDownloadsPerClient.clear();

      final poolToClose = _pool;
      _pool = null;
      _poolInit = null;
      if (poolToClose != null) {
        try {
          await poolToClose.shutdown().timeout(const Duration(seconds: 10));
        } catch (e) {
          debugPrint('[DownloadEngine] Pool shutdown timeout: $e');
        }
      }

      for (final id in List<int>.from(_activeTorrentIds)) {
        try {
          TorrentService.pauseTorrent(id);
        } catch (_) {}
      }

      _httpEngine.stopAdaptiveThreadMonitor();
    });
  }

  static String _deriveCycleState(
    String? statusMessage,
    bool isCancelled,
    bool isTorrent,
  ) {
    if (isCancelled) return 'paused';
    if (statusMessage == null) return 'downloading';
    final lower = statusMessage.toLowerCase();
    if (lower.contains('completed')) return 'completed';
    if (lower.contains('checking') || lower.contains('verifying')) {
      return 'checking';
    }
    if (lower.contains('fetching metadata')) return 'fetching_metadata';
    if (lower.contains('paused') && lower.contains('engine')) return 'retrying';
    if (lower.contains('paused')) return 'paused';
    if (lower.contains('updating') || lower.contains('refresh')) {
      return 'updating_links';
    }
    if (lower.contains('retry')) return 'retrying';
    if (lower.contains('failed') || lower.contains('error')) return 'failed';
    if (lower.contains('seeding')) return 'seeding';
    if (lower.contains('resum')) {
      return 'resuming';
    }
    if (lower.contains('starting') ||
        lower.contains('allocating') ||
        lower.contains('preparing')) {
      return 'starting';
    }
    return 'downloading';
  }
}

Dio buildTransferDio({
  String? url,
  String? customUserAgent,
  String? referer,
  String? cookies,
  String? oauthToken,
}) {
  final client = Dio();
  client.interceptors.add(ProfessionalRetryInterceptor(client));
  client.options.connectTimeout = const Duration(seconds: 30);
  client.options.sendTimeout = const Duration(seconds: 60);
  client.options.receiveTimeout = const Duration(seconds: 60);
  final uri = url != null ? Uri.tryParse(url) : null;
  final host = uri?.host.toLowerCase() ?? '';
  final isYoutubeUrl = host.contains('youtube.com') ||
      host == 'youtu.be' ||
      host.endsWith('.googlevideo.com');
  if (isYoutubeUrl) {
    client.options.headers['Origin'] = 'https://www.youtube.com';
    client.options.headers['Referer'] = (referer != null && referer.isNotEmpty)
        ? referer
        : 'https://www.youtube.com/';
    client.options.headers['User-Agent'] =
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';
    client.options.headers['Accept'] = '*/*';
    client.options.headers['Accept-Language'] = 'en-US,en;q=0.9';
    if (oauthToken != null && oauthToken.isNotEmpty) {
      client.options.headers['Authorization'] = 'Bearer $oauthToken';
    }
  } else if (customUserAgent != null && customUserAgent.trim().isNotEmpty) {
    client.options.headers['User-Agent'] = customUserAgent.trim();
  } else {
    client.options.headers['User-Agent'] =
        'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
  }
  if (referer != null &&
      referer.isNotEmpty &&
      !client.options.headers.containsKey('Referer')) {
    client.options.headers['Referer'] = referer;
  }
  if (cookies != null && cookies.isNotEmpty) {
    client.options.headers['Cookie'] = cookies;
  }
  if (client.httpClientAdapter is IOHttpClientAdapter) {
    final adapter = client.httpClientAdapter as IOHttpClientAdapter;
    adapter.createHttpClient = () {
      final httpClient = HttpClient();
      // In RELEASE: Reject all invalid certs (strict)
      httpClient.badCertificateCallback = (cert, host, port) {
        return false; // Strict: reject all invalid certs
      };

      // In DEBUG: Allow backend hosts for development
      assert(() {
        httpClient.badCertificateCallback = (cert, host, port) {
          final targetHost = url != null ? Uri.tryParse(url)?.host : null;
          if (targetHost != null && host.contains(targetHost)) {
            return true;
          }
          return false;
        };
        return true;
      }());
      return httpClient;
    };
  }
  return client;
}

Future<int> actualDownloadedBytes(
  String path, {
  required int threadCount,
}) async {
  try {
    final stateFile = File('$path.dmxstate');
    if (await stateFile.exists()) {
      final content = await stateFile.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is Map && decoded['chunks'] is List) {
        final chunks = decoded['chunks'] as List;
        return chunks.fold<int>(
          0,
          (s, c) =>
              s + ((c is Map ? (c['downloaded'] as num?)?.toInt() : 0) ?? 0),
        );
      }
      if (decoded is Map && decoded['progress'] is List) {
        final progress = decoded['progress'] as List;
        return progress.fold<int>(
          0,
          (s, c) => s + ((c is num) ? c.toInt() : 0),
        );
      }
    }

    // Check journal if .dmxstate was absent or did not contain valid chunks
    final journalPath = '$path.journal';
    if (await File(journalPath).exists()) {
      final journalBytes = await DownloadJournal.recover(journalPath);
      if (journalBytes != null && journalBytes.isNotEmpty) {
        return journalBytes.fold<int>(0, (s, b) => s + (b < 0 ? 0 : b));
      }
    }

    // For single-threaded downloads without state, file length represents actual downloaded bytes.
    // For multi-threaded downloads, the file may have been pre-allocated to full size, so we return 0.
    if (threadCount <= 1) {
      final f = File(path);
      if (await f.exists()) {
        final len = await f.length();
        if (len > 0) return len;
      }
    }
    return 0;
  } catch (e) {
    debugPrint('[DMX] actualDownloadedBytes failed for $path: $e');
    if (threadCount <= 1) {
      final f = File(path);
      if (await f.exists()) return await f.length();
    }
    return 0;
  }
}

String _redactUrl(String? url) {
  if (url == null || url.isEmpty) return '<empty>';
  final uri = Uri.tryParse(url);
  if (uri == null) return '<invalid-url>';
  final host = uri.host.isEmpty ? '<host>' : uri.host;
  final port = uri.hasPort ? ':${uri.port}' : '';
  final redactedPath = uri.path
      .split('/')
      .map((s) => _looksLikePathToken(s) ? '<redacted>' : s)
      .join('/');
  return '${uri.scheme.isEmpty ? 'https' : uri.scheme}://$host$port'
      '$redactedPath${uri.hasQuery ? '?<redacted>' : ''}';
}

bool _looksLikePathToken(String segment) {
  if (segment.isEmpty || segment.length < 24) return false;
  if (!RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(segment)) return false;
  return segment.contains(RegExp(r'[0-9]'));
}

String? _firstNonEmpty(String? a, String? b) {
  if (a != null && a.trim().isNotEmpty) return a;
  if (b != null && b.trim().isNotEmpty) return b;
  return null;
}

class _DiskSpaceInfo {
  final int freeBytes;
  const _DiskSpaceInfo({required this.freeBytes});
}
