import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../core/services/crash_reporting_service.dart';
import '../../../core/services/engine/engine_models.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/url_utils.dart';
import 'download_state_machine.dart';

export '../../../core/services/engine/engine_models.dart' show HttpPartStatus;
export 'cycle_state.dart';
export 'pause_reason.dart';

/// Public status message constants used throughout the download pipeline.
/// Extracted here for i18n readiness — replace with localized strings when
/// internationalization is added.
abstract final class DownloadStatusMessages {
  static const merging = 'Merging video and audio...';
  static const waitingWifi = 'Waiting for WiFi connection';
  static const waitingNetwork = 'Waiting for network connection...';
  static const pausedOrphaned =
      'Paused because XDM was closed during a foreground download.';
  static const ffmpegMergeFailed = 'FFmpeg merge failed: ';
  static const mergeFailedVideoOnly = 'Merged audio failed - saved video only';
  static const forbidden = 'Forbidden';
}

enum FailureCategory {
  network,
  serverError,
  authError,
  diskFull,
  integrityError,
  fileChanged,
  mergeFailed,
  torrentError,
  unknown,
}

/// Human-readable recovery suggestions keyed by [FailureCategory].
/// Kept centralized so the engine, provider and UI share one source of truth.
abstract final class RecoveryHints {
  static String hintFor(FailureCategory category) {
    return switch (category) {
      FailureCategory.network => 'Check your internet connection and retry.',
      FailureCategory.serverError =>
        'Server is temporarily unavailable. Retry in a few minutes.',
      FailureCategory.authError =>
        'URL expired. Tap retry to refresh the link.',
      FailureCategory.diskFull => 'Free up storage space and retry.',
      FailureCategory.integrityError =>
        'File corrupted on server. Restart download.',
      FailureCategory.fileChanged =>
        'File changed on server. Restart download.',
      FailureCategory.mergeFailed => 'Merge failed. Tap retry to re-attempt.',
      FailureCategory.torrentError => 'Torrent engine error. Tap retry.',
      FailureCategory.unknown =>
        'Unexpected error. Check diagnostics and retry.',
    };
  }

  /// Maps an [ErrorFamily] (from [ErrorTaxonomy]) onto a [FailureCategory].
  static FailureCategory fromFamily(String familyName) {
    return switch (familyName) {
      'network' => FailureCategory.network,
      'timeout' => FailureCategory.network,
      'server' => FailureCategory.serverError,
      'auth' => FailureCategory.authError,
      'disk' => FailureCategory.diskFull,
      'integrity' => FailureCategory.integrityError,
      'parse' => FailureCategory.integrityError,
      'cancelled' => FailureCategory.unknown,
      _ => FailureCategory.unknown,
    };
  }

  /// Derives a [FailureCategory] directly from a raw thrown object, covering
  /// the DMX-specific exceptions plus common Dio/network cases. Falls back to
  /// [FailureCategory.unknown].
  static FailureCategory fromError(Object error) {
    final rep = error.toString();
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return FailureCategory.network;
        case DioExceptionType.cancel:
          return FailureCategory.unknown;
        case DioExceptionType.badResponse:
          final status = error.response?.statusCode;
          if (status == 403 || status == 410) {
            return FailureCategory.authError;
          }
          if (status != null && status >= 500) {
            return FailureCategory.serverError;
          }
          return FailureCategory.serverError;
        default:
          return FailureCategory.network;
      }
    }
    if (rep.contains('InsufficientStorageException') ||
        rep.toLowerCase().contains('no space left')) {
      return FailureCategory.diskFull;
    }
    if (rep.contains('DownloadIntegrityException') ||
        rep.toLowerCase().contains('file changed on server') ||
        rep.contains('_FileChangedOnServerException')) {
      return FailureCategory.integrityError;
    }
    if (rep.toLowerCase().contains('merge failed') ||
        rep.contains('MERGE_FAILED') ||
        rep.toLowerCase().contains('ffmpeg')) {
      return FailureCategory.mergeFailed;
    }
    if (rep.contains('TorrentEnginePauseException') ||
        rep.toLowerCase().contains('torrent')) {
      return FailureCategory.torrentError;
    }
    if (rep.contains('UrlExpiredException') ||
        rep.toLowerCase().contains('expired') ||
        rep.toLowerCase().contains('forbidden')) {
      return FailureCategory.authError;
    }
    if (rep.toLowerCase().contains('dns') ||
        rep.toLowerCase().contains('socketexception') ||
        rep.toLowerCase().contains('handshakeexception')) {
      return FailureCategory.network;
    }
    return FailureCategory.unknown;
  }
}

enum DownloadStatus {
  queued,
  downloading,
  paused,
  completed,
  failed,
  merging
}

enum SortOption { dateAdded, fileSize, fileName, status, manual }

@immutable
class DownloadTaskCore {
  final String id;
  final String fileName;
  final String url;
  final int fileSize;
  final String category;
  final String savePath;
  final String localFilePath;
  final String tempFilePath;
  final DateTime createdAt;
  final bool supportsResume;
  final bool isAppUpdate;
  final int priority;
  final String? playlistId;
  final String? playlistTitle;
  final String? expectedSha256;

  const DownloadTaskCore({
    required this.id,
    required this.fileName,
    required this.url,
    required this.fileSize,
    required this.category,
    required this.savePath,
    required this.localFilePath,
    required this.tempFilePath,
    required this.createdAt,
    this.supportsResume = false,
    this.isAppUpdate = false,
    this.priority = 0,
    this.playlistId,
    this.playlistTitle,
    this.expectedSha256,
  });
}

@immutable
class DownloadTaskProgress {
  final int downloadedBytes;
  final double speed;
  final int? eta;
  final DownloadStatus status;
  final CycleState? cycleState;
  final PauseReason? pauseReason;
  final String? statusMessage;
  final String? errorMessage;
  final int totalChunks;
  final int completedChunks;
  final double progressRatio;

  const DownloadTaskProgress({
    required this.downloadedBytes,
    required this.speed,
    this.eta,
    required this.status,
    this.cycleState,
    this.pauseReason,
    this.statusMessage,
    this.errorMessage,
    this.totalChunks = 0,
    this.completedChunks = 0,
    this.progressRatio = 0.0,
  });
}

