import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/url_utils.dart';

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
} // FIX-B11

enum SortOption { dateAdded, fileSize, fileName, status, manual } // FIX(13)

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
  final DateTime? wasScheduledAt; // SCHED-FIX-1: Preserved after schedule fires
  final bool supportsResume;
  // Speed Limit and Torrent Seeding Fields
  final int speedLimitKbps; // 0 = unlimited
  final bool seedingEnabled;
  final bool seedingLimited;
  final int seedingLimitKbps;
  final List<Map<String, dynamic>>? torrentFiles;
  final String? downloadPageUrl;
  final String? mergedAudioUrl;
  final int audioSize;
  final int videoStreamSize; // FIX-B4
  final double audioProgress;
  final int audioThreadCount;
  final bool pausedByUser;
  final String? youtubeQualityPreset;
  final String? notes;
  final bool isAppUpdate;
  final int priority; // 0 = normal, 1 = high, 2 = urgent
  final int queueOrder; // FIX(13): Lower values = higher priority
  final String? playlistId; // groups playlist videos into one card
  final String? playlistTitle;
  final String? thumbnailUrl;
  final String? expectedSha256;
  final List<String>? mirrorUrls;

  // Smart Site Intelligence fields
  final String? siteType;
  final String? siteDisplayName;
  final String? contentHint;

  final bool isMergeInProgress; // runtime only, not persisted

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
    this.videoStreamSize = 0, // FIX-B4
    this.audioProgress = 0.0,
    this.audioDownloadedBytes = 0,
    this.audioThreadCount = 2,
    this.isMergeInProgress = false,
    this.pausedByUser = false,
    this.youtubeQualityPreset,
    this.notes,
    this.isAppUpdate = false,
    this.priority = 0,
    this.queueOrder = 0, // FIX(13)
    this.playlistId,
    this.playlistTitle,
    this.thumbnailUrl,
    this.expectedSha256,
    this.mirrorUrls,
    this.siteType,
    this.siteDisplayName,
    this.contentHint,
  });

  bool get isTorrent => isTorrentUrl(url, fileName: fileName);

  bool get isPlaylistItem => playlistId != null && playlistId!.isNotEmpty;

  /// Total size with fallbacks: stored [fileSize] first, then the sum of the
  /// selected torrent files (magnets only learn their size after metadata),
  /// then 0. Every size/percentage readout must go through this getter so
  /// torrents with a late-resolved size still render correct numbers.
  int get resolvedFileSize {
    if (fileSize < 0) return 0; // FIX-C1: Handle negative fileSize
    // FIX-10: For torrents, prefer the torrentFiles sum as it's computed from actual metadata
    if (isTorrent && torrentFiles != null && torrentFiles!.isNotEmpty) {
      final sum = torrentFiles!
          .where((f) => isTorrentFileSelected(f))
          .fold<int>(0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0));
      if (sum > 0) return sum;
    }
    if (fileSize > 0) return fileSize;
    return 0;
  }

  // FIX(07): Track uploaded bytes for torrent seeding ratio
  final int audioDownloadedBytes; // actual audio bytes on disk
  final int uploadedBytes;

  // FIX(01): Helper getter for indeterminate progress state
  bool get hasUnknownSize => resolvedFileSize <= 0;

  // FIX(05): Audio progress computed getters
  double get audioProgressPercent {
    // FIX Y-2: Prefer byte-based calculation when audioDownloadedBytes > 0
    if (audioSize > 0 && audioDownloadedBytes > 0) {
      return (audioDownloadedBytes / audioSize).clamp(0.0, 1.0);
    }
    return audioProgress.clamp(0.0, 1.0);
  }

  String get audioProgressString =>
      '${(audioProgressPercent * 100).toStringAsFixed(1)}%';
  bool get isAudioComplete =>
      audioProgress >= 0.999 ||
      (audioSize > 0 && audioDownloadedBytes >= audioSize);

  // FIX(07): Seeding ratio computed getter
  double get seedingRatio {
    if (downloadedBytes <= 0) return 0.0;
    return uploadedBytes / downloadedBytes;
  }

  // FIX(17): Helper flag when video size is unknown but audio size is known
  bool get isTotalSizePartial =>
      hasMergedAudio && fileSize <= 0 && audioSize > 0;

  // FIX-H6: Network status getters
  bool get waitingWifi =>
      errorMessage == DownloadStatusMessages.waitingWifi ||
      statusMessage == DownloadStatusMessages.waitingWifi;

  bool get waitingNetwork =>
      errorMessage == DownloadStatusMessages.waitingNetwork ||
      statusMessage == DownloadStatusMessages.waitingNetwork;

  bool get hasTorrentFiles => torrentFiles != null && torrentFiles!.isNotEmpty;

  // FIX-AUDIT-09: Unambiguous total size calculation
  int get combinedTotalSize {
    if (hasMergedAudio && audioSize > 0) {
      // If we know the video-only size, use the explicit sum
      if (videoStreamSize > 0) return videoStreamSize + audioSize;
      // fileSize is the authoritative combined total when set by stream resolution
      if (fileSize > 0) return fileSize;
      // BUG 3 FIX: Return 0 when both videoStreamSize and fileSize are 0
      // to trigger indeterminate state instead of wrong denominator (audioSize only)
      return 0;
    }
    return resolvedFileSize;
  }

  /// Combined downloaded bytes including audio stream bytes for YouTube downloads.
  int get combinedDownloadedBytes {
    final total = combinedTotalSize;
    var raw = downloadedBytes < 0 ? 0 : downloadedBytes;
    if (hasMergedAudio) {
      final videoOnly = videoStreamSize > 0
          ? videoStreamSize
          : (fileSize > audioSize ? fileSize - audioSize : 0);
      // FIX-1: Always fold audio bytes in, even when videoOnly is still 0
      // (audio size may be known before video size resolves).
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
        // videoOnly unknown — add audio bytes on top of whatever
        // video bytes we already have so progress still moves.
        raw += audioBytes;
      }
    }
    if (total > 0) return raw.clamp(0, total);
    return raw;
  }

  // FIX-S8: Sanitized chunk progress ratios matching current threadCount with NaN/Inf guards
  List<double> get sanitizedChunks {
    final count = threadCount > 0 ? threadCount : 1;
    double safe(double c) =>
        (c.isNaN || c.isInfinite) ? 0.0 : c.clamp(0.0, 1.0);

    if (chunks.length == count) {
      return chunks.map(safe).toList();
    }
    if (chunks.isEmpty) {
      // No chunk data at all → distribute overall progress evenly.
      final frac = resolvedFileSize > 0
          ? (displayDownloadedBytes / resolvedFileSize).clamp(0.0, 1.0)
          : 0.0;
      return List.filled(count, frac);
    }
    if (chunks.length < count) {
      // Thread count increased: keep existing progress, pad remainder
      // with the average so total progress is preserved.
      final existing = chunks.map(safe).toList();
      final avg = existing.isEmpty
          ? 0.0
          : existing.reduce((a, b) => a + b) / existing.length;
      return [
        ...existing,
        ...List.filled(count - existing.length, avg.clamp(0.0, 1.0))
      ];
    }
    // Thread count decreased: keep the first `count` chunks.
    return chunks.sublist(0, count).map(safe).toList();
  }

  /// Downloaded bytes clamped to total size for safe display / ratio math.
  int get displayDownloadedBytes {
    final total = combinedTotalSize;
    final downloaded = combinedDownloadedBytes;
    return total > 0 ? downloaded.clamp(0, total) : downloaded;
  }

  double get progress {
    if (status == DownloadStatus.completed) return 1.0;
    if (hasUnknownSize) return -1.0;
    final total = combinedTotalSize;
    if (total <= 0) return -1.0;
    final ratio = displayDownloadedBytes / total;
    if (ratio.isNaN || ratio.isInfinite) return -1.0;
    return ratio.clamp(0.0, 1.0);
  }

  String get progressPercentString {
    if (status == DownloadStatus.completed) return '100.0%';
    final total = combinedTotalSize;
    if (total <= 0) {
      // Unknown total → show downloaded bytes as a byte-count badge
      // so the UI is consistent with the indeterminate progress bar.
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
    // Completed + torrent + seeding: speed carries the upload rate.
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

  /// Wall-clock time the download has been alive.
  ///  - downloading / queued → up to now (ticks live while the card rebuilds)
  ///  - paused / failed      → up to the last state change
  ///  - completed            → total transfer time
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

  /// Downloaded bytes, clamped so a late-resolved total can never render
  /// "1.4 GB / 800 MB" style rows.
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
    int? videoStreamSize, // FIX-B4
    double? audioProgress,
    int? audioThreadCount,
    bool? pausedByUser,
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
  }) {
    return DownloadTask(
      id: id,
      fileName: fileName ?? this.fileName,
      url: url ?? this.url,
      fileSize: max(0, fileSize ?? this.fileSize),
      downloadedBytes: max(
        0,
        max(0, fileSize ?? this.fileSize) > 0
            ? (downloadedBytes ?? this.downloadedBytes)
                .clamp(0, max(0, fileSize ?? this.fileSize))
            : max(0, downloadedBytes ?? this.downloadedBytes),
      ),
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
      chunks: (chunks ?? this.chunks).map((c) {
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
      torrentFiles:
          clearTorrentFiles ? null : (torrentFiles ?? this.torrentFiles),
      downloadPageUrl: clearDownloadPageUrl
          ? null
          : (downloadPageUrl ?? this.downloadPageUrl),
      mergedAudioUrl:
          clearMergedAudioUrl ? null : (mergedAudioUrl ?? this.mergedAudioUrl),
      audioSize: audioSize ?? this.audioSize,
      audioDownloadedBytes: audioDownloadedBytes ?? this.audioDownloadedBytes,
      // FIX-B4 / FIX YT-U1: Use a sentinel so callers can explicitly
      // reset videoStreamSize to 0.
      // ignore: prefer_if_null_operators
      videoStreamSize: videoStreamSize ?? this.videoStreamSize,
      audioProgress: ((audioProgress ?? this.audioProgress).isNaN
          ? 0.0
          : (audioProgress ?? this.audioProgress).clamp(0.0, 1.0)),
      audioThreadCount: audioThreadCount ?? this.audioThreadCount,
      isMergeInProgress: isMergeInProgress ?? this.isMergeInProgress,
      pausedByUser: pausedByUser ?? this.pausedByUser,
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
      mirrorUrls: mirrorUrls ?? this.mirrorUrls,
      siteType: siteType ?? this.siteType,
      siteDisplayName: siteDisplayName ?? this.siteDisplayName,
      contentHint: contentHint ?? this.contentHint,
    );
  }

  /// D-01: Validates if transition from [from] to [to] is legally allowed.
  static bool isValidTransition(DownloadStatus from, DownloadStatus to) {
    if (from == to) return true;
    switch (from) {
      case DownloadStatus.queued:
        return to == DownloadStatus.downloading ||
            to == DownloadStatus.paused ||
            to == DownloadStatus.failed ||
            to == DownloadStatus.merging ||
            to == DownloadStatus.completed;
      case DownloadStatus.downloading:
        return to == DownloadStatus.paused ||
            to == DownloadStatus.completed ||
            to == DownloadStatus.failed ||
            to == DownloadStatus.merging ||
            to == DownloadStatus.queued;
      case DownloadStatus.paused:
        return to == DownloadStatus.queued ||
            to == DownloadStatus.downloading ||
            to == DownloadStatus.failed ||
            to == DownloadStatus.merging;
      case DownloadStatus.merging:
        return to == DownloadStatus.completed ||
            to == DownloadStatus.failed ||
            to == DownloadStatus.paused;
      case DownloadStatus.failed:
        return to == DownloadStatus.queued ||
            to == DownloadStatus.downloading ||
            to == DownloadStatus.paused;
      case DownloadStatus.completed:
        return to == DownloadStatus.queued ||
            to == DownloadStatus.downloading; // Explicit restart
    }
  }

  /// Transition to new status with validation
  DownloadTask transitionTo(DownloadStatus nextStatus) {
    if (!isValidTransition(status, nextStatus)) {
      debugPrint(
          '[DownloadTask] Warning: Invalid status transition from $status to $nextStatus on task $id');
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
      'videoStreamSize': videoStreamSize, // FIX-B4
      'audioProgress': audioProgress,
      'audioThreadCount': audioThreadCount,
      'pausedByUser': pausedByUser,
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
      // FIX-M16: Guard against NaN / Infinity values that survive JSON
      // round-trips (e.g. from `double.infinity` or `0/0` calculations).
      final raw = (value as num?)?.toDouble() ?? 0.0;
      if (raw.isNaN || raw.isInfinite) return 0.0;
      return raw.clamp(0.0, 1.0);
    }).toList();

    final threadCount =
        (map['threadCount'] as num?)?.toInt() ?? rawChunks.length;

    List<double> chunks;
    if (rawChunks.length == threadCount) {
      chunks = rawChunks;
    } else if (rawChunks.length > threadCount) {
      final safeThreadCount = threadCount > 0 ? threadCount : 1;
      final totalSum = rawChunks.fold<double>(0.0, (s, c) => s + c);
      final overall = rawChunks.isEmpty
          ? 0.0
          : (totalSum / rawChunks.length).clamp(0.0, 1.0);
      chunks = List<double>.filled(safeThreadCount, overall);
      if (kDebugMode) {
        debugPrint(
          'DownloadTask.fromMap: chunk count mismatch for task ${map['id']}: '
          'stored ${rawChunks.length} chunks but threadCount=$threadCount. '
          'Redistributing progress to $overall per chunk.',
        );
      }
    } else {
      final remaining = threadCount - rawChunks.length;
      chunks = [...rawChunks, ...List.filled(remaining, 0.0)];
      if (kDebugMode) {
        debugPrint(
          'DownloadTask.fromMap: chunk count mismatch for task ${map['id']}: '
          'stored ${rawChunks.length} chunks but threadCount=$threadCount. '
          'Padding with $remaining zero chunks.',
        );
      }
    }

    String? errorMessage = map['errorMessage'] as String?;
    if (matched.isEmpty && errorMessage == null) {
      errorMessage = 'Unknown status "$statusName" (recovered as paused)';
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
      torrentFiles: (map['torrentFiles'] as List?)
          ?.map((e) => e as Map<String, dynamic>)
          .toList(),
      downloadPageUrl: map['downloadPageUrl'] as String?,
      mergedAudioUrl: map['mergedAudioUrl'] as String?,
      audioSize: (map['audioSize'] as num?)?.toInt() ?? 0,
      audioDownloadedBytes: (map['audioDownloadedBytes'] as num?)?.toInt() ?? 0,
      videoStreamSize: max(
          0, (map['videoStreamSize'] as num?)?.toInt() ?? 0), // FIX-B4 / FIX-M6
      audioProgress: (map['audioProgress'] as num?)?.toDouble() ?? 0.0,
      audioThreadCount: (map['audioThreadCount'] as num?)?.toInt() ?? 2,
      pausedByUser: map['pausedByUser'] as bool? ?? false,
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
    );
  }

  // FIX 5: Helper getter for merged audio status
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

  // Identity equality based on [id] (plus playlist grouping keys) so cards
  // animate correctly in lists.
  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is DownloadTask && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
