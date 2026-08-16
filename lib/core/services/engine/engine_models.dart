import 'package:flutter/foundation.dart';
import '../../../features/downloads/models/cycle_state.dart';
import '../../../features/downloads/models/pause_reason.dart';
import '../download_journal.dart';

export '../../../features/downloads/models/cycle_state.dart';
export '../../../features/downloads/models/pause_reason.dart';

typedef ValueChangedProgress = void Function(DownloadProgress progress);

/// Typed kinds of engine IPC messages exchanged with the download worker.
///
/// Wire format stays as the string [name] for isolate compatibility; the enum
/// gives compile-time checking on the host side.
enum EngineMessageType {
  progress,
  done,
  error,
  hello,
  idle,
  limits,
  job,
  cancel,
  shutdown;

  static EngineMessageType? fromWire(Object? value) {
    if (value is! String) return null;
    for (final t in EngineMessageType.values) {
      if (t.name == value) return t;
    }
    return null;
  }
}

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
      chunks: p['chunks'] != null ? List<double>.from(p['chunks'] as List) : null,
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
      ytCounterpartDownloadedBytes: ytCounterpartDownloadedBytes ?? this.ytCounterpartDownloadedBytes,
      ytDownloadedBytes: ytDownloadedBytes ?? this.ytDownloadedBytes,
    );
  }

  double? get ytCombinedProgress {
    if (ytStreamKind == null) return null;
    final cpSize = ytCounterpartSize;
    if (cpSize == null || cpSize < 0) return null;
    final totalSize = fileSize + cpSize;
    if (totalSize <= 0) return null;
    final selfDownloaded = ytDownloadedBytes ?? downloadedBytes;
    final cpDownloaded = ytCounterpartDownloadedBytes ?? 0;
    return ((selfDownloaded + cpDownloaded) / totalSize).clamp(0.0, 1.0);
  }

  double get progressRatio {
    if (fileSize <= 0) return 0.0;
    return (downloadedBytes / fileSize).clamp(0.0, 1.0);
  }

  static int _computeChunkDetailsHash(List<ChunkDetail>? details) {
    if (details == null) return 0;
    return details.fold<int>(details.length, (h, c) => h ^ c.downloaded.hashCode);
  }

  static int _computeTorrentFilesHash(List<Map<String, dynamic>>? files) {
    if (files == null) return 0;
    return files.fold<int>(
      files.length,
      (h, f) => h ^ ((f['downloadedBytes'] as num?)?.toInt() ?? 0).hashCode,
    );
  }

  static bool _areChunkDetailsEqual(List<ChunkDetail>? a, List<ChunkDetail>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    return _computeChunkDetailsHash(a) == _computeChunkDetailsHash(b);
  }

  static bool _areTorrentFilesEqual(
      List<Map<String, dynamic>>? a, List<Map<String, dynamic>>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    return _computeTorrentFilesHash(a) == _computeTorrentFilesHash(b);
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
          pauseReason == other.pauseReason &&
          totalChunks == other.totalChunks &&
          completedChunks == other.completedChunks &&
          totalPieces == other.totalPieces &&
          completedPieces == other.completedPieces &&
          totalFiles == other.totalFiles &&
          completedFiles == other.completedFiles &&
          totalFileBytes == other.totalFileBytes &&
          downloadedFileBytes == other.downloadedFileBytes &&
          ytStreamKind == other.ytStreamKind &&
          ytCounterpartSize == other.ytCounterpartSize &&
          ytCounterpartDownloadedBytes == other.ytCounterpartDownloadedBytes &&
          ytDownloadedBytes == other.ytDownloadedBytes &&
          _areChunkDetailsEqual(chunkDetails, other.chunkDetails) &&
          _areTorrentFilesEqual(torrentFiles, other.torrentFiles);

  @override
  int get hashCode => Object.hash(
        downloadedBytes,
        fileSize,
        speed,
        eta,
        fileName,
        statusMessage,
        cycleState,
        pauseReason,
        torrentId,
        totalChunks,
        completedChunks,
        totalPieces,
        completedPieces,
        totalFiles,
        completedFiles,
        totalFileBytes,
        downloadedFileBytes,
        ytStreamKind,
        ytCounterpartSize,
        Object.hash(
          ytCounterpartDownloadedBytes,
          ytDownloadedBytes,
          _computeChunkDetailsHash(chunkDetails),
          _computeTorrentFilesHash(torrentFiles),
        ),
      );
}

@immutable
class ChunkResult {
  const ChunkResult({
    required this.chunk,
    required this.success,
    this.error,
    this.stackTrace,
    this.attempts = 1,
  });

  final ChunkState chunk;
  final bool success;
  final Object? error;
  final StackTrace? stackTrace;
  final int attempts;
}

