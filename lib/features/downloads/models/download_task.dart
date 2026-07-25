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
  static const forbidden = 'Forbidden';
}

enum DownloadStatus { queued, downloading, paused, completed, failed }

enum SortOption { dateAdded, fileSize, fileName, status }

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
  final int threadCount;
  final List<double> chunks;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final DateTime? scheduledAt;
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
  final double audioProgress;
  final bool pausedByUser;
  final String? youtubeQualityPreset;
  final String? notes;

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
    required this.threadCount,
    required this.chunks,
    required this.createdAt,
    required this.updatedAt,
    this.completedAt,
    this.scheduledAt,
    this.supportsResume = false,
    this.speedLimitKbps = 0,
    this.seedingEnabled = false,
    this.seedingLimited = false,
    this.seedingLimitKbps = 500,
    this.torrentFiles,
    this.downloadPageUrl,
    this.mergedAudioUrl,
    this.audioSize = 0,
    this.audioProgress = 0.0,
    this.pausedByUser = false,
    this.youtubeQualityPreset,
    this.notes,
  });

  bool get isTorrent => isTorrentUrl(url, fileName: fileName);

  double get progress {
    if (fileSize <= 0) return 0.0;
    return (downloadedBytes / fileSize).clamp(0.0, 1.0);
  }

  String get progressPercentString => '${(progress * 100).toStringAsFixed(1)}%';

  String get speedFormatted {
    if (status != DownloadStatus.downloading && status != DownloadStatus.completed) return '0.0 KB/s';
    // If it's completed and is torrent seeding:
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
      return '${hours}h ${minutes}m left';
    }
    if (eta! >= 60) {
      final minutes = eta! ~/ 60;
      final seconds = eta! % 60;
      return '${minutes}m ${seconds}s left';
    }
    return '${eta}s left';
  }

  String get sizeFormatted => fileSize > 0 ? formatBytes(fileSize) : 'Unknown';

  String get downloadedSizeFormatted => formatBytes(downloadedBytes);

  String get audioSizeFormatted => audioSize > 0 ? formatBytes(audioSize) : 'Unknown';

  String get audioProgressPercentString => '${(audioProgress * 100).toStringAsFixed(1)}%';

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
    int? threadCount,
    List<double>? chunks,
    DateTime? updatedAt,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    DateTime? scheduledAt,
    bool clearScheduledAt = false,
    bool? supportsResume,
    int? speedLimitKbps,
    bool? seedingEnabled,
    bool? seedingLimited,
    int? seedingLimitKbps,
    List<Map<String, dynamic>>? torrentFiles,
    String? downloadPageUrl,
    bool clearDownloadPageUrl = false,
    String? mergedAudioUrl,
    bool clearMergedAudioUrl = false,
    int? audioSize,
    double? audioProgress,
    bool? pausedByUser,
    String? youtubeQualityPreset,
    bool clearYoutubeQualityPreset = false,
    String? notes,
  }) {
    return DownloadTask(
      id: id,
      fileName: fileName ?? this.fileName,
      url: url ?? this.url,
      fileSize: fileSize ?? this.fileSize,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      speed: speed ?? this.speed,
      eta: clearEta ? null : eta ?? this.eta,
      category: category ?? this.category,
      status: status ?? this.status,
      savePath: savePath ?? this.savePath,
      localFilePath: localFilePath ?? this.localFilePath,
      tempFilePath: tempFilePath ?? this.tempFilePath,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      statusMessage: clearStatusMessage ? null : statusMessage ?? this.statusMessage,
      threadCount: threadCount ?? this.threadCount,
      chunks: chunks != null ? List.of(chunks) : List.of(this.chunks),
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
      scheduledAt: clearScheduledAt ? null : scheduledAt ?? this.scheduledAt,
      supportsResume: supportsResume ?? this.supportsResume,
      speedLimitKbps: speedLimitKbps ?? this.speedLimitKbps,
      seedingEnabled: seedingEnabled ?? this.seedingEnabled,
      seedingLimited: seedingLimited ?? this.seedingLimited,
      seedingLimitKbps: seedingLimitKbps ?? this.seedingLimitKbps,
      torrentFiles: torrentFiles ?? this.torrentFiles,
      downloadPageUrl: clearDownloadPageUrl ? null : downloadPageUrl ?? this.downloadPageUrl,
      mergedAudioUrl: clearMergedAudioUrl ? null : mergedAudioUrl ?? this.mergedAudioUrl,
      audioSize: audioSize ?? this.audioSize,
      audioProgress: audioProgress ?? this.audioProgress,
      pausedByUser: pausedByUser ?? this.pausedByUser,
      youtubeQualityPreset: clearYoutubeQualityPreset ? null : youtubeQualityPreset ?? this.youtubeQualityPreset,
      notes: notes ?? this.notes,
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
      'threadCount': threadCount,
      'chunks': chunks,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'scheduledAt': scheduledAt?.toIso8601String(),
      'supportsResume': supportsResume,
      'speedLimitKbps': speedLimitKbps,
      'seedingEnabled': seedingEnabled,
      'seedingLimited': seedingLimited,
      'seedingLimitKbps': seedingLimitKbps,
      'torrentFiles': torrentFiles,
      'downloadPageUrl': downloadPageUrl,
      'mergedAudioUrl': mergedAudioUrl,
      'audioSize': audioSize,
      'audioProgress': audioProgress,
      'pausedByUser': pausedByUser,
      'youtubeQualityPreset': youtubeQualityPreset,
      'notes': notes,
    };
  }

  factory DownloadTask.fromMap(Map<String, dynamic> map) {
    final statusName = map['status'] as String? ?? DownloadStatus.paused.name;
    final matched = DownloadStatus.values.where((v) => v.name == statusName);
    final status = matched.isNotEmpty
        ? matched.first
        : (() {
            if (kDebugMode) {
              debugPrint(
                'DownloadTask.fromMap: unknown status "$statusName" for task '
                '${map['id']}; defaulting to paused to avoid silently resuming a '
                'potentially corrupt task.',
              );
            }
            return DownloadStatus.paused;
          })();
    final rawChunks = (map['chunks'] is List ? (map['chunks'] as List) : const [0.0])
        .map((value) => (value as num?)?.toDouble().clamp(0.0, 1.0) ?? 0.0)
        .toList();
    final threadCount = (map['threadCount'] as num?)?.toInt() ?? rawChunks.length;

    // Validate chunks length matches threadCount — resize if mismatched
    List<double> chunks;
    if (rawChunks.length == threadCount) {
      chunks = rawChunks;
    } else if (rawChunks.length > threadCount) {
      chunks = rawChunks.sublist(0, threadCount);
    } else {
      chunks = [
        ...rawChunks,
        ...List.filled(threadCount - rawChunks.length, 0.0),
      ];
    }

    return DownloadTask(
      id: map['id'] as String,
      fileName: map['fileName'] as String,
      url: map['url'] as String,
      fileSize: (map['fileSize'] as num?)?.toInt() ?? 0,
      downloadedBytes: (map['downloadedBytes'] as num?)?.toInt() ?? 0,
      speed: (map['speed'] as num?)?.toDouble() ?? 0.0,
      eta: (map['eta'] as num?)?.toInt(),
      category: map['category'] as String? ?? 'Other',
      status: status,
      savePath: map['savePath'] as String? ?? '',
      localFilePath: map['localFilePath'] as String? ?? '',
      tempFilePath: map['tempFilePath'] as String? ?? '',
      errorMessage: map['errorMessage'] as String?,
      statusMessage: map['statusMessage'] as String?,
      threadCount: threadCount,
      chunks: chunks,
      createdAt:
          DateTime.tryParse(map['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(map['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      completedAt: DateTime.tryParse(map['completedAt'] as String? ?? ''),
      scheduledAt: DateTime.tryParse(map['scheduledAt'] as String? ?? ''),
      supportsResume: map['supportsResume'] as bool? ?? false,
      speedLimitKbps: (map['speedLimitKbps'] as num?)?.toInt() ?? 0,
      seedingEnabled: map['seedingEnabled'] as bool? ?? false,
      seedingLimited: map['seedingLimited'] as bool? ?? false,
      seedingLimitKbps: (map['seedingLimitKbps'] as num?)?.toInt() ?? 500,
      torrentFiles: map['torrentFiles'] is List
          ? (map['torrentFiles'] as List)
              .map((f) => f is Map ? Map<String, dynamic>.from(f) : <String, dynamic>{})
              .toList()
          : null,
      downloadPageUrl: map['downloadPageUrl'] as String?,
      mergedAudioUrl: map['mergedAudioUrl'] as String? ?? map['audioUrl'] as String?,
      audioSize: (map['audioSize'] as num?)?.toInt() ?? 0,
      audioProgress: (map['audioProgress'] as num?)?.toDouble() ?? 0.0,
      pausedByUser: map['pausedByUser'] as bool? ?? false,
      youtubeQualityPreset: map['youtubeQualityPreset'] as String?,
      notes: map['notes'] as String?,
    );
  }

  // Identity equality based on [id]. This is intentionally limited to ID comparison
  // to ensure proper identification in lists, sets, and animation transitions.
  // Note that tasks with the same ID but different states (e.g. progress, status)
  // will be considered equal under this operator.
  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is DownloadTask && other.id == id);

  @override
  int get hashCode => id.hashCode;
}

// TODO: Add unit tests for DownloadTask
//   - copyWith: each field, clearXxx flags, null preservation
//   - toMap / fromMap: round-trip fidelity, corrupt/missing keys
//   - Chunk resizing: too many, too few, exact match
//   - Unknown status fallback to paused
//   - Equality: same id equals, different id not equals
//   - Getters: isTorrent, progress, speedFormatted, etaFormatted