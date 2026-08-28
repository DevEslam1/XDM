import 'engine_types.dart';

// FIX-3.2: Domain-level torrent state enum decoupled from libtorrent_flutter
enum DmxTorrentState {
  error,
  checkingFiles,
  downloadingMetadata,
  downloading,
  finished,
  seeding,
  allocating,
  checkingResume,
  unknown,
}

// Backward-compatible alias
typedef TorrentState = DmxTorrentState;

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

/// Convert native integer state code to [DmxTorrentState].
DmxTorrentState stateFromInt(int v) {
  switch (v) {
    case -2:
      return DmxTorrentState.error;
    case 0:
      return DmxTorrentState.checkingFiles;
    case 1:
      return DmxTorrentState.downloadingMetadata;
    case 2:
      return DmxTorrentState.downloading;
    case 3:
      return DmxTorrentState.finished;
    case 4:
      return DmxTorrentState.seeding;
    case 5:
      return DmxTorrentState.allocating;
    case 6:
      return DmxTorrentState.checkingResume;
    default:
      return DmxTorrentState.unknown;
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
  // FIX: [Audit] Numeric state matching support
  final TorrentState state;

  /// libtorrent reports pause as a flag orthogonal to [state], so a paused
  /// torrent still carries its underlying state (e.g. downloading).
  final bool isPaused;
  final int numSeeds;
  final int numPeers;
  final int? numComplete;
  final int? numIncomplete;
  final int piecesHave;
  final int piecesTotal;
  final int downloadPayloadRate;
  final int uploadPayloadRate;
  final int totalPayloadDownload;
  final int totalPayloadUpload;
  final String currentTracker;
  final int nextAnnounceSeconds;
  final String infoHash;
  // FIX: [Audit] Added missing FFI fields
  final String infoHashV1;
  final String infoHashV2;
  final double distributedCopies;
  final int activeTime;
  final int seedingTime;
  final List<int> fileProgress;
  final List<int> filePriorities;
  final List<bool> pieces;

  int get peerCount => numPeers;
  bool get sizeKnown => hasMetadata && totalWanted > 0;
  // FIX: [Audit] Numeric state matching replacing fragile string matching
  bool get isChecking =>
      state == TorrentState.checkingFiles ||
      state == TorrentState.checkingResume ||
      stateLabel.toLowerCase().contains('checking');
  bool get isFetchingMetadata =>
      (state == TorrentState.downloadingMetadata ||
          stateLabel.toLowerCase().contains('metadata') ||
          stateLabel.toLowerCase().contains('getting')) &&
      !hasMetadata;

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
    this.state = TorrentState.unknown,
    this.isPaused = false,
    this.infoHash = '',
    this.infoHashV1 = '',
    this.infoHashV2 = '',
    this.numSeeds = 0,
    this.numPeers = 0,
    this.numComplete,
    this.numIncomplete,
    this.piecesHave = 0,
    this.piecesTotal = 0,
    this.downloadPayloadRate = 0,
    this.uploadPayloadRate = 0,
    this.totalPayloadDownload = 0,
    this.totalPayloadUpload = 0,
    this.currentTracker = '',
    this.nextAnnounceSeconds = 0,
    this.distributedCopies = 0.0,
    this.activeTime = 0,
    this.seedingTime = 0,
    List<int> fileProgress = const [],
    List<int> filePriorities = const [],
    List<bool> pieces = const [],
  })  : fileProgress = List.unmodifiable(fileProgress),
        filePriorities = List.unmodifiable(filePriorities),
        pieces = List.unmodifiable(pieces);
}

/// Swarm counts for a single torrent, split into the two things libtorrent
/// actually measures.
///
/// [connectedSeeds] / [connectedPeers] are peers this session currently holds a
/// connection to. [swarmSeeds] / [swarmPeers] are the tracker's scrape totals
/// for the whole swarm and are `null` until a scrape lands — a freshly added
/// torrent legitimately reports zero connections while the swarm is large, so
/// the two must not be conflated.
class TorrentSwarmSnapshot {
  final int connectedSeeds;
  final int connectedPeers;
  final int? swarmSeeds;
  final int? swarmPeers;

  /// libtorrent's distributed-copies estimate: how many complete copies of the
  /// torrent are reachable through the connected swarm.
  final double availability;

  const TorrentSwarmSnapshot({
    this.connectedSeeds = 0,
    this.connectedPeers = 0,
    this.swarmSeeds,
    this.swarmPeers,
    this.availability = 0.0,
  });

  static const TorrentSwarmSnapshot empty = TorrentSwarmSnapshot();

  /// True when nothing in this snapshot carries usable information, so callers
  /// can tell "no data yet" apart from "a real swarm of zero".
  bool get isEmpty =>
      connectedSeeds == 0 &&
      connectedPeers == 0 &&
      swarmSeeds == null &&
      swarmPeers == null &&
      availability <= 0.0;

  bool get hasSwarmScrape => swarmSeeds != null || swarmPeers != null;

  /// Total connections in use, seeds included.
  int get totalConnections => connectedSeeds + connectedPeers;
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

  /// True when [downloadedBytes] is not a measurement.
  ///
  /// The file is present on disk but the engine could not report how much of it
  /// has actually been written, and disk length cannot answer that question for
  /// a torrent (libtorrent allocates every file to its full length up front).
  /// [downloadedBytes] is reported as `0` in that case, so consumers must treat
  /// it as "unknown" rather than "nothing downloaded".
  final bool isEstimated;

  const TorrentFileProgress({
    required this.index,
    required this.name,
    required this.size,
    required this.downloadedBytes,
    required this.progress,
    required this.exists,
    required this.isComplete,
    this.isEstimated = false,
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
    CycleState? cycleState,
  }) {
    if (cycleState == CycleState.paused) return false;
    if (seedOnlyWhenCharging && !isCharging) return true;
    if (seedOnlyOnWifi && !isOnWifi) return true;
    if (seedDuration.inMinutes < minSeedTimeMinutes) return false;
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
