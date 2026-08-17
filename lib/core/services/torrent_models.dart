class TorrentFileItem {
  final int index;
  final String name;
  final int size;
  final int downloadedBytes;
  final int priority;
  final bool selected;
  final double? progressRatio;
  TorrentFileItem({
    required this.index,
    required this.name,
    required this.size,
    this.downloadedBytes = 0,
    this.priority = 4,
    this.selected = true,
    this.progressRatio,
  });
  bool get hasProgressData => downloadedBytes >= 0 || progressRatio != null;
  /// FIX v2.0.0: When downloadedBytes is 0 and progressRatio is available,
  /// prefer progressRatio (the engine may report 0 before first piece).
  int get safeDownloadedBytes {
    if (downloadedBytes > 0) return downloadedBytes;
    if (downloadedBytes == 0 && progressRatio != null && progressRatio! > 0) {
      if (size > 0) {
        return (size * progressRatio!.clamp(0.0, 1.0)).round().clamp(0, size);
      }
    }
    if (downloadedBytes >= 0) return downloadedBytes;
    if (progressRatio != null && size > 0) {
      return (size * progressRatio!.clamp(0.0, 1.0)).round().clamp(0, size);
    }
    return 0;
  }
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
  int get peerCount => numPeers;
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
  final String? infoHash;

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
    this.infoHash,
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

class TrackerInfo {
  final String url;
  final int tier;
  final String status;
  final int seeds;
  final int peers;
  final String message;

  const TrackerInfo({
    required this.url,
    required this.tier,
    required this.status,
    required this.seeds,
    required this.peers,
    required this.message,
  });
}

/// BitTorrent Info Hash protocol version.
enum TorrentHashVersion {
  v1,
  v2,
  hybrid,
  unknown,
}

/// Session settings pack model matching libtorrent settings_pack capabilities.
class TorrentSettingsPack {
  final bool enableDht;
  final bool enableLsd;
  final bool enablePex;
  final bool enableUpnp;
  final int? maxConnectionsGlobal;
  final int? maxUploadRate; // bytes/sec
  final int? maxDownloadRate; // bytes/sec
  final String? socks5ProxyHost;
  final int? socks5ProxyPort;
  final bool enforceProxy;
  final bool forceEncrypt;
  final bool enableUtp;
  final bool enableTcp;
  final int? cacheSize;

  const TorrentSettingsPack({
    this.enableDht = true,
    this.enableLsd = true,
    this.enablePex = true,
    this.enableUpnp = true,
    this.maxConnectionsGlobal,
    this.maxUploadRate,
    this.maxDownloadRate,
    this.socks5ProxyHost,
    this.socks5ProxyPort,
    this.enforceProxy = false,
    this.forceEncrypt = false,
    this.enableUtp = true,
    this.enableTcp = true,
    this.cacheSize,
  });

  TorrentSettingsPack copyWith({
    bool? enableDht,
    bool? enableLsd,
    bool? enablePex,
    bool? enableUpnp,
    int? maxConnectionsGlobal,
    int? maxUploadRate,
    int? maxDownloadRate,
    String? socks5ProxyHost,
    int? socks5ProxyPort,
    bool? enforceProxy,
    bool? forceEncrypt,
    bool? enableUtp,
    bool? enableTcp,
    int? cacheSize,
  }) {
    return TorrentSettingsPack(
      enableDht: enableDht ?? this.enableDht,
      enableLsd: enableLsd ?? this.enableLsd,
      enablePex: enablePex ?? this.enablePex,
      enableUpnp: enableUpnp ?? this.enableUpnp,
      maxConnectionsGlobal: maxConnectionsGlobal ?? this.maxConnectionsGlobal,
      maxUploadRate: maxUploadRate ?? this.maxUploadRate,
      maxDownloadRate: maxDownloadRate ?? this.maxDownloadRate,
      socks5ProxyHost: socks5ProxyHost ?? this.socks5ProxyHost,
      socks5ProxyPort: socks5ProxyPort ?? this.socks5ProxyPort,
      enforceProxy: enforceProxy ?? this.enforceProxy,
      forceEncrypt: forceEncrypt ?? this.forceEncrypt,
      enableUtp: enableUtp ?? this.enableUtp,
      enableTcp: enableTcp ?? this.enableTcp,
      cacheSize: cacheSize ?? this.cacheSize,
    );
  }

  Map<String, dynamic> toMap() => {
        'enableDht': enableDht,
        'enableLsd': enableLsd,
        'enablePex': enablePex,
        'enableUpnp': enableUpnp,
        'maxConnectionsGlobal': maxConnectionsGlobal,
        'maxUploadRate': maxUploadRate,
        'maxDownloadRate': maxDownloadRate,
        'socks5ProxyHost': socks5ProxyHost,
        'socks5ProxyPort': socks5ProxyPort,
        'enforceProxy': enforceProxy,
        'forceEncrypt': forceEncrypt,
        'enableUtp': enableUtp,
        'enableTcp': enableTcp,
        'cacheSize': cacheSize,
      };

  factory TorrentSettingsPack.fromMap(Map<String, dynamic> map) {
    return TorrentSettingsPack(
      enableDht: (map['enableDht'] as bool?) ?? true,
      enableLsd: (map['enableLsd'] as bool?) ?? true,
      enablePex: (map['enablePex'] as bool?) ?? true,
      enableUpnp: (map['enableUpnp'] as bool?) ?? true,
      maxConnectionsGlobal: (map['maxConnectionsGlobal'] as num?)?.toInt(),
      maxUploadRate: (map['maxUploadRate'] as num?)?.toInt(),
      maxDownloadRate: (map['maxDownloadRate'] as num?)?.toInt(),
      socks5ProxyHost: map['socks5ProxyHost'] as String?,
      socks5ProxyPort: (map['socks5ProxyPort'] as num?)?.toInt(),
      enforceProxy: (map['enforceProxy'] as bool?) ?? false,
      forceEncrypt: (map['forceEncrypt'] as bool?) ?? false,
      enableUtp: (map['enableUtp'] as bool?) ?? true,
      enableTcp: (map['enableTcp'] as bool?) ?? true,
      cacheSize: (map['cacheSize'] as num?)?.toInt(),
    );
  }
}

/// Comprehensive torrent metadata model supporting BitTorrent v1, v2, and Hybrid.
class TorrentMetadata {
  final String name;
  final int totalSize;
  final String? infoHashV1;
  final String? infoHashV2;
  final List<TorrentFileItem> files;
  final List<String> trackers;
  final List<String> webSeeds;
  final int pieceSize;
  final int pieceCount;
  final bool isPrivate;
  final String? comment;
  final String? createdBy;
  final DateTime? creationDate;

  const TorrentMetadata({
    required this.name,
    required this.totalSize,
    this.infoHashV1,
    this.infoHashV2,
    this.files = const [],
    this.trackers = const [],
    this.webSeeds = const [],
    this.pieceSize = 0,
    this.pieceCount = 0,
    this.isPrivate = false,
    this.comment,
    this.createdBy,
    this.creationDate,
  });

  bool get isV2Only =>
      (infoHashV2 != null && infoHashV2!.isNotEmpty) &&
      (infoHashV1 == null || infoHashV1!.isEmpty);

  bool get isHybrid =>
      (infoHashV1 != null && infoHashV1!.isNotEmpty) &&
      (infoHashV2 != null && infoHashV2!.isNotEmpty);

  bool get isV1Only =>
      (infoHashV1 != null && infoHashV1!.isNotEmpty) &&
      (infoHashV2 == null || infoHashV2!.isEmpty);

  TorrentHashVersion get version {
    if (isHybrid) return TorrentHashVersion.hybrid;
    if (isV2Only) return TorrentHashVersion.v2;
    if (isV1Only) return TorrentHashVersion.v1;
    return TorrentHashVersion.unknown;
  }

  String get primaryInfoHash =>
      infoHashV2?.isNotEmpty == true ? infoHashV2! : (infoHashV1 ?? '');
}

/// Native engine alert event for deep diagnostics and UI live logging.
class TorrentAlertEvent {
  final int type;
  final int torrentId;
  final String message;
  final DateTime timestamp;
  final String category;

  const TorrentAlertEvent({
    required this.type,
    required this.torrentId,
    required this.message,
    required this.timestamp,
    this.category = 'general',
  });

  @override
  String toString() =>
      '[${timestamp.toIso8601String()}] [T$torrentId] ($category) $message';
}

/// Supported libtorrent proxy types.
enum ProxyType {
  none,
  socks5,
  http;

  static ProxyType fromString(String? val) {
    if (val == null) return ProxyType.none;
    switch (val.toLowerCase().trim()) {
      case 'socks5':
        return ProxyType.socks5;
      case 'http':
      case 'https':
        return ProxyType.http;
      default:
        return ProxyType.none;
    }
  }

  String get displayName {
    switch (this) {
      case ProxyType.none:
        return 'None (Direct)';
      case ProxyType.socks5:
        return 'SOCKS5';
      case ProxyType.http:
        return 'HTTP';
    }
  }
}
