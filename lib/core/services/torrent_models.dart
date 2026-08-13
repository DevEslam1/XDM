class TorrentFileItem {
  final int index;
  final String name;
  final int size;
  final int downloadedBytes;
  final int priority;
  final bool selected;

  TorrentFileItem({
    required this.index,
    required this.name,
    required this.size,
    this.downloadedBytes = 0,
    this.priority = 4,
    this.selected = true,
  });

  /// Whether the engine has actual progress data for this file.
  bool get hasProgressData => downloadedBytes >= 0;

  /// Safe byte count (0 when no data available).
  int get safeDownloadedBytes => downloadedBytes >= 0 ? downloadedBytes : 0;
}

class TorrentUpdateInfo {
  final int id;
  final String name;
  final double progress;
  final int downloadRate;
  final int uploadRate;
  final int totalDone;
  final int totalWanted;
  final int totalWantedDone;
  final bool hasMetadata;
  final String stateLabel;
  final int numSeeds;
  final int numPeers;
  final int piecesHave;
  final int piecesTotal;
  final int downloadPayloadRate;
  final int uploadPayloadRate;
  final int totalPayloadDownload;
  final int totalPayloadUpload;
  final String currentTracker;
  final int nextAnnounceSeconds;
  final double distributedCopies;
  final List<int> fileProgress;
  final List<int> filePriorities;

  TorrentUpdateInfo({
    required this.id,
    required this.name,
    required this.progress,
    required this.downloadRate,
    required this.uploadRate,
    required this.totalDone,
    required this.totalWanted,
    required this.totalWantedDone,
    required this.hasMetadata,
    required this.stateLabel,
    this.numSeeds = 0,
    this.numPeers = 0,
    this.piecesHave = 0,
    this.piecesTotal = 0,
    this.downloadPayloadRate = 0,
    this.uploadPayloadRate = 0,
    this.totalPayloadDownload = 0,
    this.totalPayloadUpload = 0,
    this.currentTracker = '',
    this.nextAnnounceSeconds = 0,
    this.distributedCopies = 0.0,
    List<int> fileProgress = const [],
    List<int> filePriorities = const [],
  })  : fileProgress = List.unmodifiable(fileProgress),
        filePriorities = List.unmodifiable(filePriorities);
}

enum TrackerStatus {
  working,
  updating,
  notWorking,
  disabled,
}

class TorrentTrackerInfo {
  final String url;
  final TrackerStatus status;
  final int seeds;
  final int peers;
  final int downloaded;
  final String message;
  final int nextAnnounceSeconds;

  TorrentTrackerInfo({
    required this.url,
    this.status = TrackerStatus.working,
    this.seeds = 0,
    this.peers = 0,
    this.downloaded = 0,
    this.message = '',
    this.nextAnnounceSeconds = 0,
  });

  TorrentTrackerInfo copyWith({
    String? url,
    TrackerStatus? status,
    int? seeds,
    int? peers,
    int? downloaded,
    String? message,
    int? nextAnnounceSeconds,
  }) {
    return TorrentTrackerInfo(
      url: url ?? this.url,
      status: status ?? this.status,
      seeds: seeds ?? this.seeds,
      peers: peers ?? this.peers,
      downloaded: downloaded ?? this.downloaded,
      message: message ?? this.message,
      nextAnnounceSeconds: nextAnnounceSeconds ?? this.nextAnnounceSeconds,
    );
  }
}

class TorrentFileProgress {
  final int index;
  final String name;
  final int size;
  final int downloadedBytes;
  final double progress;
  final bool exists;
  final bool isComplete;

  const TorrentFileProgress({
    required this.index,
    required this.name,
    required this.size,
    required this.downloadedBytes,
    required this.progress,
    required this.exists,
    required this.isComplete,
  });
}

class PeerConnectionQuality {
  final String ip;
  final int port;
  final String client;
  final double downloadSpeed;
  final double uploadSpeed;
  final double progress;
  final bool isSeed;
  final bool isEncrypted;
  final bool isOutgoing;
  final Duration connectedDuration;
  final int failedHashChecks;
  final double relevance;

  const PeerConnectionQuality({
    required this.ip,
    required this.port,
    required this.client,
    required this.downloadSpeed,
    required this.uploadSpeed,
    required this.progress,
    required this.isSeed,
    required this.isEncrypted,
    this.isOutgoing = false,
    this.connectedDuration = Duration.zero,
    this.failedHashChecks = 0,
    this.relevance = 0.0,
  });
}

class SeedingPolicy {
  final double maxRatio;
  final Duration maxSeedTime;
  final int maxUploadBytes;
  final bool seedOnlyWhenCharging;
  final bool seedOnlyOnWifi;
  final int minSeedTimeMinutes;

  const SeedingPolicy({
    this.maxRatio = 2.0,
    this.maxSeedTime = Duration.zero,
    this.maxUploadBytes = 0,
    this.seedOnlyWhenCharging = false,
    this.seedOnlyOnWifi = false,
    this.minSeedTimeMinutes = 0,
  });

  bool shouldStopSeeding({
    required double currentRatio,
    required Duration seedDuration,
    required int uploadedBytes,
    required bool isCharging,
    required bool isOnWifi,
  }) {
    if (seedDuration.inMinutes < minSeedTimeMinutes) return false;
    if (seedOnlyWhenCharging && !isCharging) return true;
    if (seedOnlyOnWifi && !isOnWifi) return true;
    if (maxRatio > 0 && currentRatio >= maxRatio) return true;
    if (maxSeedTime > Duration.zero && seedDuration >= maxSeedTime) return true;
    if (maxUploadBytes > 0 && uploadedBytes >= maxUploadBytes) return true;
    return false;
  }
}