class DownloadTask {
  final String id;
  final String fileName;
  final String url;
  final int fileSize;
  final int downloadedBytes;
  final double speed;
  final int? eta;
  final String category;
  final DownloadStatus status;
  final String savePath;
  final String localFilePath;
  final String tempFilePath;
  final String? errorMessage;
  final String? statusMessage;
  final FailureCategory? failureCategory;
  final String? recoveryHint;
  final int threadCount;
  final List<double> chunks;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final DateTime? scheduledAt;
  final DateTime? wasScheduledAt;
  final bool supportsResume;
  final int speedLimitKbps;
  final bool seedingEnabled;
  final bool seedingLimited;
  final int seedingLimitKbps;
  final List<Map<String, dynamic>>? torrentFiles;
  final String? downloadPageUrl;
  final String? mergedAudioUrl;
  final int audioSize;
  final int videoStreamSize;
  final double audioProgress;
  final int audioThreadCount;
  final bool pausedByUser;
  final bool isCancelled;
  final String? youtubeQualityPreset;
  final String? notes;
  final bool isAppUpdate;
  final int priority;
  final int queueOrder;
  final String? playlistId;
  final String? playlistTitle;
  final String? thumbnailUrl;
  final String? expectedSha256;
  final List<String>? mirrorUrls;

  // Smart Site Intelligence fields
  final String? siteType;
  final String? siteDisplayName;
  final String? contentHint;

  final PauseReason? pauseReason;
  final int? totalPieces;
  final int? completedPieces;
  final int? ytCounterpartDownloadedBytes;
  final CycleState? cycleState;
  final CycleState? previousCycleState;
  final int? totalFiles;
  final int? completedFiles;
  final int? totalFileBytes;
  final int? downloadedFileBytes;

  final bool isMergeInProgress;

  // FIX 1.1, FIX 1.2, FIX 1.3, FIX 1.4: Additional data tracking fields
  final int audioDownloadedBytes;
  final List<double> audioChunks;
  final double? torrentPieceProgress;
  final List<HttpPartStatus>? httpParts;
  final int? audioChunksCompleted;
  final int? audioChunksTotal;
  final int? httpPartsCompleted;
  final int? httpPartsTotal;
  final int uploadedBytes;

  DownloadTask({
    required this.id,
    required this.fileName,
    required this.url,
    required this.fileSize,
    required this.downloadedBytes,
    this.speed = 0.0,
    this.eta,
    required this.category,
    required this.status,
    required this.savePath,
    required this.localFilePath,
    required this.tempFilePath,
    this.errorMessage,
    this.statusMessage,
    this.failureCategory,
    this.recoveryHint,
    required this.threadCount,
    required this.chunks,
    required this.createdAt,
    required this.updatedAt,
    this.completedAt,
    this.scheduledAt,
    this.wasScheduledAt,
    this.supportsResume = false,
    this.speedLimitKbps = 0,
    this.seedingEnabled = false,
    this.seedingLimited = false,
    this.seedingLimitKbps = 500,
    this.uploadedBytes = 0,
    this.torrentFiles,
    this.downloadPageUrl,
    this.mergedAudioUrl,
    this.audioSize = 0,
    this.videoStreamSize = 0,
    this.audioProgress = 0.0,
    this.audioDownloadedBytes = 0,
    this.audioThreadCount = 2,
    List<double>? audioChunks,
    this.torrentPieceProgress,
    this.httpParts,
    this.audioChunksCompleted,
    this.audioChunksTotal,
    this.httpPartsCompleted,
    this.httpPartsTotal,
    this.isMergeInProgress = false,
    this.pausedByUser = false,
    this.isCancelled = false,
    this.youtubeQualityPreset,
    this.notes,
    this.isAppUpdate = false,
    this.priority = 0,
    this.queueOrder = 0,
    this.playlistId,
    this.playlistTitle,
    this.thumbnailUrl,
    this.expectedSha256,
    this.mirrorUrls,
    this.siteType,
    this.siteDisplayName,
    this.contentHint,
    this.pauseReason,
    this.totalPieces,
    this.completedPieces,
    this.ytCounterpartDownloadedBytes,
    this.cycleState,
    this.previousCycleState,
    this.totalFiles,
    this.completedFiles,
    this.totalFileBytes,
    this.downloadedFileBytes,
  }) : audioChunks = audioChunks ??
            List<double>.filled(audioThreadCount > 0 ? audioThreadCount : 2, 0.0);

  DownloadTaskCore get core => DownloadTaskCore(
        id: id,
        fileName: fileName,
        url: url,
        fileSize: fileSize,
        category: category,
        savePath: savePath,
        localFilePath: localFilePath,
        tempFilePath: tempFilePath,
        createdAt: createdAt,
        supportsResume: supportsResume,
        isAppUpdate: isAppUpdate,
        priority: priority,
        playlistId: playlistId,
        playlistTitle: playlistTitle,
        expectedSha256: expectedSha256,
      );

  double get progressRatio => progress < 0 ? 0.0 : progress;

  DownloadTaskProgress get progressSnapshot => DownloadTaskProgress(
        downloadedBytes: downloadedBytes,
        speed: speed,
        eta: eta,
        status: status,
        cycleState: cycleState,
        pauseReason: pauseReason,
        statusMessage: statusMessage,
        errorMessage: errorMessage,
        totalChunks: chunks.length,
        completedChunks: chunks.where((c) => c >= 1.0).length,
        progressRatio: progressRatio,
      );

  bool get isTorrent => isTorrentUrl(url, fileName: fileName);

  bool get isPlaylistItem => playlistId != null && playlistId!.isNotEmpty;

  int get resolvedFileSize {
    if (fileSize < 0) return 0;
    if (isTorrent && torrentFiles != null && torrentFiles!.isNotEmpty) {
      final sum = torrentFiles!
          .where((f) => isTorrentFileSelected(f))
          .fold<int>(0, (s, f) => s + (((f['length'] ?? f['size']) as num?)?.toInt() ?? 0));
      if (sum > 0) return sum;
    }
    if (fileSize > 0) return fileSize;
    if (isTorrent && totalFileBytes != null && totalFileBytes! > 0) {
      return totalFileBytes!;
    }
    return 0;
  }

  bool get hasUnknownSize => resolvedFileSize <= 0;

