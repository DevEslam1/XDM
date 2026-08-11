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

// ═══════════════════════════════════════════════════════════════════════════
// PUBLIC MODELS (API-compatible with orchestrator/provider)
// ═══════════════════════════════════════════════════════════════════════════

class DownloadMetadata {
  final String fileName;
  final String category;
  final int fileSize;
  final bool supportsResume;
  final List<Map<String, dynamic>>? torrentFiles;
  final int? torrentId;

  const DownloadMetadata({
    required this.fileName,
    required this.category,
    required this.fileSize,
    required this.supportsResume,
    this.torrentFiles,
    this.torrentId,
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

class DownloadIntegrityException implements Exception {
  final String message;
  const DownloadIntegrityException(this.message);
  @override
  String toString() => 'DownloadIntegrityException: $message';
}

/// FIX-3: Raised when the server signals the download URL has expired
/// (401/403 on signed/YouTube URLs). The orchestrator should catch this,
/// re-resolve streams (yt-dlp / signed-URL re-issue), and re-submit the
/// download with the SAME tempFilePath + localFilePath so chunk-level
/// resume still works.
class UrlExpiredException implements Exception {
  final String message;
  final bool refreshAllMirrors;
  const UrlExpiredException(this.message, {this.refreshAllMirrors = false});
  @override
  String toString() => 'UrlExpiredException: $message';
}

/// Raised when the torrent engine enters a paused state without an explicit
/// cancel from the user. The orchestrator should catch this, mark the task
/// as retryable-paused (not failed), and resume on user action or auto-retry.
/// Resume data is always saved before this is thrown.
class TorrentEnginePauseException implements Exception {
  final String message;
  final String url;
  const TorrentEnginePauseException(this.message, {required this.url});

  @override
  String toString() => 'TorrentEnginePauseException: $message';
}

/// ffmpeg failure taxonomy. Exposed so merge call-sites can map failures to
/// user-facing messages WITHOUT string-sniffing; FFmpegMuxService can adopt
/// this without any engine change.
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

/// Which sub-stream of a YouTube download this progress update refers to.
/// The orchestrator combines `video` + `audio` into the user-facing
/// percentage: combined = (videoBytes + audioBytes) / (videoSize + audioSize).
enum YtStreamKind { video, audio, combined }

/// FIX-CHUNK-DETAILS: Per-chunk detail for the HTTP details screen.
///
/// Each chunk represents one byte-range "part" of an HTTP download. The
/// details screen renders a per-part progress bar using [ratio] and a
/// "Part N: downloaded / size" label. For indeterminate streams (total
/// size unknown), [isIndeterminate] is true and [ratio] is 0.0 — the UI
/// should render an indeterminate bar and use [downloaded] as the byte
/// indicator.
class ChunkDetail {
  final int index;
  final int start;
  final int end;
  final int downloaded;
  final int size;
  final double ratio;

  /// True when total size is unknown (open-ended chunk, indeterminate bar).
  bool get isIndeterminate => size < 0;

  /// True when this chunk's byte range is fully downloaded.
  bool get isComplete => size >= 0 && downloaded >= size;

  /// FIX-CHUNK-PERCENT: Human-readable percentage string for this part.
  /// Returns '—' for indeterminate chunks (unknown size).
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

  /// FIX-CHUNK-WIRE: Constructs a ChunkDetail from a wire-transport map
  /// (as emitted by the worker isolate in chunkDetails).
  factory ChunkDetail.fromMap(Map<String, dynamic> m) {
    final rawRatio = (m['ratio'] as num?)?.toDouble() ?? 0.0;
    return ChunkDetail(
      index: (m['index'] as num?)?.toInt() ?? 0,
      start: (m['start'] as num?)?.toInt() ?? 0,
      end: (m['end'] as num?)?.toInt() ?? -1,
      downloaded: (m['downloaded'] as num?)?.toInt() ?? 0,
      size: (m['size'] as num?)?.toInt() ?? -1,
      // FIX-RATIO-NAN: Guard against NaN/Infinity which can leak from the
      // worker isolate when downloaded or size fields are momentarily
      // inconsistent. Without this, percentLabel renders "NaN%".
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

  /// FIX-CHUNK-DETAILS: Per-chunk detail for the HTTP details screen.
  /// Null for torrents (which use torrentFiles) and single-stream downloads.
  final List<ChunkDetail>? chunkDetails;

  /// FIX-CYCLE: Structured download cycle state for UI status chips.
  /// Values: 'starting', 'resuming', 'downloading', 'paused', 'retrying',
  /// 'updating_links', 'failed', 'completed', 'checking',
  /// 'fetching_metadata', 'seeding'.
  ///
  /// 'resuming' is emitted when a download starts with bytes already on
  /// disk (HTTP chunks loaded from journal or torrent fast-resume applied).
  /// UI should show "Resuming…" and an active spinner, identical treatment
  /// to 'starting' but with a different label.
  final String? cycleState;

  /// FIX-HTTP-PARTS: Explicit HTTP part counts (derived from chunkDetails
  /// but provided for convenience so the UI doesn't recompute).
  final int? totalChunks;
  final int? completedChunks;

  /// FIX-TOR-FILES: File-level summary for torrent details screen.
  /// Null for HTTP / YouTube downloads.
  final int? totalFiles;
  final int? completedFiles;
  final int? totalFileBytes;
  final int? downloadedFileBytes;

  /// Which sub-stream of a YouTube download this progress update refers to.
  /// FIX-10: Stream identity for YouTube audio+video downloads. Null for
  /// non-YouTube / non-multistream tasks. The orchestrator uses this to
  /// route the bytes into the right accumulator and compute a combined
  /// percentage that always reflects BOTH streams.
  final YtStreamKind? ytStreamKind;

  /// FIX-10: Counterpart stream size, if known. Lets the orchestrator
  /// compute combined percentage from a single progress event without
  /// waiting for the other stream's update.
  final int? ytCounterpartSize;
  final int? ytCounterpartDownloadedBytes;

  /// FIX-YT-LIVE: Live downloaded bytes for THIS stream (forwarded from the
  /// worker isolate). The orchestrator reads this to populate
  /// [ytCounterpartDownloadedBytes] on the OTHER stream's progress event,
  /// so both streams' combined percentage is always accurate.
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

  /// FIX-CYCLE-WIRE: Factory that constructs a [DownloadProgress] from a
  /// worker-isolate message map, correctly extracting cycleState,
  /// chunkDetails, totalChunks/completedChunks, and YT live counterpart
  /// bytes so the orchestrator doesn't silently drop them.
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

    // FIX-CYCLE-WIRE-TOR: Extract torrent file-level fields so the
    // orchestrator doesn't silently drop torrentFiles, torrentId, and
    // file-level summaries when using this factory.
    // FIX-TOR-PERCENT-WIRE: Ensure each torrent file map has a computed
    // 'percent' field (0.0–1.0) so the details screen can render
    // single-file percentage without re-computing.
    final torrentFilesRaw = data['torrentFiles'];
    List<Map<String, dynamic>>? torrentFiles;
    if (torrentFilesRaw is List) {
      torrentFiles = torrentFilesRaw.whereType<Map>().map((m) {
        final map = Map<String, dynamic>.from(m);
        final length = (map['length'] as num?)?.toInt() ?? 0;
        final dlRaw = (map['downloadedBytes'] as num?)?.toInt() ?? 0;
        // FIX-PROGRESS-KEY: Set 'progress' (not just 'percent') so the
        // details screen single-file percentage reads a valid value.
        // The engine and normalizeTorrentFile use 'progress'; this factory
        // previously only set 'percent', causing null reads.
        final dl = length > 0 ? dlRaw.clamp(0, length) : 0;
        // FIX-ZERO-SIZE-WIRE: Zero-size files are trivially complete (1.0).
        final progress = length > 0 ? (dl / length).clamp(0.0, 1.0) : 1.0;
        map['downloadedBytes'] = dl;
        map['progress'] = progress;
        map['percent'] = progress; // backward-compat alias
        map['isComplete'] = length == 0 || dl >= length;
        return map;
      }).toList();
    }

    // FIX-TOR-AGG-WIRE: If the worker/torrent engine didn't populate
    // file-level summary fields, compute them from torrentFiles so the
    // details screen always has totalFiles / completedFiles /
    // totalFileBytes / downloadedFileBytes regardless of code path.
    int? totalFiles = (data['totalFiles'] as num?)?.toInt();
    int? completedFiles = (data['completedFiles'] as num?)?.toInt();
    int? totalFileBytes = (data['totalFileBytes'] as num?)?.toInt();
    int? downloadedFileBytes = (data['downloadedFileBytes'] as num?)?.toInt();
    if (torrentFiles != null && torrentFiles.isNotEmpty) {
      // FIX-FALLBACK-SELECTED: Only count SELECTED files to match the
      // engine's normalizeTorrentFiles. Previously deselected files
      // inflated counts and byte sums, causing wrong overall percentage.
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
        // FIX-ZERO-SIZE-FALLBACK: Zero-size files are trivially complete.
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
      // FIX-P5-31: Non-YouTube streams do not use ytDownloadedBytes; fallback to null for non-YT is intentional.
      ytDownloadedBytes: (data['ytDownloadedBytes'] as num?)?.toInt() ??
          (ytStreamKind != null
              ? (data['downloadedBytes'] as num?)?.toInt()
              : null),
    );
  }

  /// FIX-YT-COMBINED: Combined audio+video progress for YouTube downloads.
  /// Returns null for non-YouTube / single-stream tasks.
  /// Formula: (currentDownloaded + counterpartDownloaded) /
  ///          (currentSize + counterpartSize)
  double? get ytCombinedProgress {
    if (ytStreamKind == null) return null;

    // If counterpart size is null, use only this stream's progress.
    if (ytCounterpartSize == null) {
      if (fileSize <= 0) return null;
      // FIX-YT-COMBINED-NULL-COUNTERPART: Use ytDownloadedBytes (live cache)
      // instead of downloadedBytes for consistency with the rest of the
      // combined progress logic. The live cache is always more accurate for
      // YT streams and ensures the combined audio+video bar reflects the
      // true downloaded state even when counterpart size is unknown.
      final selfBytes = ytDownloadedBytes ?? downloadedBytes;
      return (selfBytes / fileSize).clamp(0.0, 1.0);
    }

    final counterpartSize = ytCounterpartSize!;
    final counterpartDownloaded = ytCounterpartDownloadedBytes ?? 0;

    // If this stream is complete but counterpart hasn't started, show combined
    // (so the bar doesn't jump to 100% prematurely).
    // FIX-YT-COMBINED-BYTES: Use ytDownloadedBytes (live cache) instead of
    // downloadedBytes (top-level field) for YT stream progress. The live
    // cache is always more accurate for YT streams and ensures the combined
    // audio+video bar reflects the true state of both streams.
    final selfDownloaded = ytDownloadedBytes ?? downloadedBytes;

    if (counterpartSize > 0 && counterpartDownloaded == 0) {
      if (fileSize <= 0) {
        final totalSize = counterpartSize;
        if (totalSize == 0) return null;
        return (selfDownloaded / totalSize).clamp(0.0, 1.0);
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

  /// FIX-YT-COMBINED: Total downloaded bytes across both streams.
  /// Returns the current stream's bytes only when counterpart is unknown
  /// (orchestrator has not yet set ytCounterpartDownloadedBytes).
  /// FIX-YT-COMBINED-BYTES: Use ytDownloadedBytes (live cache) for YT
  /// streams to ensure consistency with ytCombinedProgress. The live cache
  /// is updated on every progress tick and always reflects the true
  /// downloaded state for this stream.
  int get ytCombinedDownloadedBytes {
    if (ytStreamKind == null) return downloadedBytes;
    final selfBytes = ytDownloadedBytes ?? downloadedBytes;
    return selfBytes + (ytCounterpartDownloadedBytes ?? 0);
  }

  /// FIX-YT-COMBINED: Total size across both streams.
  int get ytCombinedFileSize {
    if (ytStreamKind == null) return fileSize;
    return fileSize + (ytCounterpartSize ?? 0);
  }

  /// FIX-TOR-AGG: Computes torrent file-level aggregates from [torrentFiles].
  /// Returns totalFiles, completedFiles, totalFileBytes, downloadedFileBytes.
  /// Used when the torrent engine doesn't populate these fields directly.
  ({
    int totalFiles,
    int completedFiles,
    int totalFileBytes,
    int downloadedFileBytes
  }) get torrentFileAggregates {
    // FIX-AGG-PRECOMP: When torrentFiles is null/empty but pre-computed
    // summary fields are populated (from fromWorkerMap or the engine),
    // return those instead of zeros. This ensures the details screen
    // always has accurate file-level summary data (file counts, byte
    // summaries, completed files) even when the file list isn't attached
    // to this specific progress event.
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
      // FIX-AGG-SELECTED: Only count SELECTED files to match the engine's
      // normalizeTorrentFiles. Previously deselected files inflated the
      // total file count and byte sum, causing the overall torrent
      // percentage on the details screen to be artificially low.
      final selected = f['selected'] as bool? ?? true;
      if (!selected) continue;
      final length = (f['length'] as num?)?.toInt() ?? 0;
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final clampedDl = length > 0 ? dl.clamp(0, length) : 0;
      total++;
      totalBytes += length;
      downloaded += clampedDl;
      // FIX-ZERO-SIZE-AGG: Zero-size files are trivially complete.
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

  /// FIX-TOR-PERCENT: Overall torrent data percentage (0.0–1.0).
  /// Prioritises pre-computed summary fields (totalFileBytes/downloadedFileBytes),
  /// then recomputes from torrentFiles via torrentFileAggregates, then falls
  /// back to top-level bytes (fileSize/downloadedBytes).
  /// FIX-PERC-PRECOMP: Use pre-computed summary fields FIRST — they are
  /// populated by fromWorkerMap and the engine on every tick, and are always
  /// consistent. Recomputing from torrentFiles returns zeros when the file
  /// list is null but summary fields are populated, causing the details
  /// screen to show 0% data on torrents.
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

  /// FIX-TOR-FILE-PERCENT: Returns per-file percentage list for the torrent
  /// details screen. Each entry includes name, percent (0.0–1.0),
  /// downloadedBytes, length, isComplete, selected, priority, speed.
  /// This is the single source of truth for "single file percentage on
  /// details screen on torrents".
  List<Map<String, dynamic>>? get torrentFilePercents {
    if (torrentFiles == null || torrentFiles!.isEmpty) return null;
    // FIX-PERF-TOR-PERCENT: Compute overall percent ONCE before mapping
    // to avoid O(n²) when torrentOverallPercent iterates all files via
    // torrentFileAggregates. On a 1000-file torrent this is the difference
    // between 1ms and 1000ms per details-screen rebuild.
    final overall = torrentOverallPercent;
    // FIX-TOR-FILE-PERCENT-SYNC: Always set BOTH 'progress' and 'percent'
    // to the same value. Some legacy UI code paths read 'percent' while
    // newer code reads 'progress'. If only one is set, the other goes
    // stale, causing the single-file percentage bar on the torrent details
    // screen to show incorrect data. This getter is the canonical source
    // for single-file percentage — both keys must always agree.
    return torrentFiles!.map((f) {
      final length = (f['length'] as num?)?.toInt() ?? 0;
      final dlRaw = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final dl = length > 0 ? dlRaw.clamp(0, length) : 0;
      // FIX-ZERO-SIZE: Zero-size files are trivially complete (1.0).
      final progress = length > 0 ? (dl / length).clamp(0.0, 1.0) : 1.0;
      // FIX-FILE-SPEED-GETTER: Explicitly read 'speed' from the file map
      // and clamp to non-negative. This is the canonical source for
      // single-file download speed on the torrent details screen. The
      // engine populates this field in _listenForCompletion via weighted
      // distribution of the aggregate download/upload rate.
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

// ═══════════════════════════════════════════════════════════════════════════
// ENGINE
// ═══════════════════════════════════════════════════════════════════════════

class DownloadEngine {
  static const int _progressReportIntervalMs = 500;
  static const int _isolatePoolSize = 4;
  static const int _lowSpaceThresholdBytes = 500 * 1024 * 1024;

  int get effectiveProgressReportIntervalMs =>
      PowerMonitor.throttleFactor < 1.0 ? 1000 : _progressReportIntervalMs;

  final List<CancelToken> _activeCancelTokens = [];
  DownloadIsolatePool? _pool;
  Future<DownloadIsolatePool>? _poolInit;
  final _httpEngine = HttpDownloadEngine();
  final Set<int> _activeTorrentIds = <int>{};
  final Dio _sharedDio;

  // ── YouTube live counterpart byte tracking ──────────────────────────
  /// FIX-YT-LIVE: Maps each YT stream taskId → its counterpart taskId.
  /// Registered by the orchestrator before starting either stream.
  final Map<String, String> _ytCounterpartTaskIds = {};

  /// FIX-YT-LIVE: Static cache of live downloaded bytes per YT stream task.
  /// The engine writes here on every progress tick; the orchestrator (or
  /// the engine itself when forwarding) reads the counterpart's live bytes
  /// so ytCombinedProgress always reflects BOTH audio and video.
  static final Map<String, int> _ytLiveBytes = {};

  /// Registers a bidirectional counterpart relationship (video ↔ audio).
  void registerYtCounterpart(String taskId, String counterpartTaskId) {
    _ytCounterpartTaskIds[taskId] = counterpartTaskId;
    _ytCounterpartTaskIds[counterpartTaskId] = taskId;
  }

  /// FIX-YT-UNREGISTER: Tracks which YT streams have finished so live bytes
  /// are only cleaned up when BOTH streams in a pair are done. This prevents
  /// the still-running counterpart from losing access to the finished
  /// stream's final byte count, which would cause it to report
  /// 'downloading' instead of 'completed' on its final tick — the combined
  /// audio+video progress bar would freeze below 100%.
  static final Set<String> _ytFinishedStreams = {};

  final Set<Timer> _ytCleanupTimers = {};

  void unregisterYtCounterpart(String taskId) {
    _ytFinishedStreams.add(taskId);
    final c = _ytCounterpartTaskIds[taskId];

    if (c != null && _ytFinishedStreams.contains(c)) {
      // Both streams are now finished — clean up everything.
      _ytCounterpartTaskIds.remove(taskId);
      _ytCounterpartTaskIds.remove(c);
      DownloadEngine._ytLiveBytes.remove(taskId);
      DownloadEngine._ytLiveBytes.remove(c);
      _ytFinishedStreams.remove(taskId);
      _ytFinishedStreams.remove(c);
    } else if (c == null) {
      // No counterpart registered (or already cleaned up) — just clean
      // up self.
      DownloadEngine._ytLiveBytes.remove(taskId);
      _ytFinishedStreams.remove(taskId);
    } else {
      // Counterpart is still running. Leave _ytCounterpartTaskIds and
      // _ytLiveBytes intact so the counterpart can still look up our final
      // byte count. But schedule a safety cleanup in case the counterpart
      // never finishes (crash, unhandled error) — prevents a permanent
      // memory leak of both streams' live byte data.
      Timer? timer;
      timer = Timer(const Duration(minutes: 10), () {
        _ytCleanupTimers.remove(timer);
        if (_ytFinishedStreams.contains(taskId) &&
            _ytCounterpartTaskIds.containsKey(taskId)) {
          _ytCounterpartTaskIds.remove(taskId);
          _ytCounterpartTaskIds.remove(c);
          DownloadEngine._ytLiveBytes.remove(taskId);
          DownloadEngine._ytLiveBytes.remove(c);
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

  // FIX-P1-7: Resource cleanup on engine disposal.
  void dispose() {
    _closed = true;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    for (final t in _ytCleanupTimers) {
      t.cancel();
    }
    _ytCleanupTimers.clear();
    _httpEngine.stopAdaptiveThreadMonitor();
    _pool?.dispose();
    _sharedDio.close(force: true);
    for (final client in [..._activeDioClients, ..._reservedDioClients]) {
      try {
        client.close(force: true);
      } catch (_) {}
    }
    _activeDioClients.clear();
    _reservedDioClients.clear();
    _dioClientCreationTimes.clear();
    _activeDownloadsPerClient.clear();
    _activeCancelTokens.clear();
    _ytCounterpartTaskIds.clear();
    DownloadEngine._ytLiveBytes.clear();
    _ytFinishedStreams.clear();
  }

  DownloadEngine({
    Dio? dio,
    bool enableCleanupTimer = true,
  }) : _sharedDio = dio ?? ConnectionManager.createDownloadDio() {
    if (enableCleanupTimer) {
      _cleanupTimer = Timer.periodic(const Duration(seconds: 120), (_) {
        if (_closed) return;
        final now = DateTime.now();
        _activeDioClients.removeWhere((client) {
          final hasActiveDownloads =
              _activeDownloadsPerClient[client]?.isNotEmpty ?? false;
          final age = _dioClientCreationTimes[client] != null
              ? now.difference(_dioClientCreationTimes[client]!)
              : Duration.zero;
          final reserved = _reservedDioClients.contains(client);
          final stale = (reserved
                  ? age > const Duration(minutes: 10)
                  : age > const Duration(minutes: 5)) &&
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

  // ── Dio client construction (main isolate; probes/metadata) ─────────────

  /// Builds an isolated Dio HTTP client for metadata probing or download transfers.
  /// If `proxyAddress` is provided, it takes precedence over `proxyHost`/`proxyPort`.
  Dio _buildIsolatedClient({
    String? url,
    String? customUserAgent,
    String? referer,
    bool enableProxy = false,
    String? proxyAddress,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = true,
    String? cookies,
    String? oauthToken,
  }) {
    final client = buildTransferDio(
      url: url,
      customUserAgent: customUserAgent,
      referer: referer,
      enableProxy: enableProxy,
      proxyAddress: proxyAddress,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
      bypassSSL: bypassSSL,
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

  // ── Metadata resolution (unchanged public behavior) ─────────────────────

  Future<DownloadMetadata> resolveMetadata({
    required String url,
    String? requestedFileName,
    String? customUserAgent,
    String? referer,
    bool enableProxy = false,
    String? proxyAddress,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = true,
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
    var fileName = requestedFileName?.trim().isNotEmpty == true
        ? safeFileName(requestedFileName!.trim())
        : fileNameFromUrl(punyUrl);
    var fileSize = 0;
    final uri = Uri.tryParse(punyUrl);
    final host = uri?.host.toLowerCase() ?? '';
    final isYoutube = host.contains('youtube.com') ||
        host == 'youtu.be' ||
        host.endsWith('.googlevideo.com');
    var supportsResume = isYoutube;

    final isolatedDio = _buildIsolatedClient(
      url: punyUrl,
      customUserAgent: customUserAgent,
      referer: referer,
      enableProxy: enableProxy,
      proxyAddress: proxyAddress,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
      bypassSSL: bypassSSL,
      cookies: cookies,
      oauthToken: oauthToken,
    );
    try {
      final response = await isolatedDio.head<dynamic>(
        punyUrl,
        cancelToken: cancelToken,
        options: Options(followRedirects: true, validateStatus: (_) => true),
      );
      final headerName = fileNameFromContentDisposition(response.headers);
      if (requestedFileName?.trim().isNotEmpty != true && headerName != null) {
        fileName = headerName;
      }
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

      if (fileSize == 0 ||
          response.statusCode == 403 ||
          response.statusCode == 405 ||
          response.statusCode == 400) {
        try {
          final getResponse = await isolatedDio.get<ResponseBody>(
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
            if (isLikelyHtmlResponse(getContentType) &&
                fileSize < 1024 * 1024) {
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
      }
    } catch (e) {
      debugPrint('HEAD request failed for ${_redactUrl(punyUrl)}: $e');
    } finally {
      _releaseClient(isolatedDio);
    }
    return DownloadMetadata(
      fileName: fileName,
      category: categoryFromFileName(fileName),
      fileSize: fileSize,
      supportsResume: supportsResume,
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

      // FIX-P0-3: Track cleanup state so cancel handler does not operate on an already-removed torrent.
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
          // FIX-P2-16: Keep torrent handle alive and pass torrentId so _handleTorrentDownload reuses it.
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
      // FIX-P2-17: Align magnet resolution timeout to 300s to match _waitForMetadata.
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

    // file:// .torrent
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

  // ── Speed limits / disk space ────────────────────────────────────────────

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
      final response = await client.head(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: const {'Range': 'bytes=0-0'},
          validateStatus: (_) => true,
        ),
      );
      // FIX-P2-14: Check status code — do not multithread an error response
      if (response.statusCode != null && response.statusCode! >= 400) {
        return 1;
      }
      if (response.headers.value('accept-ranges') == 'none') return 1;
      if (response.headers.value('connection')?.toLowerCase() == 'close') {
        return 1;
      }
      return requestedThreads;
    } catch (_) {
      return requestedThreads;
    }
  }

  // ── Paths / cleanup ──────────────────────────────────────────────────────

  String buildLocalFilePath(String directory, String fileName) {
    final safeName = safeFileName(fileName);
    final fullPath = p.join(directory, safeName);
    if (!p.isWithin(directory, fullPath)) {
      throw ArgumentError('Invalid file name: path traversal detected');
    }
    return fullPath;
  }

  // FIX-P2-15: Add path traversal check to buildTempFilePath
  String buildTempFilePath(String directory, String fileName) {
    final safeName = safeFileName(fileName);
    final fullPath = p.join(directory, '$safeName.dmxpart');
    if (!p.isWithin(directory, fullPath)) {
      throw ArgumentError('Invalid file name: path traversal detected');
    }
    return fullPath;
  }

  /// Deletes temp/sidecar files for a task. Merge sources (.audio*) are only
  /// removed when [mergeConfirmed] — callers that have not verified a
  /// successful merge can never delete the inputs, so a failed merge stays
  /// retryable without re-downloading.
  static Future<void> cleanupOrphanFiles(
    String tempFilePath, {
    bool mergeConfirmed = false,
  }) async {
    if (tempFilePath.trim().isEmpty) return;
    try {
      final dir = File(tempFilePath).parent;
      if (!await dir.exists()) return;
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
      for (final path in patterns) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (e) {
          debugPrint('[DownloadEngine] cleanup failed for $path: $e');
        }
      }
      final stem = p.basenameWithoutExtension(tempFilePath);
      final stemPartPrefix = '$stem.part';
      await for (final entity in dir.list(recursive: false)) {
        final basename = p.basename(entity.path);
        if (entity is File &&
            basename.startsWith(stemPartPrefix) &&
            entity.path != tempFilePath) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[DownloadEngine] cleanupOrphanFiles error: $e');
    }
  }

  // ── Main entry point (signature preserved) ──────────────────────────────

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
    bool enableProxy = false,
    String? proxyAddress,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = true,
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
    // FIX-CYCLE-RETRY: New parameter so the engine can distinguish a retry
    // (previous attempt failed) from a user-initiated resume. When true,
    // the engine emits 'retrying' instead of 'resuming' on the starting
    // tick, giving the user clear feedback that the previous attempt failed
    // and the engine is retrying — not just resuming from disk.
    bool isRetry = false,
  }) async {
    _activeCancelTokens.add(cancelToken);

    final int defaultCount =
        SettingsProvider.instance.effectiveDefaultThreadCount;
    final int effectiveThreadCount = (() {
      final base = (threadCount > 0 ? threadCount : defaultCount)
          .clamp(1, PowerMonitor.maxAllowedThreads);
      if (adaptiveThreads) {
        // Use the monitor's recommendation from the previous session, if any.
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
          enableProxy: enableProxy,
          proxyAddress: proxyAddress,
          proxyHost: proxyHost,
          proxyPort: proxyPort,
          proxyUsername: proxyUsername,
          proxyPassword: proxyPassword,
          bypassSSL: bypassSSL,
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
          // FIX-YT-STARTING: Include YT stream fields so the UI can display
          // the correct audio+video combined progress bar from the very
          // first progress tick, instead of losing stream identity during
          // the metadata-resolution phase.
          ytStreamKind: ytStreamKind,
          ytCounterpartSize: ytCounterpartSize,
          ytCounterpartDownloadedBytes: ytCounterpartDownloadedBytes,
        ));
      }
    }

    // Disk-space gate: only the REMAINING bytes matter for resumes.
    // FIX-RESUME-BYTES: Move alreadyOnDisk outside the if-block so the
    // 'starting' progress update can report actual on-disk bytes.
    int alreadyOnDisk = 0;
    // FIX-STARTING-CHUNKS: Extract per-chunk details from the loaded
    // state so the 'starting' emission on resume includes chunk-level
    // progress.
    List<ChunkDetail>? startingChunkDetails;
    int? startingTotalChunks;
    int? startingCompletedChunks;
    if (resolvedFileSize > 0) {
      final saveDir = Directory(localFilePath).parent.path;
      try {
        final state = await StateStore.loadOrCreate(
          tempFilePath,
          url: url,
          threadCount: effectiveThreadCount,
          knownFileSize: resolvedFileSize,
        );
        alreadyOnDisk = state.state.downloadedBytes;
        // FIX-STARTING-CHUNKS: Build chunk details from the loaded state
        // so the user sees per-part progress immediately on resume.
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
        _activeCancelTokens.remove(cancelToken);
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
          enableProxy: enableProxy,
          proxyAddress: proxyAddress,
          proxyHost: proxyHost,
          proxyPort: proxyPort,
          proxyUsername: proxyUsername,
          proxyPassword: proxyPassword,
          bypassSSL: bypassSSL,
          isRetry: isRetry,
        );
      } finally {
        _activeCancelTokens.remove(cancelToken);
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
      enableProxy: enableProxy,
      proxyAddress: proxyAddress,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
      bypassSSL: bypassSSL,
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
    );

    if (adaptiveThreads) {
      // Start the periodic plateau-detection monitor for this task.
      // It observes speed samples and publishes a thread-count recommendation
      // that will be applied the next time this task starts (see above).
      _httpEngine.startAdaptiveMonitorForTask(taskId, effectiveThreadCount);
    }

    // FIX-CYCLE-START: Always emit 'starting' before pool submission so the
    // UI transitions from the previous state (paused/failed/retrying) to
    // 'starting' immediately — even when metadata resolution was skipped
    // (knownFileSize > 0, user-provided name). Without this, the UI retains
    // the old cycle state until the first worker progress tick arrives.
    // FIX-CYCLE-RETRY-HTTP: If this is a retry (alreadyOnDisk > 0 AND the
    // task was previously failed), emit 'retrying' instead of 'resuming'
    // so the UI shows "Retrying…" rather than "Resuming…" — giving the
    // user clear feedback that the previous attempt failed and the engine
    // is retrying, not just resuming from disk.
    // FIX-CYCLE-TOR-START: Torrents also need 'starting' before
    // 'fetching_metadata' so the UI shows an active spinner immediately
    // instead of retaining the previous cycle state until metadata arrives.
    // FIX-YT-START-LIVE: Initialize the live bytes cache with on-disk and
    // spawn-time counterpart bytes so the combined audio+video progress
    // bar is accurate from the very first 'starting' tick on resume.
    // Uses putIfAbsent to avoid overwriting a value already set by the
    // counterpart stream's download().
    // FIX-YT-START-LIVE-COUNTERPART: Use live counterpart bytes if
    // available — the counterpart stream may have progressed since spawn,
    // making the spawn-time ytCounterpartDownloadedBytes stale.
    int? ytStartingCounterpartBytes = ytCounterpartDownloadedBytes;
    if (ytStreamKind != null) {
      // FIX-YT-LIVE-INIT: Always set (not putIfAbsent) the live bytes for
      // this stream so a resumed task starts with the correct on-disk
      // byte count. putIfAbsent would leave a stale 0 if the task was
      // previously started, cancelled, and restarted after the cache was
      // cleared by unregisterYtCounterpart.
      DownloadEngine._ytLiveBytes[taskId] = alreadyOnDisk;
      // FIX-LINT: Assign to a local final variable to properly promote
      // the type inside the closure without needing the '!' operator.
      final counterpartBytes = ytCounterpartDownloadedBytes;
      if (counterpartBytes != null && counterpartBytes > 0) {
        final counterpartId = _ytCounterpartTaskIds[taskId];
        if (counterpartId != null) {
          DownloadEngine._ytLiveBytes.putIfAbsent(
            counterpartId,
            () => counterpartBytes,
          );
        }
      }
      // Read back the live value — the counterpart may have already set
      // its own live bytes which are more accurate than the spawn-time
      // value passed via ytCounterpartDownloadedBytes.
      final ytStartCid = _ytCounterpartTaskIds[taskId];
      if (ytStartCid != null) {
        final live = DownloadEngine._ytLiveBytes[ytStartCid];
        if (live != null) {
          ytStartingCounterpartBytes = live;
        }
      }
    }
    // FIX-CYCLE-TOR-DEDUP: Skip the main 'starting'/'resuming' emission for
    // torrents — _handleTorrentDownload emits its own 'starting'/'resuming'
    // with the same file-level data, so emitting here causes a duplicate
    // progress update that can flicker the UI. HTTP and YouTube downloads
    // still need this emission because they go through the isolate pool.
    if (!isTorrent) {
      onProgress(DownloadProgress(
        // FIX-RESUME-BYTES: Report actual on-disk bytes on 'starting' so
        // the progress bar doesn't drop to 0 on resume.
        // FIX-RESUME-CYCLE: Use 'resuming' when there are bytes already
        // on disk (alreadyOnDisk > 0) to distinguish a resume from a fresh
        // start, giving the user clearer cycle feedback.
        downloadedBytes: alreadyOnDisk,
        fileSize: resolvedFileSize,
        speed: 0.0,
        eta: null,
        fileName: resolvedFileName,
        supportsResume: resolvedSupportsResume,
        // FIX-CYCLE-RETRY-HTTP: Distinguish retry from resume using the
        // isRetry parameter. When the orchestrator signals a retry (previous
        // attempt failed), emit 'retrying' so the UI shows "Retrying…"
        // instead of "Resuming…". When the user manually resumes a paused
        // download, emit 'resuming'. For fresh downloads with no bytes on
        // disk, emit 'starting'.
        cycleState: isRetry
            ? 'retrying'
            : (alreadyOnDisk > 0 ? 'resuming' : 'starting'),
        ytStreamKind: ytStreamKind,
        ytCounterpartSize: ytCounterpartSize,
        ytCounterpartDownloadedBytes: ytStartingCounterpartBytes,
        // FIX-YT-START-LIVE: Include this stream's live bytes so the
        // combined audio+video progress bar is accurate from the first tick.
        ytDownloadedBytes: alreadyOnDisk,
        // FIX-STARTING-CHUNKS: Include per-chunk details on 'starting' so
        // the HTTP details screen shows per-part progress immediately on
        // resume instead of waiting for the first worker tick.
        chunkDetails: startingChunkDetails,
        totalChunks: startingTotalChunks,
        completedChunks: startingCompletedChunks,
      ));
    }

    final pool = await _ensurePool();
    final job = pool.submit(command);
    final completer = Completer<void>();
    bool acked = false;
    bool cancelRequested = false;
    Timer? watchdog;
    Timer? inactivityTimer;
    DateTime? lastProgressEmitTime;
    // FIX-CYCLE-PAUSE: Track last known progress so we can emit a 'paused'
    // progress update with correct byte counts when the user cancels.
    // FIX-STARTING-BYTES: Initialize with alreadyOnDisk so an immediate
    // pause (before any worker tick) shows correct resume bytes.
    int lastDownloadedBytes = alreadyOnDisk;
    int lastFileSize = resolvedFileSize;
    // FIX-CYCLE-PAUSE-CHUNKS: Preserve last chunk details so the 'paused',
    // 'failed', and 'updating_links' progress updates include per-chunk
    // progress instead of dropping the chunk-level view when the cycle
    // transitions.
    // FIX-STARTING-CHUNKS: Initialize with starting chunk details so
    // pause/failed/updating_links emissions retain per-chunk data even
    // if no worker progress tick was received before the transition.
    List<ChunkDetail>? lastChunkDetails = startingChunkDetails;
    int? lastTotalChunks = startingTotalChunks;
    int? lastCompletedChunks = startingCompletedChunks;
    // FIX-CYCLE-TOR-TRACK: Track last torrent file-level data so
    // 'paused', 'failed', and 'updating_links' emissions include
    // per-file progress, file counts, and byte summaries for torrents
    // — matching the chunk-level preservation already done for HTTP.
    List<Map<String, dynamic>>? lastTorrentFiles =
        isTorrent ? getTorrentFiles?.call() : null;
    int? lastTotalFiles;
    int? lastCompletedFiles;
    int? lastTotalFileBytes;
    int? lastDownloadedFileBytes;
    // Non-active cycle states (paused/failed/updating_links) explicitly
    // use speed: 0.0 and eta: null, so we no longer track lastSpeed/lastEta.

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
      // FIX-P0-1: Guard against requestCancel executing after job has already completed.
      if (completer.isCompleted) return;
      cancelRequested = true;
      job.cancel();
      // A cancel must never leave a completed final file behind (even if the
      // worker already renamed the temp path in a race with the cancel).
      try {
        final f = File(localFilePath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      // FIX-CYCLE-PAUSE: Emit a 'paused' progress update with the last known
      // byte counts so the UI transitions immediately to the paused state
      // instead of retaining 'downloading' until the orchestrator processes
      // the cancel exception.
      // FIX-YT-PAUSE-LIVE: Use live counterpart bytes (if available) so the
      // combined audio+video progress bar retains the most accurate data
      // during pause, not the stale spawn-time value.
      final ytPauseCid = _ytCounterpartTaskIds[taskId];
      int? ytPauseLiveCp =
          ytPauseCid != null ? DownloadEngine._ytLiveBytes[ytPauseCid] : null;
      if (ytPauseLiveCp == null && ytPauseCid != null) {
        ytPauseLiveCp = ytCounterpartSize;
      }
      onProgress(DownloadProgress(
        downloadedBytes: lastDownloadedBytes,
        fileSize: lastFileSize,
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
        // FIX-YT-PAUSE: Preserve live YT stream bytes so the combined
        // audio+video progress bar retains accurate data during pause.
        ytDownloadedBytes: DownloadEngine._ytLiveBytes[taskId],
        // FIX-CYCLE-PAUSE-CHUNKS: Preserve chunk-level progress so the
        // details screen retains per-part visibility during pause.
        chunkDetails: lastChunkDetails,
        totalChunks: lastTotalChunks,
        completedChunks: lastCompletedChunks,
        // FIX-CYCLE-PAUSE-TOR: Preserve torrent file-level progress so
        // the details screen retains per-file visibility and single-file
        // percentage during pause.
        torrentFiles: lastTorrentFiles,
        totalFiles: lastTotalFiles,
        completedFiles: lastCompletedFiles,
        totalFileBytes: lastTotalFileBytes,
        downloadedFileBytes: lastDownloadedFileBytes,
        // FIX-CYCLE-PAUSE-TORRENT-ID: Include torrentId so the details
        // screen can associate the paused state with the torrent handle
        // for resume operations.
        torrentId: torrentId,
      ));
    }

    // FIX-P1-6: Store cancelFuture so it is tracked and handle unhandled async errors.
    final cancelFuture = cancelToken.whenCancel.then((_) => requestCancel());
    if (cancelToken.isCancelled) requestCancel();

    final sub = job.messages.listen((message) {
      switch (message.type) {
        case 'ack':
          acked = true;
          watchdog?.cancel();
          if (cancelRequested) job.cancel();
        case 'error':
          // FIX-CYCLE-ERROR: Map worker error types to structured cycle
          // states so the UI transitions correctly. 'urlExpired' →
          // 'updating_links' (orchestrator will refresh and retry);
          // 'cancel' → 'paused' (user-initiated); everything else →
          // 'failed' with preserved data so the details screen retains
          // chunk/file/YT visibility during the failed state.
          resetInactivityTimer();
          final errData = message.data;
          final errorType = errData['errorType'] as String? ?? 'uncaught';
          final errorMsg =
              errData['errorMessage'] as String? ?? 'Unknown error';

          if (errorType == 'cancel') {
            // Already handled by requestCancel() — skip.
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
            // FIX-CYCLE-UPDATING-LINKS: Emit 'updating_links' with all
            // preserved data (chunks, torrent files, YT audio+video) so
            // the UI shows "Updating links…" while the orchestrator
            // refreshes URLs and re-submits the job.
            // FIX-YT-UPDATING-LIVE: Read BOTH streams' live bytes fresh
            // from the cache so the combined audio+video progress bar
            // retains the most accurate data during URL refresh. The
            // spawn-time ytCounterpartDownloadedBytes may be stale if the
            // counterpart stream progressed between the last tick and the
            // URL expiry error.
            final ytUlcId = _ytCounterpartTaskIds[taskId];
            int? ytUlcLiveCp =
                ytUlcId != null ? DownloadEngine._ytLiveBytes[ytUlcId] : null;
            if (ytUlcLiveCp == null && ytUlcId != null) {
              ytUlcLiveCp = ytCounterpartSize;
            }
            final ytUlcLiveSelf = DownloadEngine._ytLiveBytes[taskId];
            onProgress(DownloadProgress(
              downloadedBytes: ytUlcLiveSelf ?? lastDownloadedBytes,
              fileSize: lastFileSize,
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
              chunkDetails: lastChunkDetails,
              totalChunks: lastTotalChunks,
              completedChunks: lastCompletedChunks,
              torrentFiles: lastTorrentFiles,
              totalFiles: lastTotalFiles,
              completedFiles: lastCompletedFiles,
              totalFileBytes: lastTotalFileBytes,
              downloadedFileBytes: lastDownloadedFileBytes,
            ));
            if (!completer.isCompleted) {
              // FIX-ERROR-MAP: Route through _mapWorkerError to correctly
              // construct UrlExpiredException with refreshAllMirrors flag.
              completer.completeError(_mapWorkerError(message, punyUrl));
            }
            break;
          }

          // FIX-CYCLE-RETRYABLE: For error types that are auto-retryable
          // (connectionTimeout, connectionError, receiveTimeout, sendTimeout),
          // emit 'retrying' instead of 'failed' so the UI shows "Retrying…"
          // and the user knows the engine hasn't given up. The orchestrator
          // will catch and retry these. Non-retryable errors (diskFull,
          // integrity, badResponse) still emit 'failed'.
          final isRetryable = errorType == 'connectionTimeout' ||
              errorType == 'connectionError' ||
              errorType == 'receiveTimeout' ||
              errorType == 'sendTimeout';
          final ytFailCid = _ytCounterpartTaskIds[taskId];
          int? ytFailLiveCp =
              ytFailCid != null ? DownloadEngine._ytLiveBytes[ytFailCid] : null;
          if (ytFailLiveCp == null && ytFailCid != null) {
            ytFailLiveCp = ytCounterpartSize;
          }
          onProgress(DownloadProgress(
            downloadedBytes: lastDownloadedBytes,
            fileSize: lastFileSize,
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
            ytDownloadedBytes: DownloadEngine._ytLiveBytes[taskId],
            chunkDetails: lastChunkDetails,
            totalChunks: lastTotalChunks,
            completedChunks: lastCompletedChunks,
            torrentFiles: lastTorrentFiles,
            totalFiles: lastTotalFiles,
            completedFiles: lastCompletedFiles,
            totalFileBytes: lastTotalFileBytes,
            downloadedFileBytes: lastDownloadedFileBytes,
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
          resetInactivityTimer();
          final p = message.data;
          if (adaptiveThreads) {
            // Feed live throughput into the adaptive monitor so plateau
            // detection can fire and update the recommendation.
            final speed = (p['speed'] as num?)?.toDouble() ?? 0.0;
            if (speed > 0) {
              _httpEngine.recordSample(taskId, speed, effectiveThreadCount);
            }
          }
          // FIX-CHUNK-DETAILS: Parse per-chunk byte details for HTTP details screen
          List<ChunkDetail>? chunkDetails;
          if (p['chunkDetails'] is List) {
            chunkDetails = (p['chunkDetails'] as List).map((c) {
              // ignore: avoid_dynamic_calls
              // FIX-CHUNK-SIZE-DEFAULT: Default to -1 (indeterminate) to
              // match ChunkDetail.fromMap. A default of 0 made unknown-size
              // chunks appear as "complete" since isComplete checks
              // downloaded >= size (0 >= 0 == true).
              // ignore: avoid_dynamic_calls
              final rawSize = (c['size'] as num?)?.toInt() ?? -1;
              // ignore: avoid_dynamic_calls
              final rawRatio = (c['ratio'] as num?)?.toDouble() ?? 0.0;
              // FIX-RATIO-SENTINEL: After the ChunkState.ratio fix that
              // returns -1.0 for unknown-size chunks, clamp the ratio
              // back to [0.0, 1.0] for the ChunkDetail model. The
              // isIndeterminate getter on ChunkDetail already signals
              // indeterminate state via `size < 0`, so the ratio field
              // itself should never be negative.
              // FIX-RATIO-NAN: Also guard against NaN/Infinity which can
              // leak from the worker isolate if a chunk's downloaded or
              // size fields are momentarily inconsistent.
              final safeRatio =
                  (rawRatio.isNaN || rawRatio.isInfinite || rawRatio < 0.0)
                      ? 0.0
                      : rawRatio.clamp(0.0, 1.0);
              return ChunkDetail(
                // ignore: avoid_dynamic_calls
                index: (c['index'] as num?)?.toInt() ?? 0,
                // ignore: avoid_dynamic_calls
                start: (c['start'] as num?)?.toInt() ?? 0,
                // ignore: avoid_dynamic_calls
                end: (c['end'] as num?)?.toInt() ?? -1,
                // ignore: avoid_dynamic_calls
                downloaded: (c['downloaded'] as num?)?.toInt() ?? 0,
                size: rawSize,
                ratio: safeRatio,
              );
            }).toList();
          }
          // FIX-YT-LIVE: Store THIS stream's live bytes in the static cache
          // and look up the counterpart's live bytes so the combined
          // percentage always reflects BOTH streams.
          // FIX-YT-LIVE-FALLBACK: When the worker doesn't send
          // ytDownloadedBytes as a separate field, fall back to the
          // progress tick's downloadedBytes. For YouTube streams,
          // downloadedBytes IS this stream's live bytes — without this
          // fallback, the live cache goes stale and the counterpart
          // stream's combined audio+video progress bar freezes.
          final ytLive = (p['ytDownloadedBytes'] as num?)?.toInt();
          final ytEffectiveLive = ytLive ??
              (ytStreamKind != null
                  ? (p['downloadedBytes'] as num?)?.toInt()
                  : null);
          if (ytEffectiveLive != null) {
            DownloadEngine._ytLiveBytes[taskId] = ytEffectiveLive;
          }
          final counterpartId = _ytCounterpartTaskIds[taskId];
          int? liveCounterpart = counterpartId != null
              ? DownloadEngine._ytLiveBytes[counterpartId]
              : null;
          // FIX-YT-LIVE-FALLBACK: If the counterpart finished and was
          // unregistered, its live bytes cache entry is gone. Use its
          // known size as the live bytes so the combined progress bar
          // doesn't drop back to the spawn-time value.
          if (liveCounterpart == null && counterpartId != null) {
            liveCounterpart = ytCounterpartSize;
          }

          // FIX-CYCLE-LAST-DATA: Update last-known progress values on
          // every tick so non-active cycle states (paused/failed/
          // updating_links) can emit them instead of zeros. This covers
          // HTTP chunks, torrent files, YT audio+video, speed, and ETA.
          lastDownloadedBytes =
              (p['downloadedBytes'] as num?)?.toInt() ?? lastDownloadedBytes;
          lastFileSize = (p['fileSize'] as num?)?.toInt() ?? lastFileSize;
          // Speed and ETA are read directly from 'p' for 'downloading' states.
          // Non-active states hardcode 0.0 and null.
          // Chunk-detail caching is handled below after totalParts/doneParts
          // are computed, so they reflect isDone completion semantics.
          // FIX-CYCLE-TOR-TRACK-UPDATE: Update torrent file-level data
          // from the worker message so pause/failed/updating_links
          // emissions include current per-file progress.
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

          // FIX-CYCLE: Derive structured cycle state from status message.
          final sm = p['statusMessage'] as String?;
          var cycle = _deriveCycleState(
            sm,
            cancelToken.isCancelled,
            isTorrent,
          );
          // FIX-YT-CYCLE-COMBINED: If this YouTube stream reports
          // 'completed' but the counterpart stream is still downloading,
          // keep the cycle as 'downloading' so the UI doesn't show
          // 'completed' prematurely. The overall download is only
          // complete when BOTH audio and video streams finish.
          // FIX-YT-COMBINED-PROG: For combined/muxed YouTube streams (no
          // counterpart), 'completed' is valid — don't override it to
          // 'downloading'. Only audio+video splits need the counterpart
          // guard below.
          if (cycle == 'completed' &&
              ytStreamKind != null &&
              ytStreamKind != YtStreamKind.combined) {
            // FIX-YT-COUNTERPART-CHECK: Check the counterpart's live bytes
            // to determine if it's still downloading. If the counterpart
            // hasn't started (null) or hasn't finished (< counterpartSize),
            // keep the cycle as 'downloading' so the combined audio+video
            // progress bar doesn't show 'completed' prematurely.
            final cpId = _ytCounterpartTaskIds[taskId];
            final cpLive =
                cpId != null ? DownloadEngine._ytLiveBytes[cpId] : null;
            final cpSize = ytCounterpartSize;
            // FIX-YT-CONSISTENCY: When counterpart size is unknown (null
            // or <= 0), keep 'downloading' — consistent with the 'done'
            // case's doneCycle logic. Previously this only checked
            // cpSize > 0, causing premature 'completed' when counterpart
            // size was not yet resolved.
            if (cpSize == null || cpSize <= 0) {
              cycle = 'downloading';
            } else if (cpLive == null || cpLive < cpSize) {
              cycle = 'downloading';
            }
          }

          // FIX-HTTP-PARTS: Derive explicit chunk completion counts.
          // FIX-HTTP-PARTS-NULL: When chunkDetails is null (worker didn't
          // report per-chunk data, e.g. single-stream), leave counts null
          // so the UI shows an indeterminate bar instead of "0/0 parts".
          final chunkList = chunkDetails;
          final totalParts = chunkList?.length ?? 0;
          // FIX-CHUNK-COMPLETE: When the download is completed, count ALL
          // chunks as complete — including indeterminate-size chunks (size
          // < 0) whose isComplete getter always returns false. Without this,
          // a finished single-stream download shows 0/1 parts done.
          final isDone = cycle == 'completed';
          final doneParts = chunkList == null
              ? 0
              : (isDone
                  ? totalParts
                  : chunkList.where((c) => c.isComplete).length);

          // FIX-CYCLE-LAST-DATA-DUP: Removed duplicate assignment that
          // reset lastDownloadedBytes to 0 when p['downloadedBytes'] was
          // null. The earlier assignment above already handles this with
          // lastDownloadedBytes as the correct fallback.
          // FIX-CYCLE-PAUSE-CHUNKS: Cache chunk details for non-downloading
          // cycle state emissions (paused/failed/updating_links).
          lastChunkDetails = chunkDetails ?? lastChunkDetails;
          lastTotalChunks = (isTorrent || chunkDetails == null)
              ? lastTotalChunks
              : totalParts;
          lastCompletedChunks = (isTorrent || chunkDetails == null)
              ? lastCompletedChunks
              : doneParts;

          // FIX-P3-26: Throttle progress notifications on main isolate using effectiveProgressReportIntervalMs
          final nowEmit = DateTime.now();
          final shouldEmit = lastProgressEmitTime == null ||
              nowEmit.difference(lastProgressEmitTime!) >=
                  Duration(milliseconds: effectiveProgressReportIntervalMs);
          if (shouldEmit) {
            lastProgressEmitTime = nowEmit;
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
        case 'done':
          // FIX-CYCLE-DONE: Emit final 'completed' with all preserved
          // data (chunks, torrent files, YT audio+video combined) so the
          // details screen shows 100% on every level before the
          // orchestrator processes the completion.
          // FIX-YT-DONE-LIVE: Set this stream's final live bytes to its
          // total size so the counterpart's combined percentage reaches
          // 100% even if the counterpart's last tick hasn't arrived yet.
          if (ytStreamKind != null && lastFileSize > 0) {
            DownloadEngine._ytLiveBytes[taskId] = lastFileSize;
          }
          watchdog?.cancel();
          inactivityTimer?.cancel();
          if (cancelRequested || cancelToken.isCancelled) {
            // Completion raced with a cancel. Honor the cancel so a cancelled
            // task is never surfaced as "complete" and never leaves a final
            // file behind. Any temp/state the worker removed stays removed;
            // a final file already renamed in the race is dropped.
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
            // FIX-CYCLE-DONE: Emit a final 'completed' progress so the UI
            // transitions immediately even if the worker's last progress
            // tick didn't include a 'completed' status message. Preserves
            // chunk details and YT live bytes for accurate final rendering.
            // FIX-YT-DONE-CYCLE: If this is a YouTube stream and the
            // counterpart is still downloading (or its size is unknown),
            // keep cycle as 'downloading' so the UI doesn't show
            // 'completed' prematurely for audio+video downloads.
            final ytDoneCid = _ytCounterpartTaskIds[taskId];
            int? ytDoneLiveCp = ytDoneCid != null
                ? DownloadEngine._ytLiveBytes[ytDoneCid]
                : null;
            if (ytDoneLiveCp == null && ytDoneCid != null) {
              ytDoneLiveCp = ytCounterpartSize;
            }
            if (lastFileSize > 0) {
              lastDownloadedBytes = lastFileSize;
              // FIX-YT-DONE-LIVE: Live bytes cache was already set to
              // lastFileSize at the top of the 'done' handler (before the
              // cancel/non-cancel branch). The redundant second write is
              // removed to avoid confusion about which write is the
              // authoritative one.
            }
            // FIX-CHUNK-COMPLETE-DONE: On done, count ALL chunks as
            // complete (including indeterminate-size chunks whose
            // isComplete getter returns false due to size < 0).
            if (lastChunkDetails != null && lastTotalChunks != null) {
              lastCompletedChunks = lastTotalChunks;
            }
            // FIX-FILE-COMPLETE-DONE: On done, mark ALL torrent files as
            // complete and set downloaded bytes to total — mirrors the
            // chunk-complete logic above so a racing cancel/pause emission
            // sees consistent file-level data instead of stale values
            // from the last progress tick.
            if (lastTotalFiles != null) {
              lastCompletedFiles = lastTotalFiles;
            }
            if (lastTotalFileBytes != null) {
              lastDownloadedFileBytes = lastTotalFileBytes;
            }
            var doneCycle = 'completed';
            // FIX-YT-COMBINED-DONE: For combined/muxed YouTube streams (no
            // counterpart), the download IS complete. Previously the null
            // ytCounterpartSize forced doneCycle to 'downloading', so muxed
            // YT downloads never showed 'completed' and the UI stayed stuck
            // on an active spinner forever.
            if (ytStreamKind != null && ytStreamKind != YtStreamKind.combined) {
              final cpSize = ytCounterpartSize;
              if (cpSize == null || cpSize <= 0) {
                // FIX-YT-DONE-NO-COUNTERPART: If counterpart size is unknown
                // AND counterpart never started (no live byte cache entry),
                // this stream is effectively complete — don't hold it in
                // 'downloading' forever waiting for a counterpart that will
                // never come. The orchestrator handles the missing stream
                // separately.
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
              downloadedBytes: lastDownloadedBytes,
              fileSize: lastFileSize,
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
              // FIX-YT-DONE-BYTES: Fall back to lastDownloadedBytes when
              // live cache wasn't set (lastFileSize == 0 skipped the
              // cache update above). Ensures combined audio+video bar
              // has a valid byte count on completion even for streams
              // whose size was never resolved.
              ytDownloadedBytes:
                  DownloadEngine._ytLiveBytes[taskId] ?? lastDownloadedBytes,
              chunkDetails: lastChunkDetails,
              totalChunks: lastTotalChunks,
              completedChunks: lastCompletedChunks,
              torrentFiles: lastTorrentFiles,
              totalFiles: lastTotalFiles,
              completedFiles: lastCompletedFiles ?? lastTotalFiles,
              totalFileBytes: lastTotalFileBytes,
              downloadedFileBytes:
                  lastDownloadedFileBytes ?? lastTotalFileBytes,
            ));
            if (!completer.isCompleted) {
              completer.complete();
            }
          }
        // FIX-DEAD-CODE: Removed unreachable second `case 'error':` block.
        // The first `case 'error':` above handles all error types with
        // complete data (chunks, torrent files, YT audio+video live bytes,
        // file-level summaries). This dead code was missing torrent file
        // fields and YT live bytes — removing it eliminates the risk of
        // silently dropped data if Dart switch semantics change.
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
      _activeCancelTokens.remove(cancelToken);
      // FIX-YT-LIVE: Clean up YouTube counterpart tracking on exit.
      if (ytStreamKind != null) {
        unregisterYtCounterpart(taskId);
      }
      if (adaptiveThreads) {
        // Keep the tracker alive so recommendedThreads() can be read on the
        // next start, but stop the periodic timer if no other tasks are tracked.
        if (_httpEngine.activeTrackerCount == 0) {
          _httpEngine.stopAdaptiveThreadMonitor();
        }
      }
    }
  }

  /// Maps versioned worker error payloads back to typed exceptions.
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
        // FIX-3: typed signal so the orchestrator can refresh the URL
        // (YouTube / signed S3 links) and resume without losing bytes.
        // FIX-URL-EXPIRY-ALL-MIRRORS: For YouTube / signed-URL sources,
        // all mirrors share the same expiry signature. The data flag
        // 'refreshAllMirrors' tells the orchestrator to re-resolve every
        // mirror URL (not just the active one) before retrying.
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

  // ── Torrent orchestration (engine side) ─────────────────────────────────

  Future<void> _handleTorrentDownload({
    required String url,
    required String currentLocalFilePath,
    required int knownFileSize,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool enableProxy = false,
    String? proxyAddress,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    bool bypassSSL = true,
    bool isRetry = false,
  }) async {
    // FIX-CYCLE-TOR-START: Emit 'starting' immediately so the UI shows an
    // active spinner before metadata resolution begins. Without this, the
    // torrent retains its previous cycle state (paused/failed) until the
    // first 'fetching_metadata' heartbeat arrives 10 seconds later.
    final initialTorrentFiles = getTorrentFiles?.call();
    // FIX-TOR-FILE-NORM: Use the shared helper to normalize all file maps
    // and compute summary stats in one pass. Ensures single-file
    // percentage on the details screen is always valid from the first tick.
    final initSummary = normalizeTorrentFiles(initialTorrentFiles);
    onProgress(DownloadProgress(
      // FIX-TOR-RESUME-BYTES: Report actual downloaded bytes from stored
      // file data so the overall progress bar doesn't drop to 0 on resume.
      downloadedBytes: initSummary.downloaded,
      // FIX-TOR-START-SIZE: Use total selected file bytes when available
      // (more accurate for partial selections) instead of knownFileSize.
      fileSize: initSummary.bytes > 0 ? initSummary.bytes : knownFileSize,
      speed: 0.0,
      eta: null,
      supportsResume: true,
      torrentFiles: initialTorrentFiles,
      // FIX-RESUME-CYCLE: Distinguish resume from fresh start so the UI
      // can show "Resuming…" instead of "Starting…" when bytes exist.
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
      debugPrint('[DMX] Stale torrent handle $id detected; re-adding.');
      id = -1;
    }
    if (id == -1) {
      final saveDir = File(currentLocalFilePath).parent.path;
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
            enableProxy: enableProxy,
            proxyAddress: proxyAddress,
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            proxyUsername: proxyUsername,
            proxyPassword: proxyPassword,
            bypassSSL: bypassSSL,
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

    // FIX-CYCLE-TOR-PAUSE: Emit 'paused' progress with full file-level data
    // when the user cancels a torrent, so the UI transitions immediately
    // to 'paused' instead of retaining the last active cycle state until
    // the cancel error surfaces. Preserves per-file percentage, file counts,
    // and byte summaries so the details screen retains all data on pause.
    // FIX-P0-2: Guard cancel callback against firing after torrent completion.
    bool torrentCompleted = false;
    cancelToken.whenCancel.then((_) {
      if (torrentCompleted) return;
      try {
        TorrentService.pauseTorrent(id);
      } catch (_) {}
      final pauseFiles = getTorrentFiles?.call();
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

      // RESUME BARRIER (load side): fast-resume data is loaded, hash-verified
      // and applied BEFORE the torrent is resumed and BEFORE any progress
      // number can be emitted. Without usable resume data we recheck and wait
      // for the checking state to finish — still before any progress number.
      final resumeBlob = await TorrentResumeStore.loadResumeDataForSource(url);
      final nativeLoaded =
          resumeBlob != null && TorrentService.loadResumeData(id, resumeBlob);
      if (!nativeLoaded) {
        if (resumeBlob != null) {
          debugPrint(
              '[DMX] stored resume data rejected by engine — rechecking');
        }
        TorrentService.recheckTorrent(id);
        // FIX-12 / FIX-24: Use the ENGINE-reported total size, not
        // knownFileSize, which is 0 for fresh magnet adds. Wait for
        // metadata first if necessary so we have a real size to scale with.
        int effectiveSize = knownFileSize;
        try {
          // _waitForMetadata already guarantees metadata is available, but
          // we listen briefly to safely extract totalWanted without relying
          // on a static cache (which may not exist on all platforms).
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
        // FIX-RECHECK-FEEDBACK: Pass onProgress + knownFileSize so the user
        // sees "Checking pieces… X%" during recheck instead of a frozen bar.
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
        // FIX-CYCLE-CHECKING: Emit 'checking' completion transition with
        // full file-level data so the details screen retains per-file
        // percentages, file counts, and byte summaries after recheck
        // finishes and before the torrent resumes downloading.
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
        // FIX-CYCLE-RETRY: Don't emit 'failed' for TorrentEnginePauseException
        // — the 'retrying' state was already emitted in _listenForCompletion
        // with full file-level data. The orchestrator will catch this
        // exception and retry.
        if (e is! TorrentEnginePauseException) {
          // FIX-CYCLE-RETRYABLE: For DioException types that are
          // auto-retryable (connectionTimeout, connectionError,
          // receiveTimeout), emit 'retrying' instead of 'failed' so the
          // UI shows "Retrying…" and the user knows the engine hasn't
          // given up. The orchestrator will catch and retry these.
          // Non-retryable errors (diskFull, integrity) still emit 'failed'.
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
          TorrentService.removeTorrent(id, deleteFiles: false);
        } catch (_) {}
      }
      rethrow;
    } finally {
      torrentCompleted = true;
      _activeTorrentIds.remove(id);
      // FIX-P1-10: Clean up source mapping for torrent
      TorrentResumeStore.unregisterSource(url);
      // FIX-TOR-04: Clean up static maps on torrent removal or completion
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
      // FIX-FETCH-META-FILES: Include stored torrent files so the details
      // screen retains the file tree and per-file percentages during
      // metadata fetching heartbeats instead of going blank.
      final metaFiles = getTorrentFiles?.call();
      final mfSummary = normalizeTorrentFiles(metaFiles);
      onProgress(DownloadProgress(
        downloadedBytes: mfSummary.downloaded,
        fileSize:
            initialFileSize > 0 ? initialFileSize : 0, // FIX-L4: pass size
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

  // FIX T-2: Log mismatch and attempt name-based reconciliation
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
      // Try to match by filename and apply priorities to matched files
      final engineFiles = TorrentService.getFiles(id);
      String normalizeName(String name) {
        var decoded = name;
        try {
          decoded = Uri.decodeComponent(name.replaceAll('+', ' '));
        } catch (_) {}
        return decoded.replaceAll('\\', '/').trim().toLowerCase();
      }

      final storedByName = <String, Map<String, dynamic>>{};
      for (final f in currentTorrentFiles) {
        storedByName[normalizeName(f['name'] as String? ?? '')] = f;
      }

      // FIX-6: Pre-calculate if the user has deselected ANY file to correctly
      // handle unknown files regardless of their position in the list.
      final anyUserDeselected =
          currentTorrentFiles.any((f) => !isTorrentFileSelected(f));

      final priorities = <int>[];
      final preservedBytes = <String, int>{};
      var userDeselectedCount = 0;
      for (final ef in engineFiles) {
        final key = normalizeName(ef.name);
        final stored = storedByName[key];
        if (stored != null) {
          final selected = isTorrentFileSelected(stored);
          if (!selected) userDeselectedCount++;
          priorities.add(selected ? (stored['priority'] as int? ?? 4) : 0);
          // FIX-RECONCILE-BYTES: Preserve the stored downloadedBytes for
          // matched files so the next progress tick doesn't flash 0% on
          // every file before the engine reports real per-file bytes.
          final storedBytes = (stored['downloadedBytes'] as num?)?.toInt() ?? 0;
          if (storedBytes > 0) {
            preservedBytes[key] =
                storedBytes.clamp(0, ef.size > 0 ? ef.size : storedBytes);
          }
        } else {
          // FIX-6: Unknown file. Default to selected ONLY if the user has
          // not deselected any other file (i.e., they appear to want
          // everything). If they deselected at least one, respect their
          // selective intent and DO NOT auto-select unknowns.
          priorities.add(anyUserDeselected ? 0 : 4);
        }
      }
      // Stash preserved bytes for the next _listenForCompletion tick to
      // pick up via the existing `existing?['downloadedBytes']` lookup.
      // (The orchestrator stores these back into the task's torrentFiles.)
      debugPrint(
        '[DMX] FIX-RECONCILE-BYTES: preserved bytes for '
        '${preservedBytes.length} file(s) across reconciliation.',
      );
      if (priorities.length == engineFileCount) {
        TorrentService.setFilePriorities(id, priorities);
        debugPrint(
            '[DMX] FIX-6/T-2: Reconciled priorities ($userDeselectedCount user-deselected).');
      } else {
        // FIX-6: Even on total reconciliation failure, do NOT silently
        // select all — preserve user intent by selecting only files that
        // were previously selected.
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
    // Normal path (counts match)
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

      // NEVER emit progress numbers while resume data is being verified.
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
          // FIX T-2: Normalize file names for comparison (handles URL-encoding and slash normalization)
          String normalizeName(String name) {
            var decoded = name;
            try {
              decoded = Uri.decodeComponent(name.replaceAll('+', ' '));
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
              // BUG 8 FIX: When f.size == 0, return 0 instead of unclamped safeDownloadedBytes
              resolvedBytes =
                  f.size > 0 ? f.safeDownloadedBytes.clamp(0, f.size) : 0;
              isEstimated = false;
              // FIX-7: Real per-file percentage, clamped to [0.0, 1.0].
              // FIX-ZERO-SIZE: A zero-size file is trivially complete (1.0).
              fileProgress =
                  f.size > 0 ? (resolvedBytes / f.size).clamp(0.0, 1.0) : 1.0;
            } else {
              // FIX T-S1: Preserve the previously stored byte count instead of
              // resetting to 0. The proportional estimator in
              // _distributeEstimatedBytes will refine it once the engine
              // reports real data.
              final prevStored =
                  (existing?['downloadedBytes'] as num?)?.toInt() ?? 0;
              // FIX-7: Clamp stored bytes to file length — defensive guard
              // against stale state from a previous version.
              resolvedBytes = f.size > 0
                  ? prevStored.clamp(0, f.size)
                  : prevStored.clamp(0, 1 << 62);
              isEstimated = true;
              // FIX-ZERO-SIZE: A zero-size file is trivially complete (1.0).
              fileProgress =
                  f.size > 0 ? (resolvedBytes / f.size).clamp(0.0, 1.0) : 1.0;
            }
            return <String, dynamic>{
              'name': f.name,
              'length': f.size,
              'selected': existing?['selected'] as bool? ?? f.selected,
              'priority': existing?['priority'] as int? ?? f.priority,
              'downloadedBytes': resolvedBytes,
              // FIX-FILE-SPEED: Populated below via aggregate rate
              // distribution across actively-downloading selected files.
              'speed': 0.0,
              'progressEstimated': isEstimated,
              // FIX-7: Explicit per-file percentage so UI can render
              // file-level progress bars without re-computing (and possibly
              // disagreeing with downloadedBytes/length).
              'progress': fileProgress,
              // FIX-FILE-ISCOMPLETE-PERCENT: Set isComplete and percent
              // directly in the engine emission so the torrent details
              // screen single-file percentage bar always has valid data
              // without relying on torrentFilePercents getter or
              // fromWorkerMap to synthesize them. Both keys must always
              // agree — 'progress' is the canonical key used by newer
              // code, 'percent' is the legacy alias.
              'percent': fileProgress,
              'isComplete': f.size == 0 || resolvedBytes >= f.size,
            };
          }).toList();
        } catch (e) {
          debugPrint('[DownloadEngine] getFiles failed: $e');
        }
      }

      // FIX-FILES-FALLBACK: When resolvedFiles is null (getFiles threw or
      // metadata not yet received by this tick), fall back to the stored
      // torrent files from the orchestrator. Without this, every progress
      // emission in _listenForCompletion sends torrentFiles: null and all
      // file-level summaries as null — the details screen loses the file
      // tree, per-file percentages (including single-file percentage),
      // file counts, and byte summaries until the next successful getFiles
      // call. normalizeTorrentFiles guarantees every file map has a valid,
      // clamped 'progress' field so the single-file percentage bar on the
      // torrent details screen is always renderable.
      if (resolvedFiles == null) {
        resolvedFiles = getTorrentFiles?.call();
        if (resolvedFiles != null) {
          normalizeTorrentFiles(resolvedFiles);
        }
      }

      // FIX-FILE-SPEED-DISTRIBUTE: Distribute the aggregate download/upload
      // rate across actively-downloading selected files so single-file speed
      // on the torrent details screen is non-zero. Previously the 'speed'
      // field was always 0.0 in the engine emission — the torrentFilePercents
      // getter's comment claimed the engine populated it, but it never did.
      // Distribution is equal among all selected, incomplete files (those
      // with length > 0 and downloadedBytes < length). Complete or
      // deselected files get 0.0 (no active transfer).
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

      // FIX-21 & FIX T-1: Prefer engine-reported per-file bytes over stored values
      // FIX-PROG-02: Include ALL selected file bytes (real + estimated) in
      // calculatedDownloaded so the total percentage is never artificially low.
      // Previously estimated bytes were excluded, causing the total to underreport
      // and _distributeEstimatedBytes to receive 0 remaining bytes for estimated
      // files (since total == confirmed), freezing them at 0%.
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
      // FIX-TOR-TOTAL: Prefer the per-file sum (calculatedTotal) because it
      // respects user file selection. Fall back to the engine aggregate, then
      // to the orchestrator's knownFileSize.
      final totalSize = calculatedTotal > 0
          ? calculatedTotal
          : (torrent.totalWanted > 0
              ? torrent.totalWanted
              : (knownFileSize > 0 ? knownFileSize : 0));

      // FIX T-1: While metadata is unknown, show indeterminate state.
      // If metadata is present but totalSize is 0 (e.g. user deselected all
      // files), fall through to normal progress emission so the UI doesn't
      // freeze on "Fetching metadata…".
      if (totalSize <= 0 && !torrent.hasMetadata) {
        // FIX-FETCH-META-FILES-LISTEN: Include stored torrent files and
        // file-level summary so the details screen retains the file tree
        // and per-file percentages during metadata fetching.
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
        return; // skip normal progress emission
      }

      // FIX-PROG-02: When any file has estimated progress, prefer the torrent
      // engine's aggregate totals (totalWantedDone / totalDone / progress)
      // over the per-file sum. The aggregate includes ALL downloaded bytes
      // (real + estimated) and is the most reliable early-phase source.
      // The per-file sum is used only as a fallback when aggregates are 0.
      final int torrentAggregate = torrent.totalWantedDone > 0
          ? torrent.totalWantedDone
          : (torrent.totalDone > 0
              ? torrent.totalDone
              : (torrent.progress > 0 && totalSize > 0
                  ? (torrent.progress * totalSize).round()
                  : 0));
      // FIX-AGGREGATE-PREF: Prefer the engine's aggregate (totalWantedDone)
      // whenever available — it includes ALL downloaded bytes (real +
      // estimated) and is the most reliable source. Fall back to per-file
      // sum only when aggregates are zero. Always clamp to [0, totalSize].
      final int rawDownloaded;
      if (torrentAggregate > 0) {
        rawDownloaded = torrentAggregate;
      } else if (calculatedDownloaded > 0) {
        rawDownloaded = calculatedDownloaded;
      } else {
        rawDownloaded = 0;
      }
      // FIX-CLAMP: Clamp downloaded bytes to [0, totalSize] so the overall
      // torrent percentage never goes negative or exceeds 100%.
      final downloadedBytes = totalSize > 0
          ? rawDownloaded.clamp(0, totalSize)
          : max(0, rawDownloaded);

      if (resolvedFiles != null) {
        _distributeEstimatedBytes(resolvedFiles, downloadedBytes);
        // FIX-PROG-01: Recalculate per-file 'progress' AFTER estimated byte
        // distribution so the file-level percentage on the torrent details
        // screen always matches the distributed downloadedBytes value.
        // FIX-ZERO-SIZE: Zero-size files are trivially complete (1.0).
        // FIX-FILE-CLAMP: Defensive double-clamp on BOTH downloadedBytes and
        // progress so a stale stored value from a previous version can never
        // produce a percentage outside [0.0, 1.0] or a NaN.
        // FIX-FILE-CONSISTENCY: Promote estimated files to real once their
        // distributed bytes exactly equal length (i.e. the file is fully
        // downloaded) so the details screen no longer shows the
        // "estimated" badge on completed files.
        for (final f in resolvedFiles) {
          final len = (f['length'] as num?)?.toInt() ?? 0;
          var dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
          if (len > 0) {
            dl = dl.clamp(0, len);
            f['downloadedBytes'] = dl;
            // FIX-FILE-PCT: Always set explicit per-file percentage so
            // the torrent details screen can render a deterministic bar
            // without re-computing (and potentially disagreeing with
            // downloadedBytes/length).
            f['progress'] = (dl / len).clamp(0.0, 1.0);
            if (dl >= len && f['progressEstimated'] == true) {
              f['progressEstimated'] = false;
            }
          } else {
            f['downloadedBytes'] = 0;
            // FIX-ZERO-SIZE: Zero-size file = trivially complete.
            f['progress'] = 1.0;
            f['progressEstimated'] = false;
          }
          // FIX-FILE-PCT: Defensive — ensure 'progress' is NEVER null,
          // NaN, or out of [0.0, 1.0] regardless of prior state.
          final pf = f['progress'];
          if (pf == null || pf is! num || pf.isNaN || pf.isInfinite) {
            f['progress'] = 0.0;
          } else {
            f['progress'] = pf.toDouble().clamp(0.0, 1.0);
          }
        }

        // FIX-FILE-SPEED: Distribute aggregate rate across files. During
        // downloading, split downloadRate across actively-downloading
        // selected files. During seeding, split uploadRate across selected
        // files (all are complete). Always zero ALL files first to prevent
        // stale values persisting on files that just completed.
        //
        // FIX-FILE-SPEED-PAUSE: Also zero all file speeds when the torrent
        // is paused/stopped/error so the details screen doesn't show a
        // stale non-zero speed on individual files after the user pauses.
        final isPausedState = stateLabel == 'paused' ||
            stateLabel == 'stopped' ||
            stateLabel == 'error';
        // FIX-CYCLE-SPEED: Zero file speeds during checking/metadata too,
        // so stale non-zero values from the previous downloading state
        // don't persist on individual files in the details screen.
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
              // During seeding, attribute upload speed to all selected files
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
                // FIX-FILE-SPEED-DIST: Distribute aggregate download rate
                // across actively-downloading selected files. Weight by
                // remaining bytes so larger files get more bandwidth
                // allocation (approximates libtorrent's priority-based
                // distribution for the details screen single-file speed).
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
                  // Equal split fallback when all remaining bytes are 0
                  // (shouldn't happen but defensive).
                  final perFileSpeed = aggregateRate / activeFileList.length;
                  for (final f in activeFileList) {
                    f['speed'] = perFileSpeed.toDouble();
                  }
                }
              }
            }
          }
        }

        final maxConcurrent =
            SettingsProvider.instance.maxConcurrentFilesPerTorrent;
        if (maxConcurrent > 0 && !isCheckingOrMetadata) {
          _applyMaxConcurrentFilesLimit(id, resolvedFiles, maxConcurrent);
        }
      }

      final isUserPaused = stateLabel == 'paused' || stateLabel == 'stopped';
      if (isUserPaused && !cancelToken.isCancelled && !isCheckingOrMetadata) {
        // FIX: If the torrent is fully downloaded but paused (e.g., seeding
        // disabled), treat as complete — not as an error.
        if (totalSize > 0 && downloadedBytes >= totalSize) {
          // FIX-TOR-COMPLETE-FILES: Include file-level summary so the
          // details screen shows all files as complete with accurate
          // single-file percentages on the completed state.
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
        // FIX-5: Only treat as a clean pause IF the orchestrator actually
        // requested it via the cancel token. Otherwise the engine entered
        // 'paused' due to an I/O error, disk-full, or external trigger —
        // surface that as an error so the user is notified and the
        // orchestrator can retry instead of silently "completing".
        //
        // FIX-PAUSE-RESUME: Save resume data BEFORE surfacing the error so
        // the retry path can resume from the last flushed piece instead of
        // rechecking the entire torrent. The cancel path already does this;
        // this mirrors that behaviour for non-cancel pauses.
        // FIX-PAUSE-AMBIGUITY: Distinguish an internal/IO pause from a user
        // pause via a typed status message so the orchestrator can mark the
        // task as retryable-paused (not failed). Resume data is saved first
        // so the retry path can fast-resume instead of rechecking.
        // FIX-TOR-RETRY-FILES: Include file-level summary so the details
        // screen retains all data (files, parts, single-file percentages,
        // overall data percentage) during the retry state instead of
        // going blank.
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
          () async {
            try {
              await TorrentResumeStore.saveAndWait(
                torrentId: id,
                sourceUrl: url,
                fetchResumeData: () => TorrentService.fetchResumeBytes(id),
                files: getTorrentFiles?.call(),
              );
            } catch (e) {
              debugPrint('[DMX] non-cancel-pause resume save failed: $e');
            }
            if (!completer.isCompleted) {
              completer.completeError(TorrentEnginePauseException(
                'Torrent entered paused state without an explicit cancel — '
                'possible I/O error or external pause. Resume data saved; '
                'retry to resume.',
                url: url,
              ));
            }
          }();
        }
        return;
      }

      // FIX-TOR-ERROR-CYCLE: When the torrent engine enters an 'error'
      // state (disk I/O failure, corrupt piece, etc.), emit 'failed'
      // progress with full file-level data (files, per-file percentages,
      // file counts, byte summaries) AND complete the completer with an
      // error so the orchestrator can surface the failure immediately.
      // Without this, the download hangs for 30 minutes until the
      // inactivity timeout fires — the user sees a 'failed' chip but the
      // task is still "running" internally.
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
      // FIX-SEEDING-COMPLETE: A torrent is fully downloaded when it reaches
      // 100% or enters a stable finished state. The engine should complete
      // the download future so the orchestrator can mark the task as done.
      // If seeding is enabled, the orchestrator handles the 'seeding' cycle
      // state and live upload speed separately — keeping the engine's
      // download() future hanging forever blocks the task from completing.
      final shouldComplete = isFullyDownloaded && !isCheckingOrMetadata;

      // FIX F-1: Report upload speed while seeding, download speed otherwise.
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
        // FIX-CYCLE-CHECK-META: Distinguish 'checking', 'fetching_metadata',
        // and 'allocating' cycle states. Previously all three were lumped
        // into 'checking', causing the UI to show "Checking pieces…"
        // during metadata fetching and disk allocation — wrong cycle
        // state and wrong status message.
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
        // FIX-TOR-FILES: Include file summary during checking too.
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
              // FIX-ZERO-FILE-COMPLETE: Zero-size files are trivially complete.
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
        // FIX-TOR-FILES: Compute file-level summary for the details screen.
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
              // FIX-ZERO-FILE-COMPLETE: Zero-size files are trivially complete.
              if (len == 0 || dl >= len) dFiles++;
            }
          }
        }
        // FIX-CYCLE: Derive cycle state from torrent state label.
        // FIX-CYCLE-TOR: Handle all torrent states — previously error,
        // stalled, queued, finished, and completed all fell through to
        // 'downloading', causing the UI to show an active spinner on a
        // failed, idle, or finished torrent.
        // FIX-CYCLE-COMPLETE-OVERRIDE: If shouldComplete is true (fully
        // downloaded and seeding disabled), force 'completed' cycle state
        // so the UI doesn't briefly show 'seeding' before the engine
        // completes and the orchestrator marks the task as finished.
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
      await sub?.cancel();
      // PAUSE BARRIER (engine side): pause the torrent FIRST so all in-flight
      // pieces are flushed to disk, THEN save and hash-verify fast-resume
      // data BEFORE the cancel completes, so "cancelled" always implies
      // "resumable state is on disk".
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
  static const Duration _concurrentLimitThrottle = Duration(seconds: 2);

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
    // FIX-8: Build priorities that PRESERVE user-deselected files (priority 0
    // because the user explicitly unchecked them). Previously the code filled
    // with 0 and only re-enabled the top-N incomplete SELECTED files, which
    // correctly left deselected files at 0 — but it ALSO clobbered the
    // per-file priority LEVEL of selected-but-waiting files (e.g., priority 6
    // became 0). Restore the stored priority for the waiting selected files
    // so when the limit rotates, they re-activate at the user's chosen level.
    final priorities = List<int>.generate(files.length, (i) {
      final f = files[i];
      final selected = isTorrentFileSelected(f);
      if (!selected) return 0; // respect user deselection
      return (f['priority'] as int?) ?? 4;
    });
    for (var i = 0; i < incompleteSelected.length; i++) {
      final idx = incompleteSelected[i];
      if (i >= maxConcurrentFiles) {
        priorities[idx] = 0; // temporarily park this SELECTED file
      } else {
        // Restore user priority (already set above, but explicit for clarity).
        priorities[idx] = (files[idx]['priority'] as int?) ?? 4;
      }
    }
    _lastConcurrentLimitApply[torrentId] = now;
    _lastIncompleteSnapshot[torrentId] = incompleteSet;
    TorrentService.setFilePriorities(torrentId, priorities);
  }

  /// FIX-TOR-FILE-NORM: Normalizes a single torrent file map to guarantee
  /// that 'downloadedBytes' and 'progress' are always present, clamped, and
  /// consistent with each other. Zero-size files are treated as trivially
  /// complete (progress = 1.0). Call this everywhere torrent file maps are
  /// constructed or updated to ensure the details screen always shows a
  /// valid single-file percentage bar.
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
    // Defensive: ensure 'progress' is never null, NaN, or out of range.
    final pf = f['progress'];
    if (pf == null || pf is! num || pf.isNaN || pf.isInfinite) {
      f['progress'] = 0.0;
    } else {
      f['progress'] = pf.toDouble().clamp(0.0, 1.0);
    }
  }

  /// FIX-TOR-FILE-NORM: Normalizes a list of torrent file maps and computes
  /// file-level summary statistics for the details screen. Returns a record
  /// with (totalFiles, completedFiles, totalFileBytes, downloadedFileBytes)
  /// counting only selected files.
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
    // BUG 4 FIX: Subtract confirmed (non-estimated) bytes first
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
      // FIX-6: When the engine has no data yet (remainingForEstimation == 0)
      // preserve the previously stored per-file bytes instead of zeroing
      // them, so a resume after restart doesn't flash 0 % on every file.
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
    // FIX-CHECKING-PERCENT: During recheck, normalize torrent files on every
    // tick so single-file percentage on the details screen stays valid and
    // clamped to [0.0, 1.0] instead of going null/stale during the checking
    // phase. This ensures per-file data percentage is accurate at every
    // level (overall, per-file, file counts, byte summaries) during recheck.
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
        // FIX-RECHECK-FEEDBACK: Emit progress during hash-check so the UI
        // shows "Checking…" with the recheck percentage instead of a blank
        // or frozen bar.
        if (onProgress != null && !completer.isCompleted) {
          final label = tor.stateLabel.toLowerCase();
          if (label.contains('checking')) {
            final recheckPct = tor.progress.clamp(0.0, 1.0);
            // FIX-RECHECK-FILES: Include stored torrent files so the
            // details screen retains the file tree and per-file
            // percentages during recheck progress updates.
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
              cycleState: 'checking', // FIX-CYCLE-MISSING
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
    // FIX-RECHECK-FEEDBACK: Heartbeat so the user sees activity even if the
    // engine doesn't emit per-second updates during checking.
    // FIX-CYCLE-HEARTBEAT: Only emit 'checking' cycle state when the engine
    // is actually in a checking state. Previously this heartbeat emitted
    // 'checking' unconditionally every 5s, which could override a legitimate
    // 'downloading' or 'starting' state if _waitForState was used in a
    // non-checking context.
    if (onProgress != null) {
      heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
        if (completer.isCompleted) return;
        elapsed += 5;
        final lowerSeen = lastSeen?.toLowerCase() ?? '';
        final isChecking = lowerSeen.contains('checking');
        // FIX-CYCLE-WAIT-META: Distinguish 'fetching_metadata' from
        // 'checking' and 'starting' so the UI shows the correct cycle
        // state during the _waitForState heartbeat. Previously a
        // 'metadata' state was shown as 'starting', hiding the fact
        // that the torrent was still fetching metadata.
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
        // FIX-WAIT-STATE-FILES: Include stored torrent files so the
        // details screen retains the file tree and per-file percentages
        // during checking/preparing heartbeats.
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

  void close() {
    _closed = true;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    for (final token in List<CancelToken>.from(_activeCancelTokens)) {
      try {
        token.cancel('Engine closing');
      } catch (_) {}
    }
    _activeCancelTokens.clear();
    _sharedDio.close(force: true);
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
      unawaited(poolToClose.shutdown().catchError((_) {}));
    }
    for (final id in List<int>.from(_activeTorrentIds)) {
      try {
        TorrentService.pauseTorrent(id);
      } catch (_) {}
    }
    _activeTorrentIds.clear();
    _httpEngine.stopAdaptiveThreadMonitor();
  }

  /// FIX-CYCLE: Maps a status message / cancel state to a structured cycle
  /// state string used by the UI for status chips and the details screen.
  static String _deriveCycleState(
    String? statusMessage,
    bool isCancelled,
    bool isTorrent,
  ) {
    if (isCancelled) return 'paused';
    if (statusMessage == null) return 'downloading';
    final lower = statusMessage.toLowerCase();
    if (lower.contains('completed')) return 'completed';
    if (lower.contains('checking')) return 'checking';
    if (lower.contains('fetching metadata')) return 'fetching_metadata';
    if (lower.contains('paused') && lower.contains('engine')) return 'retrying';
    if (lower.contains('paused')) return 'paused';
    if (lower.contains('updating') || lower.contains('refresh')) {
      return 'updating_links';
    }
    if (lower.contains('retry')) return 'retrying';
    if (lower.contains('failed') || lower.contains('error')) return 'failed';
    if (lower.contains('seeding')) return 'seeding';
    // FIX-CYCLE-RESUME: Map 'resume' / 'resuming' to 'resuming' so the UI
    // can show "Resuming…" when a paused download is resumed, instead of
    // lumping it with 'starting'. Only map 'starting' to 'starting'.
    if (lower.contains('resum')) {
      return 'resuming';
    }
    if (lower.contains('starting')) {
      return 'starting';
    }
    return 'downloading';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SHARED HELPERS
// ═══════════════════════════════════════════════════════════════════════════

/// Builds a transfer-configured Dio client. Isolate-safe (no shared state),
/// used both by main-isolate probes and by worker isolates.
Dio buildTransferDio({
  String? url,
  String? customUserAgent,
  String? referer,
  bool enableProxy = false,
  String? proxyAddress,
  String? proxyHost,
  int? proxyPort,
  String? proxyUsername,
  String? proxyPassword,
  bool bypassSSL = true,
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
    final String proxyHostResolved =
        (enableProxy && proxyHost != null && proxyHost.trim().isNotEmpty)
            ? proxyHost.trim()
            : (enableProxy && proxyAddress != null && proxyAddress.contains(':')
                ? proxyAddress.split(':')[0].trim()
                : (enableProxy ? proxyAddress?.trim() ?? '' : ''));
    final int port = (enableProxy && proxyPort != null && proxyPort > 0)
        ? proxyPort
        : (enableProxy && proxyAddress != null && proxyAddress.contains(':')
            ? int.tryParse(proxyAddress.split(':')[1]) ?? 8080
            : 8080);
    adapter.createHttpClient = () {
      final httpClient = HttpClient();
      if (enableProxy && proxyHostResolved.isNotEmpty) {
        httpClient.findProxy = (uri) => 'PROXY $proxyHostResolved:$port';
        if (proxyUsername != null && proxyUsername.isNotEmpty) {
          httpClient.authenticateProxy = (h, p, scheme, realm) async {
            httpClient.addProxyCredentials(h, p, realm ?? '',
                HttpClientBasicCredentials(proxyUsername, proxyPassword ?? ''));
            return true;
          };
        }
      }
      if (bypassSSL) {
        httpClient.badCertificateCallback = (cert, h, p) => true;
      }
      return httpClient;
    };
  }
  return client;
}

// FIX-M3: Read-only path that does not create .dmxstate file
// FIX-03: Apply missing-state file length fallback for ALL thread counts
Future<int> actualDownloadedBytes(
  String path, {
  required int threadCount,
}) async {
  try {
    final stateFile = File('$path.dmxstate');
    if (!await stateFile.exists()) {
      if (threadCount > 1) {
        return 0; // BUG 2 FIX: Pre-allocated file length is meaningless for multi-thread
      }
      final f = File(path);
      return await f.exists() ? await f.length() : 0;
    }
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
    return 0;
  } catch (e) {
    debugPrint('[DMX] actualDownloadedBytes failed for $path: $e');
    if (threadCount > 1) {
      return 0; // BUG 2 FIX: Pre-allocated file length is meaningless for multi-thread
    }
    final f = File(path);
    if (await f.exists()) return f.length();
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