@immutable
class DownloadCommand {
  const DownloadCommand({
    required this.taskId,
    required this.url,
    required this.punyUrl,
    required this.tempFilePath,
    required this.localFilePath,
    required this.knownFileSize,
    required this.supportsResume,
    required this.threadCount,
    this.isNameAutoGenerated = false,
    this.adaptiveThreads = false,
    int? speedLimit,
    int? activeCount,
    int initialSpeedLimit = 0,
    int initialActiveCount = 1,
    int speedLimitKbps = 0,
    this.customUserAgent,
    this.referer,
    this.cookies,
    this.oauthToken,
    this.mirrorUrls,
    this.resolvedFileName,
    this.ytStreamKind,
    this.ytCounterpartSize,
    this.ytCounterpartDownloadedBytes,
    this.ytCounterpartTaskId,
    this.throttleFactor = 1.0,
  })  : initialSpeedLimit = speedLimit ?? initialSpeedLimit,
        initialActiveCount = activeCount ?? initialActiveCount,
        speedLimitKbps = speedLimit ?? speedLimitKbps;

  final double throttleFactor;
  final String taskId;
  final String url;
  final String punyUrl;
  final String tempFilePath;
  final String localFilePath;
  final int knownFileSize;
  final bool supportsResume;
  final int threadCount;
  final String? customUserAgent;
  final String? referer;
  final String? cookies;
  final String? oauthToken;
  final bool isNameAutoGenerated;
  final int initialSpeedLimit;
  final int initialActiveCount;
  final int speedLimitKbps;
  final List<String>? mirrorUrls;
  final bool adaptiveThreads;
  final String? resolvedFileName;
  final YtStreamKind? ytStreamKind;
  final int? ytCounterpartSize;
  final int? ytCounterpartDownloadedBytes;
  final String? ytCounterpartTaskId;

  Map<String, dynamic> toMap() => {
        'taskId': taskId,
        'url': url,
        'punyUrl': punyUrl,
        'tempFilePath': tempFilePath,
        'localFilePath': localFilePath,
        'knownFileSize': knownFileSize,
        'supportsResume': supportsResume,
        'threadCount': threadCount,
        'customUserAgent': customUserAgent,
        'referer': referer,
        'cookies': cookies,
        'oauthToken': oauthToken,
        'isNameAutoGenerated': isNameAutoGenerated,
        'initialSpeedLimit': initialSpeedLimit,
        'initialActiveCount': initialActiveCount,
        'speedLimitKbps': speedLimitKbps,
        'mirrorUrls': mirrorUrls,
        'adaptiveThreads': adaptiveThreads,
        'resolvedFileName': resolvedFileName,
        if (ytStreamKind != null) 'ytStreamKind': ytStreamKind!.name,
        if (ytCounterpartSize != null) 'ytCounterpartSize': ytCounterpartSize,
        if (ytCounterpartDownloadedBytes != null)
          'ytCounterpartDownloadedBytes': ytCounterpartDownloadedBytes,
        if (ytCounterpartTaskId != null)
          'ytCounterpartTaskId': ytCounterpartTaskId,
        'throttleFactor': throttleFactor,
      };

  factory DownloadCommand.fromMap(Map<String, dynamic> m) => DownloadCommand(
        taskId: m['taskId'] as String,
        url: m['url'] as String,
        punyUrl: m['punyUrl'] as String,
        tempFilePath: m['tempFilePath'] as String,
        localFilePath: m['localFilePath'] as String,
        knownFileSize: (m['knownFileSize'] as num?)?.toInt() ?? 0,
        supportsResume: m['supportsResume'] as bool? ?? false,
        threadCount: (m['threadCount'] as num?)?.toInt() ?? 1,
        customUserAgent: m['customUserAgent'] as String?,
        referer: m['referer'] as String?,
        cookies: m['cookies'] as String?,
        oauthToken: m['oauthToken'] as String?,
        isNameAutoGenerated: m['isNameAutoGenerated'] as bool? ?? false,
        initialSpeedLimit: (m['initialSpeedLimit'] as num?)?.toInt() ?? 0,
        initialActiveCount: (m['initialActiveCount'] as num?)?.toInt() ?? 1,
        speedLimitKbps: (m['speedLimitKbps'] as num?)?.toInt() ?? 0,
        mirrorUrls: (m['mirrorUrls'] as List?)?.cast<String>(),
        adaptiveThreads: m['adaptiveThreads'] as bool? ?? false,
        resolvedFileName: m['resolvedFileName'] as String?,
        throttleFactor: (m['throttleFactor'] as num?)?.toDouble() ?? 1.0,
        ytStreamKind: m['ytStreamKind'] != null
            ? YtStreamKind.values.firstWhere(
                (k) => k.name == m['ytStreamKind'],
                orElse: () => YtStreamKind.combined,
              )
            : null,
        ytCounterpartSize: (m['ytCounterpartSize'] as num?)?.toInt(),
        ytCounterpartDownloadedBytes:
            (m['ytCounterpartDownloadedBytes'] as num?)?.toInt(),
        ytCounterpartTaskId: m['ytCounterpartTaskId'] as String?,
      );
}

/// A single (timestamp, bytes) pair captured for speed measurement.
class SpeedSample {
  final int timestampMs;
  final int bytes;
  SpeedSample(this.timestampMs, this.bytes);
}
