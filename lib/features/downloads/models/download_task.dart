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
  final bool isAppUpdate;
  final int priority; // 0 = normal, 1 = high, 2 = urgent
  final String? playlistId; // groups playlist videos into one card
  final String? playlistTitle;
  final String? thumbnailUrl;
  final String? expectedSha256;
  final List<String>? mirrorUrls;

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
    this.isAppUpdate = false,
    this.priority = 0,
    this.playlistId,
    this.playlistTitle,
    this.thumbnailUrl,
    this.expectedSha256,
    this.mirrorUrls,
  });

  bool get isTorrent => isTorrentUrl(url, fileName: fileName);

  bool get isPlaylistItem => playlistId != null && playlistId!.isNotEmpty;

  /// Total size with fallbacks: stored [fileSize] first, then the sum of the
  /// selected torrent files (magnets only learn their size after metadata),
  /// then 0. Every size/percentage readout must go through this getter so
  /// torrents with a late-resolved size still render correct numbers.
  int get resolvedFileSize {
    if (fileSize > 0) return fileSize;
    if (torrentFiles != null && torrentFiles!.isNotEmpty) {
      final sum = torrentFiles!
          .where((f) => f['selected'] != false)
          .fold<int>(0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0));
      if (sum > 0) return sum;
    }
    return 0;
  }

  double get progress {
    if (status == DownloadStatus.completed) return 1.0;
    final total = resolvedFileSize;
    if (total <= 0) return 0.0;
    return (downloadedBytes / total).clamp(0.0, 1.0);
  }

  String get progressPercentString {
    if (status == DownloadStatus.completed) return '100.0%';
    if (resolvedFileSize <= 0) return '0.0%';
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
    final total = resolvedFileSize;
    if (total > 0) return formatBytes(total);
    if (status == DownloadStatus.completed && downloadedBytes > 0) {
      return formatBytes(downloadedBytes);
    }
    return 'Unknown';
  }

  /// Downloaded bytes, clamped so a late-resolved total can never render
  /// "1.4 GB / 800 MB" style rows.
  String get downloadedSizeFormatted {
    final total = resolvedFileSize;
    if (total > 0 && downloadedBytes > total) return formatBytes(total);
    return formatBytes(downloadedBytes);
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
    bool? isAppUpdate,
    int? priority,
    String? playlistTitle,
    bool clearPlaylist = false,
    String? thumbnailUrl,
    bool clearThumbnail = false,
    String? expectedSha256,
    List<String>? mirrorUrls,
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
      statusMessage:
          clearStatusMessage ? null : statusMessage ?? this.statusMessage,
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
      torrentFiles: torrentFiles != null
          ? [for (final m in torrentFiles) Map<String, dynamic>.from(m)]
          : this
              .torrentFiles
              ?.map((m) => Map<String, dynamic>.from(m))
              .toList(),
      downloadPageUrl:
          clearDownloadPageUrl ? null : downloadPageUrl ?? this.downloadPageUrl,
      mergedAudioUrl:
          clearMergedAudioUrl ? null : mergedAudioUrl ?? this.mergedAudioUrl,
      audioSize: audioSize ?? this.audioSize,
      audioProgress: audioProgress ?? this.audioProgress,
      pausedByUser: pausedByUser ?? this.pausedByUser,
      youtubeQualityPreset: clearYoutubeQualityPreset
          ? null
          : youtubeQualityPreset ?? this.youtubeQualityPreset,
      notes: notes ?? this.notes,
      isAppUpdate: isAppUpdate ?? this.isAppUpdate,
      priority: priority ?? this.priority,
      // ignore: unnecessary_this
      playlistId: clearPlaylist ? null : playlistId ?? this.playlistId,
      playlistTitle: clearPlaylist ? null : playlistTitle ?? this.playlistTitle,
      thumbnailUrl: clearThumbnail ? null : thumbnailUrl ?? this.thumbnailUrl,
      expectedSha256: expectedSha256 ?? this.expectedSha256,
      mirrorUrls: mirrorUrls ?? this.mirrorUrls,
    );
  }

  /// ⚠️ These methods are used for backup export/import and inter-isolate messaging.
  /// The Drift companion in `app_database.dart` is the source of truth for persistence.
  /// Any new field MUST be added to BOTH paths.
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
      'isAppUpdate': isAppUpdate,
      'priority': priority,
      'playlistId': playlistId,
      'playlistTitle': playlistTitle,
      'thumbnailUrl': thumbnailUrl,
      'expectedSha256': expectedSha256,
      'mirrorUrls': mirrorUrls,
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
            .map((value) => (value as num?)?.toDouble().clamp(0.0, 1.0) ?? 0.0)
            .toList();
    final threadCount =
        (map['threadCount'] as num?)?.toInt() ?? rawChunks.length;
    // Validate chunks length matches threadCount — resize if mismatched.
    // When truncating, preserve overall progress by redistributing across
    // the new count.
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
      final existingSum = rawChunks.fold<double>(0.0, (s, c) => s + c);
      final remaining = threadCount - rawChunks.length;
      chunks = [...rawChunks, ...List.filled(remaining, 0.0)];
      if (kDebugMode) {
        debugPrint(
          'DownloadTask.fromMap: chunk count mismatch for task ${map['id']}: '
          'stored ${rawChunks.length} chunks but threadCount=$threadCount. '
          'Padding with $remaining zero chunks (existing progress: ${existingSum.toStringAsFixed(2)}).',
        );
      }
    }
    if (matched.isEmpty) {
      final task = DownloadTask(
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
        errorMessage: 'Unknown status "$statusName" (recovered as paused)',
        statusMessage: map['statusMessage'] as String?,
        threadCount: threadCount,
        chunks: chunks,
        createdAt: _parseFlexDate(map['createdAt']),
        updatedAt: _parseFlexDate(map['updatedAt']),
        completedAt: _parseNullableFlexDate(map['completedAt']),
        scheduledAt: _parseNullableFlexDate(map['scheduledAt']),
        supportsResume: map['supportsResume'] as bool? ?? false,
        speedLimitKbps: (map['speedLimitKbps'] as num?)?.toInt() ?? 0,
        seedingEnabled: map['seedingEnabled'] as bool? ?? false,
        seedingLimited: map['seedingLimited'] as bool? ?? false,
        seedingLimitKbps: (map['seedingLimitKbps'] as num?)?.toInt() ?? 500,
        torrentFiles: map['torrentFiles'] is List
            ? (map['torrentFiles'] as List)
                .map(
                  (f) => f is Map
                      ? Map<String, dynamic>.from(f)
                      : <String, dynamic>{},
                )
                .toList()
            : null,
        downloadPageUrl: map['downloadPageUrl'] as String?,
        mergedAudioUrl:
            map['mergedAudioUrl'] as String? ?? map['audioUrl'] as String?,
        audioSize: (map['audioSize'] as num?)?.toInt() ?? 0,
        audioProgress: (map['audioProgress'] as num?)?.toDouble() ?? 0.0,
        pausedByUser: map['pausedByUser'] as bool? ?? false,
        youtubeQualityPreset: map['youtubeQualityPreset'] as String?,
        notes: map['notes'] as String?,
        isAppUpdate: map['isAppUpdate'] as bool? ?? false,
        priority: map['priority'] as int? ?? 0,
        playlistId: map['playlistId'] as String?,
        playlistTitle: map['playlistTitle'] as String?,
        thumbnailUrl: map['thumbnailUrl'] as String?,
        expectedSha256: map['expectedSha256'] as String?,
        mirrorUrls: map['mirrorUrls'] is List
            ? (map['mirrorUrls'] as List).map((e) => e.toString()).toList()
            : null,
      );
      return task;
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
      errorMessage: map['errorMessage'] as String?,
      statusMessage: map['statusMessage'] as String?,
      threadCount: threadCount,
      chunks: chunks,
      createdAt: _parseFlexDate(map['createdAt']),
      updatedAt: _parseFlexDate(map['updatedAt']),
      completedAt: _parseNullableFlexDate(map['completedAt']),
      scheduledAt: _parseNullableFlexDate(map['scheduledAt']),
      supportsResume: map['supportsResume'] as bool? ?? false,
      speedLimitKbps: (map['speedLimitKbps'] as num?)?.toInt() ?? 0,
      seedingEnabled: map['seedingEnabled'] as bool? ?? false,
      seedingLimited: map['seedingLimited'] as bool? ?? false,
      seedingLimitKbps: (map['seedingLimitKbps'] as num?)?.toInt() ?? 500,
      torrentFiles: map['torrentFiles'] is List
          ? (map['torrentFiles'] as List)
              .map(
                (f) => f is Map
                    ? Map<String, dynamic>.from(f)
                    : <String, dynamic>{},
              )
              .toList()
          : null,
      downloadPageUrl: map['downloadPageUrl'] as String?,
      mergedAudioUrl:
          map['mergedAudioUrl'] as String? ?? map['audioUrl'] as String?,
      audioSize: (map['audioSize'] as num?)?.toInt() ?? 0,
      audioProgress: (map['audioProgress'] as num?)?.toDouble() ?? 0.0,
      pausedByUser: map['pausedByUser'] as bool? ?? false,
      youtubeQualityPreset: map['youtubeQualityPreset'] as String?,
      notes: map['notes'] as String?,
      isAppUpdate: map['isAppUpdate'] as bool? ?? false,
      priority: map['priority'] as int? ?? 0,
      playlistId: map['playlistId'] as String?,
      playlistTitle: map['playlistTitle'] as String?,
      thumbnailUrl: map['thumbnailUrl'] as String?,
      expectedSha256: map['expectedSha256'] as String?,
      mirrorUrls: map['mirrorUrls'] is List
          ? (map['mirrorUrls'] as List).map((e) => e.toString()).toList()
          : null,
    );
  }

  // Identity equality based on [id] (plus playlist grouping keys) so cards
  // animate correctly in lists.
  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is DownloadTask && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