  // FIX 3.8: Dual-leg YouTube progress getters
  double get videoProgressPercent {
    final vSize = videoStreamSize > 0
        ? videoStreamSize
        : (fileSize > audioSize && audioSize > 0
            ? fileSize - audioSize
            : fileSize);
    if (vSize <= 0) return 0.0;
    return (downloadedBytes / vSize).clamp(0.0, 1.0);
  }

  double get audioProgressPercent {
    if (audioSize > 0 && audioDownloadedBytes > 0) {
      return (audioDownloadedBytes / audioSize).clamp(0.0, 1.0);
    }
    return audioProgress.clamp(0.0, 1.0);
  }

  double get combinedProgressPercent => progress.clamp(0.0, 1.0);

  String get videoChunksSummary =>
      '${chunks.where((c) => c >= 1.0).length}/${chunks.length}';

  String get audioChunksSummary =>
      '${audioChunks.where((c) => c >= 1.0).length}/${audioChunks.length}';

  String get audioProgressString =>
      '${(audioProgressPercent * 100).toStringAsFixed(1)}%';

  bool get isAudioComplete =>
      audioProgress >= 0.999 ||
      (audioSize > 0 && audioDownloadedBytes >= audioSize);

  double get seedingRatio {
    if (downloadedBytes <= 0) return 0.0;
    return uploadedBytes / downloadedBytes;
  }

  bool get isTotalSizePartial =>
      hasMergedAudio && fileSize <= 0 && audioSize > 0;

  bool get waitingWifi =>
      errorMessage == DownloadStatusMessages.waitingWifi ||
      statusMessage == DownloadStatusMessages.waitingWifi;

  bool get waitingNetwork =>
      errorMessage == DownloadStatusMessages.waitingNetwork ||
      statusMessage == DownloadStatusMessages.waitingNetwork;

  bool get hasTorrentFiles => torrentFiles != null && torrentFiles!.isNotEmpty;

  ({int totalFileBytes, int downloadedFileBytes}) get torrentFileAggregates {
    if (torrentFiles == null || torrentFiles!.isEmpty) {
      return (totalFileBytes: 0, downloadedFileBytes: 0);
    }
    int total = 0;
    int dl = 0;
    for (final f in torrentFiles!) {
      if (isTorrentFileSelected(f)) {
        final len = ((f['length'] ?? f['size']) as num?)?.toInt() ?? 0;
        final d = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        total += len;
        if (d >= 0) dl += d;
      }
    }
    return (totalFileBytes: total, downloadedFileBytes: dl);
  }

