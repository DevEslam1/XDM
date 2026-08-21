import 'package:flutter/foundation.dart';
import 'cycle_state.dart';
import 'pause_reason.dart';

export 'cycle_state.dart';
export 'download_request.dart';
export 'pause_reason.dart';
export 'torrent_session_settings.dart';
export 'utils/url_specifications.dart' show TorrentFileSelection, TorrentUriKind;

/// Progress callback signature for download engine operations.
typedef ValueChangedProgress = void Function(DownloadProgress progress);

/// YouTube stream composition types.
enum YtStreamKind { video, audio, combined }

/// Immutable domain metadata describing a resolvable download source.
@immutable
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

  DownloadMetadata copyWith({
    String? fileName,
    String? category,
    int? fileSize,
    bool? supportsResume,
    List<Map<String, dynamic>>? torrentFiles,
    int? torrentId,
    String? etag,
    String? lastModified,
  }) {
    return DownloadMetadata(
      fileName: fileName ?? this.fileName,
      category: category ?? this.category,
      fileSize: fileSize ?? this.fileSize,
      supportsResume: supportsResume ?? this.supportsResume,
      torrentFiles: torrentFiles ?? this.torrentFiles,
      torrentId: torrentId ?? this.torrentId,
      etag: etag ?? this.etag,
      lastModified: lastModified ?? this.lastModified,
    );
  }
}

