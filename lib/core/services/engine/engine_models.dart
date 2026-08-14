import 'package:flutter/foundation.dart';

typedef ValueChangedProgress = void Function(DownloadProgress progress);

enum YtStreamKind { video, audio, combined }

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

@immutable
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
    this.totalChunks,
    this.completedChunks,
    this.totalFiles,
    this.completedFiles,
    this.totalFileBytes,
    this.downloadedFileBytes,
    this.ytStreamKind,
    this.ytCounterpartSize,
    this.ytCounterpartDownloadedBytes,
    this.ytDownloadedBytes,
  });

  factory DownloadProgress.fromWorkerMap(Map<String, dynamic> p) {
    List<ChunkDetail>? details;
    if (p['chunkDetails'] is List) {
      details = (p['chunkDetails'] as List)
          .whereType<Map>()
          .map((c) => ChunkDetail.fromMap(Map<String, dynamic>.from(c)))
          .toList();
    }
    return DownloadProgress(
      downloadedBytes: (p['downloadedBytes'] as num?)?.toInt() ?? 0,
      fileSize: (p['fileSize'] as num?)?.toInt() ?? 0,
      speed: (p['speed'] as num?)?.toDouble() ?? 0.0,
      eta: (p['eta'] as num?)?.toInt(),
      chunks: p['chunks'] != null ? List<double>.from(p['chunks'] as List) : null,
      fileName: p['fileName'] as String?,
      supportsResume: p['supportsResume'] as bool?,
      statusMessage: p['statusMessage'] as String?,
      torrentId: (p['torrentId'] as num?)?.toInt(),
      chunkDetails: details,
      cycleState: p['cycleState'] as String?,
      totalChunks: (p['totalChunks'] as num?)?.toInt(),
      completedChunks: (p['completedChunks'] as num?)?.toInt(),
      totalFiles: (p['totalFiles'] as num?)?.toInt(),
      completedFiles: (p['completedFiles'] as num?)?.toInt(),
      totalFileBytes: (p['totalFileBytes'] as num?)?.toInt(),
      downloadedFileBytes: (p['downloadedFileBytes'] as num?)?.toInt(),
      ytStreamKind: p['ytStreamKind'] is YtStreamKind ? p['ytStreamKind'] as YtStreamKind : null,
      ytCounterpartSize: (p['ytCounterpartSize'] as num?)?.toInt(),
      ytCounterpartDownloadedBytes: (p['ytCounterpartDownloadedBytes'] as num?)?.toInt(),
      ytDownloadedBytes: (p['ytDownloadedBytes'] as num?)?.toInt(),
    );
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
    String? cycleState,
    int? totalChunks,
    int? completedChunks,
    int? totalFiles,
    int? completedFiles,
    int? totalFileBytes,
    int? downloadedFileBytes,
    YtStreamKind? ytStreamKind,
    int? ytCounterpartSize,
    int? ytCounterpartDownloadedBytes,
    int? ytDownloadedBytes,
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
      totalChunks: totalChunks ?? this.totalChunks,
      completedChunks: completedChunks ?? this.completedChunks,
      totalFiles: totalFiles ?? this.totalFiles,
      completedFiles: completedFiles ?? this.completedFiles,
      totalFileBytes: totalFileBytes ?? this.totalFileBytes,
      downloadedFileBytes: downloadedFileBytes ?? this.downloadedFileBytes,
      ytStreamKind: ytStreamKind ?? this.ytStreamKind,
      ytCounterpartSize: ytCounterpartSize ?? this.ytCounterpartSize,
      ytCounterpartDownloadedBytes: ytCounterpartDownloadedBytes ?? this.ytCounterpartDownloadedBytes,
      ytDownloadedBytes: ytDownloadedBytes ?? this.ytDownloadedBytes,
    );
  }

  double? get ytCombinedProgress {
    if (ytStreamKind == null) return null;
    if (ytCounterpartSize == null) return null;
    final totalSize = fileSize + ytCounterpartSize!;
    if (totalSize == 0) return null;
    final selfDownloaded = ytDownloadedBytes ?? downloadedBytes;
    final cpDownloaded = ytCounterpartDownloadedBytes ?? 0;
    return ((selfDownloaded + cpDownloaded) / totalSize).clamp(0.0, 1.0);
  }

  double get progressRatio {
    if (fileSize <= 0) return 0.0;
    return (downloadedBytes / fileSize).clamp(0.0, 1.0);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadProgress &&
          runtimeType == other.runtimeType &&
          downloadedBytes == other.downloadedBytes &&
          fileSize == other.fileSize &&
          speed == other.speed &&
          eta == other.eta &&
          fileName == other.fileName &&
          supportsResume == other.supportsResume &&
          statusMessage == other.statusMessage &&
          torrentId == other.torrentId &&
          cycleState == other.cycleState &&
          totalChunks == other.totalChunks &&
          completedChunks == other.completedChunks &&
          totalFiles == other.totalFiles &&
          completedFiles == other.completedFiles &&
          totalFileBytes == other.totalFileBytes &&
          downloadedFileBytes == other.downloadedFileBytes &&
          ytStreamKind == other.ytStreamKind &&
          ytCounterpartSize == other.ytCounterpartSize &&
          ytCounterpartDownloadedBytes == other.ytCounterpartDownloadedBytes &&
          ytDownloadedBytes == other.ytDownloadedBytes;

  @override
  int get hashCode => Object.hash(
        downloadedBytes,
        fileSize,
        speed,
        eta,
        fileName,
        statusMessage,
        cycleState,
        torrentId,
        totalChunks,
        completedChunks,
        totalFiles,
        completedFiles,
        totalFileBytes,
        downloadedFileBytes,
        ytStreamKind,
        ytCounterpartSize,
      );
}