  double get torrentOverallPercent {
    final agg = torrentFileAggregates;
    if (agg.totalFileBytes > 0) {
      final dl = agg.downloadedFileBytes.clamp(0, agg.totalFileBytes);
      return (dl / agg.totalFileBytes).clamp(0.0, 1.0);
    }
    if (fileSize > 0) {
      return (downloadedBytes / fileSize).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  // FIX 1.3, FIX 4.8: Torrent Piece & File Progress getters
  String get torrentOverallPercentString =>
      '${(torrentOverallPercent * 100).toStringAsFixed(1)}%';

  String get torrentPiecePercentString {
    if (torrentPieceProgress != null) {
      return '${(torrentPieceProgress! * 100).toStringAsFixed(1)}%';
    }
    if (totalPieces != null && totalPieces! > 0 && completedPieces != null) {
      final frac = (completedPieces! / totalPieces!).clamp(0.0, 1.0);
      return '${(frac * 100).toStringAsFixed(1)}%';
    }
    return '0.0%';
  }

  int get torrentCompletedFilesCount {
    if (completedFiles != null) return completedFiles!;
    if (torrentFiles != null) {
      return torrentFiles!.where((f) {
        final len = ((f['length'] ?? f['size']) as num?)?.toInt() ?? 0;
        final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        return len == 0 || dl >= len;
      }).length;
    }
    return 0;
  }

  int get torrentTotalFilesCount =>
      totalFiles ?? (torrentFiles?.length ?? 0);

  List<({String fileName, int downloadedBytes, int totalBytes, double percent, bool isComplete})>
      get torrentFileProgressSummary {
    if (torrentFiles == null || torrentFiles!.isEmpty) return [];
    return torrentFiles!.map((f) {
      final name = (f['name'] as String?) ?? 'file';
      final len = ((f['length'] ?? f['size']) as num?)?.toInt() ?? 0;
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final percent = len > 0 ? (dl / len).clamp(0.0, 1.0) : 0.0;
      final complete = len > 0 ? dl >= len : false;
      return (
        fileName: name,
        downloadedBytes: dl,
        totalBytes: len,
        percent: percent,
        isComplete: complete,
      );
    }).toList();
  }

  // FIX 1.4: HTTP Part Summary getter
  ({int totalParts, int completedParts, int totalBytes, int downloadedBytes})
      get httpPartsSummary {
    if (httpParts != null && httpParts!.isNotEmpty) {
      final totalP = httpParts!.length;
      final completedP = httpParts!.where((p) => p.isComplete).length;
      final totalB = resolvedFileSize;
      final dlB = httpParts!.fold<int>(0, (s, p) => s + p.downloadedBytes);
      return (
        totalParts: totalP,
        completedParts: completedP,
        totalBytes: totalB,
        downloadedBytes: dlB,
      );
    }
    final chunksCount = chunks.length;
    final completedC = chunks.where((c) => c >= 1.0).length;
    return (
      totalParts: chunksCount > 0 ? chunksCount : threadCount,
      completedParts: completedC,
      totalBytes: resolvedFileSize,
      downloadedBytes: downloadedBytes,
    );
  }

  int get combinedTotalSize {
    if (hasMergedAudio && audioSize > 0) {
      if (videoStreamSize > 0) return videoStreamSize + audioSize;
      if (fileSize > audioSize) return fileSize;
      if (fileSize > 0) return fileSize;
      if (downloadedBytes > 0) return downloadedBytes + audioSize;
      return 0;
    }
    if (hasMergedAudio && audioSize == 0 && fileSize > 0) {
      return fileSize;
    }
    return resolvedFileSize;
  }

  int get combinedDownloadedBytes {
    final total = combinedTotalSize;
    var raw = downloadedBytes < 0 ? 0 : downloadedBytes;
    if (hasMergedAudio) {
      final videoOnly = videoStreamSize > 0
          ? videoStreamSize
          : (fileSize > audioSize ? fileSize - audioSize : 0);
      final audioBytes = audioDownloadedBytes > 0
          ? audioDownloadedBytes
          : (audioSize > 0 ? (audioProgress * audioSize).round() : 0);
      if (videoOnly > 0) {
        if (raw < videoOnly) {
          raw += audioBytes;
        } else {
          raw = videoOnly + audioBytes;
        }
      } else {
        raw += audioBytes;
      }
    }
    if (total > 0) return raw.clamp(0, total);
    return raw;
  }

  List<double> get sanitizedChunks {
    final count = threadCount > 0 ? threadCount : 1;
    double safe(double c) =>
        (c.isNaN || c.isInfinite) ? 0.0 : c.clamp(0.0, 1.0);

    if (chunks.length == count) return chunks.map(safe).toList();
    if (chunks.isEmpty) {
      final frac = fileSize > 0
          ? (displayDownloadedBytes / fileSize).clamp(0.0, 1.0)
          : 0.0;
      return List.filled(count, frac);
    }
    if (chunks.length < count) {
      final existing = chunks.map(safe).toList();
      final avg = existing.isEmpty
          ? 0.0
          : existing.reduce((a, b) => a + b) / existing.length;
      return [
        ...existing,
        ...List.filled(count - existing.length, avg.clamp(0.0, 1.0))
      ];
    }
    final totalProgress = chunks.fold<double>(0, (s, c) => s + safe(c));
    final perChunk = totalProgress / count;
    return List.generate(count, (_) => perChunk.clamp(0.0, 1.0));
  }

  int get displayDownloadedBytes {
    final total = combinedTotalSize;
    final downloaded = combinedDownloadedBytes;
    return total > 0 ? downloaded.clamp(0, total) : downloaded;
  }

  // FIX 1.5: Fix progress getter for YouTube dual-stream
  double get progress {
    if (status == DownloadStatus.completed) return 1.0;
    if (isTorrent && hasTorrentFiles) return torrentOverallPercent;

    if (hasMergedAudio && audioSize > 0) {
      final vSize = videoStreamSize > 0
          ? videoStreamSize
          : (fileSize > audioSize ? fileSize - audioSize : (fileSize > 0 ? fileSize : 0));
      final videoDl = downloadedBytes.clamp(0, vSize > 0 ? vSize : downloadedBytes);
      final audioDl = (audioDownloadedBytes > 0
              ? audioDownloadedBytes
              : (audioProgress * audioSize).round())
          .clamp(0, audioSize);
      final total = (vSize > 0 ? vSize : 0) + audioSize;
      if (total > 0) {
        return ((videoDl + audioDl) / total).clamp(0.0, 1.0);
      }
    }

    if (hasUnknownSize) return -1.0;
    final total = combinedTotalSize;
    if (total <= 0) return -1.0;
    final ratio = displayDownloadedBytes / total;
    if (ratio.isNaN || ratio.isInfinite) return -1.0;
    return ratio.clamp(0.0, 1.0);
  }

  double? get ytCombinedProgress {
    if (!hasMergedAudio && audioSize <= 0 && youtubeQualityPreset == null) {
      return null;
    }
    final selfSize = fileSize > 0 ? fileSize : 0;
    final cpSize = audioSize > 0 ? audioSize : 0;
    final totalSize = selfSize + cpSize;
    if (totalSize <= 0) return null;

    final selfDownloaded = downloadedBytes;
    final cpDownloaded = audioDownloadedBytes;
    final totalDownloaded = (selfDownloaded > 0 ? selfDownloaded : 0) +
        (cpDownloaded > 0 ? cpDownloaded : 0);

    return (totalDownloaded / totalSize).clamp(0.0, 1.0);
  }

  String get progressPercentString {
    if (status == DownloadStatus.completed) return '100.0%';
    if (isTorrent && hasTorrentFiles) {
      return '${(torrentOverallPercent * 100).toStringAsFixed(1)}%';
    }
    final total = combinedTotalSize;
    if (total <= 0) {
      final dl = combinedDownloadedBytes;
      return dl > 0 ? formatBytes(dl) : '—';
    }
    return '${(progress * 100).toStringAsFixed(1)}%';
  }

  String get speedFormatted {
    if (status != DownloadStatus.downloading &&
        status != DownloadStatus.completed) {
      return '0.0 KB/s';
    }
    if (status == DownloadStatus.completed && isTorrent && seedingEnabled) {
      return '${formatBytes(speed)}/s';
    }
    if (status != DownloadStatus.downloading || speed <= 0) return '0.0 KB/s';
    return '${formatBytes(speed)}/s';
  }

  String get etaFormatted {
    if (status == DownloadStatus.completed) {
      if (isTorrent && seedingEnabled) return 'Seeding';
      return 'Finished';
    }
    if (status == DownloadStatus.queued) return 'Queued';
    if (status == DownloadStatus.paused) {
      if (scheduledAt != null) {
        return 'Scheduled';
      }
      return 'Paused';
    }
    if (status == DownloadStatus.failed) return 'Failed';
    if (eta == null || eta! <= 0) return '--';
    if (eta! >= 3600) {
      final hours = eta! ~/ 3600;
      final minutes = (eta! % 3600) ~/ 60;
      return '${hours}h ${minutes}m';
    }
    if (eta! >= 60) {
      final minutes = eta! ~/ 60;
      final seconds = eta! % 60;
      return '${minutes}m ${seconds}s';
    }
    return '${eta}s';
  }

  String get elapsedFormatted {
    final DateTime end;
    switch (status) {
      case DownloadStatus.completed:
        end = completedAt ?? updatedAt;
        break;
      case DownloadStatus.downloading:
      case DownloadStatus.queued:
      case DownloadStatus.merging:
        end = DateTime.now();
        break;
      case DownloadStatus.paused:
      case DownloadStatus.failed:
        end = updatedAt;
        break;
    }
    var seconds = end.difference(createdAt).inSeconds;
    if (seconds < 0) seconds = 0;
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) {
      return '${seconds ~/ 60}m ${seconds % 60}s';
    }
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h >= 100) return '${h ~/ 24}d ${h % 24}h';
    return '${h}h ${m}m';
  }

  String get sizeFormatted {
    final total = combinedTotalSize;
    if (total > 0) return formatBytes(total);
    final downloaded = combinedDownloadedBytes;
    if (status == DownloadStatus.completed && downloaded > 0) {
      return formatBytes(downloaded);
    }
    return 'Unknown';
  }