/// Chunk detail for individual thread progression.
@immutable
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

  ChunkDetail copyWith({
    int? index,
    int? start,
    int? end,
    int? downloaded,
    int? size,
    double? ratio,
  }) {
    return ChunkDetail(
      index: index ?? this.index,
      start: start ?? this.start,
      end: end ?? this.end,
      downloaded: downloaded ?? this.downloaded,
      size: size ?? this.size,
      ratio: ratio ?? this.ratio,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChunkDetail &&
          runtimeType == other.runtimeType &&
          index == other.index &&
          start == other.start &&
          end == other.end &&
          downloaded == other.downloaded &&
          size == other.size &&
          ratio == other.ratio;

  @override
  int get hashCode => Object.hash(index, start, end, downloaded, size, ratio);
}

/// Immutable snapshot representing live transfer state for UI and observers.
@immutable
class DownloadProgress {
  final int downloadedBytes;
  final int fileSize;
  final double speed;
  final int? eta;
  @Deprecated('Use chunkDetails instead')
  final List<double>? chunks;
  final String? fileName;
  final List<Map<String, dynamic>>? torrentFiles;
  final bool? supportsResume;
  final String? statusMessage;
  final int? torrentId;
  final List<ChunkDetail>? chunkDetails;
  final CycleState? cycleState;
  final PauseReason? pauseReason;
  final int? totalChunks;
  final int? completedChunks;
  final int? totalPieces;
  final int? completedPieces;
  final int? totalFiles;
  final int? completedFiles;
  final int? totalFileBytes;
  final int? downloadedFileBytes;
  final YtStreamKind? ytStreamKind;
  final int? ytCounterpartSize;
  final int? ytCounterpartDownloadedBytes;
  final int? ytDownloadedBytes;
  final bool? hasEstimatedFileProgress;
  final int chunkFingerprint;

  const DownloadProgress({
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
    this.chunkDetails,
    this.cycleState,
    this.pauseReason,
    this.totalChunks,
    this.completedChunks,
    this.totalPieces,
    this.completedPieces,
    this.totalFiles,
    this.completedFiles,
    this.totalFileBytes,
    this.downloadedFileBytes,
    this.ytStreamKind,
    this.ytCounterpartSize,
    this.ytCounterpartDownloadedBytes,
    this.ytDownloadedBytes,
    this.hasEstimatedFileProgress,
    this.chunkFingerprint = 0,
  });

  factory DownloadProgress.fromWorkerMap(Map<String, dynamic> p) {
    List<ChunkDetail>? details;
    if (p['chunkDetails'] is List) {
      details = (p['chunkDetails'] as List)
          .whereType<Map>()
          .map((c) => ChunkDetail.fromMap(Map<String, dynamic>.from(c)))
          .toList();
    }
    final rawCycleState = p['cycleState'];
    final CycleState? cycleState = rawCycleState is CycleState
        ? rawCycleState
        : CycleState.fromName(rawCycleState as String?);

    final rawPauseReason = p['pauseReason'];
    final PauseReason? pauseReason = rawPauseReason is PauseReason
        ? rawPauseReason
        : PauseReason.fromName(rawPauseReason as String?);

    return DownloadProgress(
      downloadedBytes: (p['downloadedBytes'] as num?)?.toInt() ?? 0,
      fileSize: (p['fileSize'] as num?)?.toInt() ?? 0,
      speed: (p['speed'] as num?)?.toDouble() ?? 0.0,
      eta: (p['eta'] as num?)?.toInt(),
      chunks:
          p['chunks'] != null ? List<double>.from(p['chunks'] as List) : null,
      fileName: p['fileName'] as String?,
      supportsResume: p['supportsResume'] as bool?,
      statusMessage: p['statusMessage'] as String?,
      torrentId: (p['torrentId'] as num?)?.toInt(),
      chunkDetails: details,
      cycleState: cycleState,
      pauseReason: pauseReason,
      totalChunks: (p['totalChunks'] as num?)?.toInt(),
      completedChunks: (p['completedChunks'] as num?)?.toInt(),
      totalPieces: (p['totalPieces'] as num?)?.toInt(),
      completedPieces: (p['completedPieces'] as num?)?.toInt(),
      totalFiles: (p['totalFiles'] as num?)?.toInt(),
      completedFiles: (p['completedFiles'] as num?)?.toInt(),
      totalFileBytes: (p['totalFileBytes'] as num?)?.toInt(),
      downloadedFileBytes: (p['downloadedFileBytes'] as num?)?.toInt(),
      ytStreamKind: p['ytStreamKind'] is YtStreamKind
          ? p['ytStreamKind'] as YtStreamKind
          : null,
      ytCounterpartSize: (p['ytCounterpartSize'] as num?)?.toInt(),
      ytCounterpartDownloadedBytes:
          (p['ytCounterpartDownloadedBytes'] as num?)?.toInt(),
      ytDownloadedBytes: (p['ytDownloadedBytes'] as num?)?.toInt(),
      hasEstimatedFileProgress: p['hasEstimatedFileProgress'] as bool?,
      chunkFingerprint: (p['chunkFingerprint'] as num?)?.toInt() ?? 0,
    );
  }

  double get progress =>
      fileSize > 0 ? (downloadedBytes / fileSize).clamp(0.0, 1.0) : 0.0;

  double get progressRatio =>
      fileSize > 0 ? (downloadedBytes / fileSize).clamp(0.0, 1.0) : 0.0;

  double? get ytCombinedProgress {
    if (ytStreamKind == null) return null;
    if (ytStreamKind == YtStreamKind.combined) {
      return progressRatio;
    }
    if (ytCounterpartSize == null || ytCounterpartSize! <= 0) {
      if (fileSize > 0) {
        final ratio = progressRatio;
        return ratio < 1.0 ? ratio : null;
      }
      return null;
    }
    final cpSize = ytCounterpartSize!;
    final selfSize = fileSize > 0 ? fileSize : 0;
    final totalSize = selfSize + cpSize;
    if (totalSize <= 0) return null;

    final selfDownloaded = ytDownloadedBytes ?? downloadedBytes;
    final cpDownloaded = ytCounterpartDownloadedBytes ?? 0;
    final totalDownloaded = (selfDownloaded > 0 ? selfDownloaded : 0) +
        (cpDownloaded > 0 ? cpDownloaded : 0);
    return (totalDownloaded / totalSize).clamp(0.0, 1.0);
  }

  DownloadProgress copyWith({
    int? downloadedBytes,
    int? fileSize,
    double? speed,
    int? eta,
    List<double>? chunks,
    String? fileName,
    List<Map<String, dynamic>>? torrentFiles,
    bool? supportsResume,
    String? statusMessage,
    int? torrentId,
    List<ChunkDetail>? chunkDetails,
    CycleState? cycleState,
    PauseReason? pauseReason,
    int? totalChunks,
    int? completedChunks,
    int? totalPieces,
    int? completedPieces,
    int? totalFiles,
    int? completedFiles,
    int? totalFileBytes,
    int? downloadedFileBytes,
    YtStreamKind? ytStreamKind,
    int? ytCounterpartSize,
    int? ytCounterpartDownloadedBytes,
    int? ytDownloadedBytes,
    bool? hasEstimatedFileProgress,
    int? chunkFingerprint,
  }) {
    return DownloadProgress(
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      fileSize: fileSize ?? this.fileSize,
      speed: speed ?? this.speed,
      eta: eta ?? this.eta,
      chunks: chunks ?? this.chunks,
      fileName: fileName ?? this.fileName,
      torrentFiles: torrentFiles ?? this.torrentFiles,
      supportsResume: supportsResume ?? this.supportsResume,
      statusMessage: statusMessage ?? this.statusMessage,
      torrentId: torrentId ?? this.torrentId,
      chunkDetails: chunkDetails ?? this.chunkDetails,
      cycleState: cycleState ?? this.cycleState,
      pauseReason: pauseReason ?? this.pauseReason,
      totalChunks: totalChunks ?? this.totalChunks,
      completedChunks: completedChunks ?? this.completedChunks,
      totalPieces: totalPieces ?? this.totalPieces,
      completedPieces: completedPieces ?? this.completedPieces,
      totalFiles: totalFiles ?? this.totalFiles,
      completedFiles: completedFiles ?? this.completedFiles,
      totalFileBytes: totalFileBytes ?? this.totalFileBytes,
      downloadedFileBytes: downloadedFileBytes ?? this.downloadedFileBytes,
      ytStreamKind: ytStreamKind ?? this.ytStreamKind,
      ytCounterpartSize: ytCounterpartSize ?? this.ytCounterpartSize,
      ytCounterpartDownloadedBytes:
          ytCounterpartDownloadedBytes ?? this.ytCounterpartDownloadedBytes,
      ytDownloadedBytes: ytDownloadedBytes ?? this.ytDownloadedBytes,
      hasEstimatedFileProgress:
          hasEstimatedFileProgress ?? this.hasEstimatedFileProgress,
      chunkFingerprint: chunkFingerprint ?? this.chunkFingerprint,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadProgress &&
          runtimeType == other.runtimeType &&
          downloadedBytes == other.downloadedBytes &&
          fileSize == other.fileSize &&
          speed.round() == other.speed.round() &&
          cycleState == other.cycleState &&
          pauseReason == other.pauseReason &&
          totalChunks == other.totalChunks &&
          completedChunks == other.completedChunks &&
          chunkFingerprint == other.chunkFingerprint &&
          listEquals(torrentFiles, other.torrentFiles) &&
          listEquals(chunkDetails, other.chunkDetails);

  @override
  int get hashCode => Object.hash(
        downloadedBytes,
        fileSize,
        speed.round(),
        cycleState,
        pauseReason,
        totalChunks,
        completedChunks,
        chunkFingerprint,
        torrentFiles?.length,
        chunkDetails?.length,
      );
}

/// FIX-22: Structured error model for download telemetry, resilience logging, and UI reporting.
@immutable
class DownloadError {
  final String code;
  final String message;
  final String? detail;
  final String category;
  final DateTime timestamp;
  final String? taskId;

  const DownloadError({
    required this.code,
    required this.message,
    this.detail,
    required this.category,
    required this.timestamp,
    this.taskId,
  });

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
        'detail': detail,
        'category': category,
        'timestamp': timestamp.toIso8601String(),
        'taskId': taskId,
      };

  factory DownloadError.fromJson(Map<String, dynamic> json) => DownloadError(
        code: json['code'] as String? ?? 'UNKNOWN',
        message: json['message'] as String? ?? '',
        detail: json['detail'] as String?,
        category: json['category'] as String? ?? 'unknown',
        timestamp: json['timestamp'] != null
            ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
            : DateTime.now(),
        taskId: json['taskId'] as String?,
      );

  @override
  String toString() =>
      'DownloadError(code: $code, message: $message, category: $category, taskId: $taskId)';
}
