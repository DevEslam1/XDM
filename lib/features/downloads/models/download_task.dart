import 'dart:math';
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

enum DownloadStatus { queued, downloading, paused, completed, failed, merging } // FIX-B11

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
          .where((f) => f['selected'] != false)
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
  double get audioProgressPercent => audioProgress.clamp(0.0, 1.0);
  String get audioProgressString =>
      '${(audioProgressPercent * 100).toStringAsFixed(1)}%';
  bool get isAudioComplete => audioProgress >= 1.0;

  // FIX(07): Seeding ratio computed getter
  double get seedingRatio {
    if (downloadedBytes <= 0) return 0.0;
    return uploadedBytes / downloadedBytes;
  }

  // FIX(17): Helper flag when video size is unknown but audio size is known
  bool get isTotalSizePartial =>
      hasMergedAudio && fileSize <= 0 && audioSize > 0;

  /// Combined total payload size for this task (video + audio if YouTube, or resolvedFileSize).
  int get combinedTotalSize {
    if (hasMergedAudio && audioSize > 0) {
      if (videoStreamSize > 0) return videoStreamSize + audioSize;
      if (fileSize > 0) return fileSize;
      // Growing estimate so bar is not stuck at 0
      return max(downloadedBytes, 1) + audioSize;
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
      if (videoOnly > 0 && raw > videoOnly) {
        // Already includes audio — do not add again
      } else if (audioSize > 0) {
        if (audioProgress > 0) {
          raw += (audioProgress * audioSize).round();
        } else if (audioDownloadedBytes > 0) {
          raw += audioDownloadedBytes;
        }
      }
    }
    if (total > 0) return raw.clamp(0, total);
    return raw;
  }

  /// Sanitized chunk progress ratios matching current threadCount.
  List<double> get sanitizedChunks {
    final count = threadCount > 0 ? threadCount : 1;
    if (chunks.length == count) return chunks;
    if (chunks.isEmpty) return List<double>.filled(count, 0.0);
    if (chunks.length < count) {
      return [...chunks, ...List<double>.filled(count - chunks.length, 0.0)];
    }
    return chunks.sublist(0, count);
  }

  double get progress {
    if (status == DownloadStatus.completed) return 1.0;
    final total = combinedTotalSize;
    if (total <= 0) {
      return downloadedBytes > 0 ? -1.0 : 0.0;
    }
    return (combinedDownloadedBytes / total).clamp(0.0, 1.0);
  }

  String get progressPercentString {
    if (status == DownloadStatus.completed) return '100.0%';
    final total = combinedTotalSize;
    if (total <= 0) return '0.0%';
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
      '${(audioProgress * 100).toStringAsFixed(1)}%';

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
      fileSize: fileSize ?? this.fileSize,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
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
      threadCount: threadCount ?? this.threadCount,
      chunks: chunks ?? this.chunks,
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
      videoStreamSize: videoStreamSize ?? this.videoStreamSize, // FIX-B4
      audioProgress: (audioProgress ?? this.audioProgress).clamp(0.0, 1.0),
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
            })
            .toList();

    final threadCount =
        (map['threadCount'] as num?)?.toInt() ?? rawChunks.length;

    List<double> chunks;
    if (rawChunks.length == threadCount) {
      chunks = rawChunks;
    } else if (rawChunks.length > threadCount) {
      final safeThreadCount = threadCount > 0 ? threadCount : 1;
      final totalSum = rawChunks.fold<double>(0.0, (s, c) => s + c);
      final perChunk = (totalSum / safeThreadCount).clamp(0.0, 1.0);
      chunks = List<double>.filled(safeThreadCount, perChunk);
      if (kDebugMode) {
        debugPrint(
          'DownloadTask.fromMap: chunk count mismatch for task ${map['id']}: '
          'stored ${rawChunks.length} chunks but threadCount=$threadCount. '
          'Redistributing progress to $perChunk per chunk.',
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
      videoStreamSize: (map['videoStreamSize'] as num?)?.toInt() ?? 0, // FIX-B4
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
  bool get hasMergedAudio => mergedAudioUrl != null && mergedAudioUrl!.isNotEmpty;

  // FIX(H-4): Expose displayDownloadedBytes clamped to combinedTotalSize for UI rendering
  int get displayDownloadedBytes {
    final total = combinedTotalSize;
    final downloaded = combinedDownloadedBytes;
    return total > 0 ? min(downloaded, total) : downloaded;
  }

  String? get youtubePreferredType {
    if (mergedAudioUrl != null && mergedAudioUrl!.isNotEmpty) return 'combined';
    if (youtubeQualityPreset == 'audio_only' || category.toLowerCase() == 'audio' || fileName.toLowerCase().endsWith('.mp3') || fileName.toLowerCase().endsWith('.m4a')) {
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