  String get downloadedSizeFormatted {
    final total = combinedTotalSize;
    final downloaded = combinedDownloadedBytes;
    if (total > 0 && downloaded > total) return formatBytes(total);
    return formatBytes(downloaded);
  }

  String get audioSizeFormatted =>
      audioSize > 0 ? formatBytes(audioSize) : 'Unknown';

  String get audioProgressPercentString =>
      '${(audioProgressPercent * 100).toStringAsFixed(1)}%';

  DownloadTask copyWith({
    String? fileName,
    String? url,
    int? fileSize,
    bool clearFileSize = false,
    int? downloadedBytes,
    double? speed,
    int? eta,
    bool clearEta = false,
    String? category,
    DownloadStatus? status,
    String? savePath,
    String? localFilePath,
    String? tempFilePath,
    String? errorMessage,
    bool clearError = false,
    String? statusMessage,
    bool clearStatusMessage = false,
    FailureCategory? failureCategory,
    bool clearFailureCategory = false,
    String? recoveryHint,
    bool clearRecoveryHint = false,
    int? threadCount,
    List<double>? chunks,
    DateTime? updatedAt,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    DateTime? scheduledAt,
    bool clearScheduledAt = false,
    DateTime? wasScheduledAt,
    bool clearWasScheduledAt = false,
    bool? supportsResume,
    int? speedLimitKbps,
    bool? seedingEnabled,
    bool? seedingLimited,
    int? seedingLimitKbps,
    int? uploadedBytes,
    List<Map<String, dynamic>>? torrentFiles,
    bool clearTorrentFiles = false,
    String? downloadPageUrl,
    bool clearDownloadPageUrl = false,
    String? mergedAudioUrl,
    bool clearMergedAudioUrl = false,
    int? audioSize,
    int? audioDownloadedBytes,
    int? videoStreamSize,
    double? audioProgress,
    int? audioThreadCount,
    List<double>? audioChunks,
    double? torrentPieceProgress,
    bool clearTorrentPieceProgress = false,
    List<HttpPartStatus>? httpParts,
    bool clearHttpParts = false,
    int? audioChunksCompleted,
    int? audioChunksTotal,
    int? httpPartsCompleted,
    int? httpPartsTotal,
    bool? pausedByUser,
    bool? isCancelled,
    String? youtubeQualityPreset,
    bool clearYoutubeQualityPreset = false,
    String? notes,
    bool? isAppUpdate,
    int? priority,
    int? queueOrder,
    String? playlistId,
    String? playlistTitle,
    String? thumbnailUrl,
    bool clearThumbnail = false,
    String? expectedSha256,
    List<String>? mirrorUrls,
    String? siteType,
    String? siteDisplayName,
    String? contentHint,
    bool? isMergeInProgress,
    PauseReason? pauseReason,
    bool clearPauseReason = false,
    int? totalPieces,
    bool clearTotalPieces = false,
    int? completedPieces,
    bool clearCompletedPieces = false,
    int? ytCounterpartDownloadedBytes,
    CycleState? cycleState,
    bool clearCycleState = false,
    CycleState? previousCycleState,
    bool clearPreviousCycleState = false,
    int? totalFiles,
    int? completedFiles,
    int? totalFileBytes,
    int? downloadedFileBytes,
  }) {
    final effectiveFileSize = clearFileSize
        ? 0
        : (fileSize != null ? max(0, fileSize) : this.fileSize);
    final rawDownloadedBytes = max(0, downloadedBytes ?? this.downloadedBytes);

    // FIX 1.6: Validate cycleState transition legality
    CycleState? effectiveCycleState = cycleState ?? this.cycleState;
    if (clearCycleState) {
      effectiveCycleState = null;
    } else if (cycleState != null &&
        cycleState != this.cycleState &&
        this.cycleState != null) {
      if (!CycleState.isValidTransition(this.cycleState, cycleState)) {
        debugPrint(
            '[DownloadTask] Warning: Blocked illegal cycleState transition from ${this.cycleState} to $cycleState on task $id');
        try {
          CrashReportingService.recordError(
            StateError(
                'Illegal CycleState transition from ${this.cycleState} to $cycleState on task $id'),
            StackTrace.current,
            hint: 'recoverable',
          );
        } catch (_) {}
        effectiveCycleState = this.cycleState;
      }
    }

    final effAudioThreadCount = audioThreadCount ?? this.audioThreadCount;
    final effAudioChunks = (audioChunks != null
            ? List<double>.from(audioChunks)
            : List<double>.from(this.audioChunks))
        .map((c) => (c.isNaN || c.isInfinite) ? 0.0 : c.clamp(0.0, 1.0))
        .toList();

    return DownloadTask(
      id: id,
      fileName: fileName ?? this.fileName,
      url: url ?? this.url,
      fileSize: effectiveFileSize,
      downloadedBytes: (effectiveFileSize > 0 &&
              !hasMergedAudio &&
              !isTorrent &&
              (mergedAudioUrl == null || mergedAudioUrl.isEmpty))
          ? rawDownloadedBytes.clamp(0, effectiveFileSize)
          : rawDownloadedBytes,
      speed: speed ?? this.speed,
      eta: clearEta ? null : (eta ?? this.eta),
      category: category ?? this.category,
      status: status ?? this.status,
      savePath: savePath ?? this.savePath,
      localFilePath: localFilePath ?? this.localFilePath,
      tempFilePath: tempFilePath ?? this.tempFilePath,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      statusMessage:
          clearStatusMessage ? null : (statusMessage ?? this.statusMessage),
      failureCategory: clearFailureCategory
          ? null
          : (failureCategory ?? this.failureCategory),
      recoveryHint:
          clearRecoveryHint ? null : (recoveryHint ?? this.recoveryHint),
      threadCount: threadCount ?? this.threadCount,
      chunks: (chunks != null
              ? List<double>.from(chunks)
              : List<double>.from(this.chunks))
          .map((c) {
        if (c.isNaN || c.isInfinite) return 0.0;
        return c.clamp(0.0, 1.0);
      }).toList(),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
      scheduledAt: clearScheduledAt ? null : (scheduledAt ?? this.scheduledAt),
      wasScheduledAt:
          clearWasScheduledAt ? null : (wasScheduledAt ?? this.wasScheduledAt),
      supportsResume: supportsResume ?? this.supportsResume,
      speedLimitKbps: speedLimitKbps ?? this.speedLimitKbps,
      seedingEnabled: seedingEnabled ?? this.seedingEnabled,
      seedingLimited: seedingLimited ?? this.seedingLimited,
      seedingLimitKbps: seedingLimitKbps ?? this.seedingLimitKbps,
      uploadedBytes: uploadedBytes ?? this.uploadedBytes,
      torrentFiles: clearTorrentFiles
          ? null
          : (torrentFiles != null
              ? List<Map<String, dynamic>>.from(
                  torrentFiles.map((m) => Map<String, dynamic>.from(m)))
              : (this.torrentFiles != null
                  ? List<Map<String, dynamic>>.from(this
                      .torrentFiles!
                      .map((m) => Map<String, dynamic>.from(m)))
                  : null)),
      downloadPageUrl: clearDownloadPageUrl
          ? null
          : (downloadPageUrl ?? this.downloadPageUrl),
      mergedAudioUrl:
          clearMergedAudioUrl ? null : (mergedAudioUrl ?? this.mergedAudioUrl),
      audioSize: audioSize ?? this.audioSize,
      audioDownloadedBytes: audioDownloadedBytes ?? this.audioDownloadedBytes,
      videoStreamSize: videoStreamSize ?? this.videoStreamSize,
      audioProgress: ((audioProgress ?? this.audioProgress).isNaN
          ? 0.0
          : (audioProgress ?? this.audioProgress).clamp(0.0, 1.0)),
      audioThreadCount: effAudioThreadCount,
      audioChunks: effAudioChunks,
      torrentPieceProgress: clearTorrentPieceProgress
          ? null
          : (torrentPieceProgress ?? this.torrentPieceProgress),
      httpParts: clearHttpParts
          ? null
          : (httpParts ?? this.httpParts),
      audioChunksCompleted: audioChunksCompleted ?? this.audioChunksCompleted,
      audioChunksTotal: audioChunksTotal ?? this.audioChunksTotal,
      httpPartsCompleted: httpPartsCompleted ?? this.httpPartsCompleted,
      httpPartsTotal: httpPartsTotal ?? this.httpPartsTotal,
      isMergeInProgress: isMergeInProgress ?? this.isMergeInProgress,
      pausedByUser: pausedByUser ?? this.pausedByUser,
      isCancelled: isCancelled ?? this.isCancelled,
      youtubeQualityPreset: clearYoutubeQualityPreset
          ? null
          : (youtubeQualityPreset ?? this.youtubeQualityPreset),
      notes: notes ?? this.notes,
      isAppUpdate: isAppUpdate ?? this.isAppUpdate,
      priority: priority ?? this.priority,
      queueOrder: queueOrder ?? this.queueOrder,
      playlistId: playlistId ?? this.playlistId,
      playlistTitle: playlistTitle ?? this.playlistTitle,
      thumbnailUrl: clearThumbnail ? null : (thumbnailUrl ?? this.thumbnailUrl),
      expectedSha256: expectedSha256 ?? this.expectedSha256,
      mirrorUrls: mirrorUrls != null
          ? List<String>.from(mirrorUrls)
          : (this.mirrorUrls != null
              ? List<String>.from(this.mirrorUrls!)
              : null),
      siteType: siteType ?? this.siteType,
      siteDisplayName: siteDisplayName ?? this.siteDisplayName,
      contentHint: contentHint ?? this.contentHint,
      pauseReason: clearPauseReason ? null : (pauseReason ?? this.pauseReason),
      totalPieces: clearTotalPieces ? null : (totalPieces ?? this.totalPieces),
      completedPieces: clearCompletedPieces
          ? null
          : (completedPieces ?? this.completedPieces),
      ytCounterpartDownloadedBytes:
          ytCounterpartDownloadedBytes ?? this.ytCounterpartDownloadedBytes,
      cycleState: effectiveCycleState,
      previousCycleState: clearPreviousCycleState
          ? null
          : (previousCycleState ?? this.previousCycleState),
      totalFiles: totalFiles ?? this.totalFiles,
      completedFiles: completedFiles ?? this.completedFiles,
      totalFileBytes: totalFileBytes ?? this.totalFileBytes,
      downloadedFileBytes: downloadedFileBytes ?? this.downloadedFileBytes,
    );
  }

