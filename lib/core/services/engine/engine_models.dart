// FIX: P0-01 — Engine Models for DMX Download Engine

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
}