  static bool isValidTransition(DownloadStatus from, DownloadStatus to) {
    return DownloadStateMachine.canTransitionStatus(from, to);
  }

  DownloadTask transitionTo(DownloadStatus nextStatus) {
    if (!isValidTransition(status, nextStatus)) {
      debugPrint(
          '[DownloadTask] Warning: Blocked illegal status transition from $status to $nextStatus on task $id');
      return this;
    }
    return copyWith(status: nextStatus);
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'fileName': fileName,
      'url': url,
      'fileSize': fileSize,
      'downloadedBytes': downloadedBytes,
      'speed': speed,
      'eta': eta,
      'category': category,
      'status': status.name,
      'savePath': savePath,
      'localFilePath': localFilePath,
      'tempFilePath': tempFilePath,
      'errorMessage': errorMessage,
      'statusMessage': statusMessage,
      'failureCategory': failureCategory?.name,
      'recoveryHint': recoveryHint,
      'threadCount': threadCount,
      'chunks': chunks,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'updatedAt': updatedAt.millisecondsSinceEpoch,
      'completedAt': completedAt?.millisecondsSinceEpoch,
      'scheduledAt': scheduledAt?.millisecondsSinceEpoch,
      'wasScheduledAt': wasScheduledAt?.millisecondsSinceEpoch,
      'supportsResume': supportsResume,
      'speedLimitKbps': speedLimitKbps,
      'seedingEnabled': seedingEnabled,
      'seedingLimited': seedingLimited,
      'seedingLimitKbps': seedingLimitKbps,
      'uploadedBytes': uploadedBytes,
      'torrentFiles': torrentFiles,
      'downloadPageUrl': downloadPageUrl,
      'mergedAudioUrl': mergedAudioUrl,
      'audioSize': audioSize,
      'audioDownloadedBytes': audioDownloadedBytes,
      'videoStreamSize': videoStreamSize,
      'audioProgress': audioProgress,
      'audioThreadCount': audioThreadCount,
      'audioChunks': audioChunks,
      'torrentPieceProgress': torrentPieceProgress,
      'httpParts': httpParts?.map((p) => p.toMap()).toList(),
      'audioChunksCompleted': audioChunksCompleted,
      'audioChunksTotal': audioChunksTotal,
      'httpPartsCompleted': httpPartsCompleted,
      'httpPartsTotal': httpPartsTotal,
      'pausedByUser': pausedByUser,
      'isCancelled': isCancelled,
      'youtubeQualityPreset': youtubeQualityPreset,
      'notes': notes,
      'isAppUpdate': isAppUpdate,
      'priority': priority,
      'queueOrder': queueOrder,
      'playlistId': playlistId,
      'playlistTitle': playlistTitle,
      'thumbnailUrl': thumbnailUrl,
      'expectedSha256': expectedSha256,
      'mirrorUrls': mirrorUrls,
      'siteType': siteType,
      'siteDisplayName': siteDisplayName,
      'contentHint': contentHint,
      'pauseReason': pauseReason?.name,
      'totalPieces': totalPieces,
      'completedPieces': completedPieces,
      'ytCounterpartDownloadedBytes': ytCounterpartDownloadedBytes,
      'cycleState': cycleState?.name,
      'totalFiles': totalFiles,
      'completedFiles': completedFiles,
      'totalFileBytes': totalFileBytes,
      'downloadedFileBytes': downloadedFileBytes,
    };
  }

  static DateTime _parseFlexDate(dynamic value, {DateTime? fallback}) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    if (value is String && value.isNotEmpty) {
      final intVal = int.tryParse(value);
      if (intVal != null) return DateTime.fromMillisecondsSinceEpoch(intVal);
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;
    }
    return fallback ?? DateTime.now();
  }

  static DateTime? _parseNullableFlexDate(dynamic value) {
    if (value == null) return null;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    if (value is String && value.isNotEmpty) {
      final intVal = int.tryParse(value);
      if (intVal != null) return DateTime.fromMillisecondsSinceEpoch(intVal);
      return DateTime.tryParse(value);
    }
    return null;
  }

  factory DownloadTask.fromMap(Map<String, dynamic> map) {
    final statusName = map['status'] as String? ?? 'paused';
    final matched = DownloadStatus.values.where((v) => v.name == statusName);
    final status = matched.isNotEmpty ? matched.first : DownloadStatus.paused;

    final rawChunks =
        (map['chunks'] is List ? (map['chunks'] as List) : const [0.0])
            .map((value) {
      final raw = (value as num?)?.toDouble() ?? 0.0;
      if (raw.isNaN || raw.isInfinite) return 0.0;
      return raw.clamp(0.0, 1.0);
    }).toList();

    final threadCount =
        (map['threadCount'] as num?)?.toInt() ?? rawChunks.length;
    final downloadedBytes = (map['downloadedBytes'] as num?)?.toInt() ?? 0;
    final fileSize = (map['fileSize'] as num?)?.toInt() ?? 0;

    List<double> chunks;
    if (rawChunks.length == threadCount) {
      chunks = rawChunks;
    } else if (rawChunks.length < threadCount) {
      chunks = [
        ...rawChunks,
        ...List<double>.filled(threadCount - rawChunks.length, 0.0),
      ];
    } else {
      final safeThreadCount = threadCount > 0 ? threadCount : 1;
      final sum = rawChunks.fold<double>(0.0, (s, c) => s + c);
      final overallProgress = rawChunks.isNotEmpty
          ? (sum / rawChunks.length).clamp(0.0, 1.0)
          : (downloadedBytes > 0 && fileSize > 0
              ? (downloadedBytes / fileSize).clamp(0.0, 1.0)
              : 0.0);
      chunks = List<double>.filled(safeThreadCount, overallProgress);
    }
    chunks = chunks
        .map((c) => (c.isNaN || c.isInfinite) ? 0.0 : c.clamp(0.0, 1.0))
        .toList();

    String? errorMessage = map['errorMessage'] as String?;
    if (matched.isEmpty && errorMessage == null) {
      errorMessage = 'Unknown status "$statusName" (recovered as paused)';
    }

    final rawPauseReason = map['pauseReason'];
    final pauseReason = rawPauseReason is String
        ? PauseReason.fromName(rawPauseReason)
        : (rawPauseReason is PauseReason ? rawPauseReason : null);

    final rawTorrentFiles = (map['torrentFiles'] as List?)
        ?.whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    int? totalFiles = (map['totalFiles'] as num?)?.toInt();
    int? completedFiles = (map['completedFiles'] as num?)?.toInt();
    int? totalFileBytes = (map['totalFileBytes'] as num?)?.toInt();
    int? downloadedFileBytes = (map['downloadedFileBytes'] as num?)?.toInt();

    if (rawTorrentFiles != null && rawTorrentFiles.isNotEmpty) {
      final selected = rawTorrentFiles
          .where((f) => (f['selected'] as bool?) ?? true)
          .toList();
      totalFiles ??= selected.length;
      completedFiles ??= selected.where((f) {
        final len = (f['length'] as num?)?.toInt() ?? 0;
        final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        return len == 0 || dl >= len;
      }).length;
      totalFileBytes ??= selected.fold<int>(
          0, (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0));
      downloadedFileBytes ??= selected.fold<int>(0, (sum, f) {
        final len = (f['length'] as num?)?.toInt() ?? 0;
        final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        return sum + (len > 0 ? dl.clamp(0, len) : 0);
      });
    }

    final audioThreadCount = (map['audioThreadCount'] as num?)?.toInt() ?? 2;
    List<double>? audioChunks;
    if (map['audioChunks'] is List) {
      audioChunks = (map['audioChunks'] as List)
          .map((v) => (v as num?)?.toDouble() ?? 0.0)
          .map((c) => (c.isNaN || c.isInfinite) ? 0.0 : c.clamp(0.0, 1.0))
          .toList();
    } else if (map['audio_chunks'] is String) {
      try {
        final dec = jsonDecode(map['audio_chunks'] as String);
        if (dec is List) {
          audioChunks = dec
              .map((v) => (v as num?)?.toDouble() ?? 0.0)
              .map((c) => (c.isNaN || c.isInfinite) ? 0.0 : c.clamp(0.0, 1.0))
              .toList();
        }
      } catch (_) {}
    }

    List<HttpPartStatus>? httpParts;
    if (map['httpParts'] is List) {
      httpParts = (map['httpParts'] as List)
          .whereType<Map>()
          .map((m) => HttpPartStatus.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    } else if (map['http_parts'] is String) {
      try {
        final dec = jsonDecode(map['http_parts'] as String);
        if (dec is List) {
          httpParts = dec
              .whereType<Map>()
              .map((m) => HttpPartStatus.fromMap(Map<String, dynamic>.from(m)))
              .toList();
        }
      } catch (_) {}
    }

    return DownloadTask(
      id: map['id'] as String? ?? '',
      fileName: map['fileName'] as String? ?? '',
      url: map['url'] as String? ?? '',
      fileSize: (map['fileSize'] as num?)?.toInt() ?? 0,
      downloadedBytes: (map['downloadedBytes'] as num?)?.toInt() ?? 0,
      speed: (map['speed'] as num?)?.toDouble() ?? 0.0,
      eta: (map['eta'] as num?)?.toInt(),
      category: map['category'] as String? ?? 'Other',
      status: status,
      savePath: map['savePath'] as String? ?? '',
      localFilePath: map['localFilePath'] as String? ?? '',
      tempFilePath: map['tempFilePath'] as String? ?? '',
      errorMessage: errorMessage,
      statusMessage: map['statusMessage'] as String?,
      failureCategory: map['failureCategory'] != null
          ? FailureCategory.values.firstWhere(
              (v) => v.name == map['failureCategory'],
              orElse: () => FailureCategory.unknown,
            )
          : null,
      recoveryHint: map['recoveryHint'] as String?,
      threadCount: threadCount,
      chunks: chunks,
      createdAt: _parseFlexDate(map['createdAt']),
      updatedAt: _parseFlexDate(map['updatedAt']),
      completedAt: _parseNullableFlexDate(map['completedAt']),
      scheduledAt: _parseNullableFlexDate(map['scheduledAt']),
      wasScheduledAt: _parseNullableFlexDate(map['wasScheduledAt']),
      supportsResume: map['supportsResume'] as bool? ?? false,
      speedLimitKbps: (map['speedLimitKbps'] as num?)?.toInt() ?? 0,
      seedingEnabled: map['seedingEnabled'] as bool? ?? false,
      seedingLimited: map['seedingLimited'] as bool? ?? false,
      seedingLimitKbps: (map['seedingLimitKbps'] as num?)?.toInt() ?? 500,
      uploadedBytes: (map['uploadedBytes'] as num?)?.toInt() ?? 0,
      torrentFiles: rawTorrentFiles,
      downloadPageUrl: map['downloadPageUrl'] as String?,
      mergedAudioUrl: map['mergedAudioUrl'] as String?,
      audioSize: (map['audioSize'] as num?)?.toInt() ?? 0,
      audioDownloadedBytes: (map['audioDownloadedBytes'] as num?)?.toInt() ?? 0,
      videoStreamSize: max(
          0, (map['videoStreamSize'] as num?)?.toInt() ?? 0),
      audioProgress: (map['audioProgress'] as num?)?.toDouble() ?? 0.0,
      audioThreadCount: audioThreadCount,
      audioChunks: audioChunks,
      torrentPieceProgress: (map['torrentPieceProgress'] as num?)?.toDouble() ??
          (map['torrent_piece_progress'] as num?)?.toDouble(),
      httpParts: httpParts,
      audioChunksCompleted: (map['audioChunksCompleted'] as num?)?.toInt() ??
          (map['audio_chunks_completed'] as num?)?.toInt(),
      audioChunksTotal: (map['audioChunksTotal'] as num?)?.toInt() ??
          (map['audio_chunks_total'] as num?)?.toInt(),
      httpPartsCompleted: (map['httpPartsCompleted'] as num?)?.toInt() ??
          (map['http_parts_completed'] as num?)?.toInt(),
      httpPartsTotal: (map['httpPartsTotal'] as num?)?.toInt() ??
          (map['http_parts_total'] as num?)?.toInt(),
      pausedByUser: map['pausedByUser'] as bool? ?? false,
      isCancelled: map['isCancelled'] as bool? ?? false,
      youtubeQualityPreset: map['youtubeQualityPreset'] as String?,
      notes: map['notes'] as String?,
      isAppUpdate: map['isAppUpdate'] as bool? ?? false,
      priority: (map['priority'] as num?)?.toInt() ?? 0,
      queueOrder: (map['queueOrder'] as num?)?.toInt() ?? 0,
      playlistId: map['playlistId'] as String?,
      playlistTitle: map['playlistTitle'] as String?,
      thumbnailUrl: map['thumbnailUrl'] as String?,
      expectedSha256: map['expectedSha256'] as String?,
      mirrorUrls: map['mirrorUrls'] is List
          ? (map['mirrorUrls'] as List).map((e) => e.toString()).toList()
          : null,
      siteType: map['siteType'] as String?,
      siteDisplayName: map['siteDisplayName'] as String?,
      contentHint: map['contentHint'] as String?,
      pauseReason: pauseReason,
      totalPieces: (map['totalPieces'] as num?)?.toInt(),
      completedPieces: (map['completedPieces'] as num?)?.toInt(),
      ytCounterpartDownloadedBytes:
          (map['ytCounterpartDownloadedBytes'] as num?)?.toInt(),
      cycleState: map['cycleState'] is String
          ? CycleState.fromName(map['cycleState'] as String)
          : (map['cycleState'] is CycleState
              ? map['cycleState'] as CycleState
              : null),
      previousCycleState: map['previousCycleState'] is String
          ? CycleState.fromName(map['previousCycleState'] as String)
          : (map['previousCycleState'] is CycleState
              ? map['previousCycleState'] as CycleState
              : null),
      totalFiles: totalFiles,
      completedFiles: completedFiles,
      totalFileBytes: totalFileBytes,
      downloadedFileBytes: downloadedFileBytes,
    );
  }

  bool get hasMergedAudio =>
      mergedAudioUrl != null && mergedAudioUrl!.isNotEmpty;

  String? get youtubePreferredType {
    if (mergedAudioUrl != null && mergedAudioUrl!.isNotEmpty) return 'combined';
    if (youtubeQualityPreset == 'audio_only' ||
        category.toLowerCase() == 'audio' ||
        fileName.toLowerCase().endsWith('.mp3') ||
        fileName.toLowerCase().endsWith('.m4a')) {
      return 'audio';
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is DownloadTask && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
