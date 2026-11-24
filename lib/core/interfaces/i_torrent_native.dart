import 'dart:async';

import '../domain/torrent_models.dart';

/// BitTorrent Alert types mapped from native libtorrent alerts.
enum TorrentAlertType {
  metadataReceived,
  torrentPaused,
  torrentResumed,
  pieceFinished,
  saveResumeDataCompleted,
  saveResumeDataFailed,
  trackerReply,
  trackerError,
  fastresumeRejected,
  torrentError,
  statusTick,
  other;

  // FIX: [Audit] Verified mapping table matching exact libtorrent 2.x alert enum without stoppedAnnounce.
  static const Map<int, TorrentAlertType> _nativeTypeMap = {
    16: TorrentAlertType.trackerReply, // tracker_reply_alert
    17: TorrentAlertType.trackerError, // tracker_error_alert
    19: TorrentAlertType.fastresumeRejected, // fastresume_rejected_alert
    26: TorrentAlertType.pieceFinished, // piece_finished_alert
    30: TorrentAlertType.saveResumeDataCompleted, // save_resume_data_alert
    31: TorrentAlertType.saveResumeDataFailed, // save_resume_data_failed_alert
    34: TorrentAlertType.torrentPaused, // torrent_paused_alert
    35: TorrentAlertType.torrentResumed, // torrent_resumed_alert
    38: TorrentAlertType.metadataReceived, // metadata_received_alert
    64: TorrentAlertType.torrentError, // torrent_error_alert
  };

  // FIX: [Audit] Semantic alert ID mapping without hardcoded magic switch statements.
  static TorrentAlertType fromNativeType(int type) =>
      _nativeTypeMap[type] ?? TorrentAlertType.other;
}

/// Native engine alert event with typed details.
class NativeAlertEvent {
  final TorrentAlertType type;
  final int alertCode;
  final int torrentId;
  final String message;
  final DateTime timestamp;
  final List<int>? resumeData;
  final int? pieceIndex;
  final String? trackerUrl;
  final String? error;

  const NativeAlertEvent({
    required this.type,
    required this.alertCode,
    required this.torrentId,
    required this.message,
    required this.timestamp,
    this.resumeData,
    this.pieceIndex,
    this.trackerUrl,
    this.error,
  });

  @override
  String toString() =>
      'NativeAlertEvent($type, id=$torrentId, code=$alertCode, msg=$message)';
}

// FIX: [Audit] Strongly typed native snapshot with complete FFI fields.
class NativeTorrentStatus {
  final int id;
  final String name;
  final String savePath;
  final String errorMsg;
  final int state;
  final String stateLabel;
  final double progress;
  final int downloadRate;
  final int uploadRate;
  final int totalDone;
  final int totalWanted;
  final int totalWantedDone;
  final int totalUploaded;
  final int numPeers;
  final int numSeeds;
  final int? numComplete;
  final int? numIncomplete;
  final int numPieces;
  final int piecesDone;
  final List<bool> pieces;
  final bool isPaused;
  final bool isFinished;
  final bool hasMetadata;
  final int queuePosition;
  final List<int> fileProgress;
  final List<int> filePriorities;
  // FIX: [Audit] Added missing FFI fields
  final String infoHashV1;
  final String infoHashV2;
  final double distributedCopies;
  final int activeTime;
  final int seedingTime;

  const NativeTorrentStatus({
    required this.id,
    required this.name,
    required this.savePath,
    required this.errorMsg,
    required this.state,
    required this.stateLabel,
    required this.progress,
    required this.downloadRate,
    required this.uploadRate,
    required this.totalDone,
    required this.totalWanted,
    required this.totalWantedDone,
    required this.totalUploaded,
    required this.numPeers,
    required this.numSeeds,
    this.numComplete,
    this.numIncomplete,
    this.numPieces = 0,
    this.piecesDone = 0,
    this.pieces = const [],
    required this.isPaused,
    required this.isFinished,
    required this.hasMetadata,
    required this.queuePosition,
    this.fileProgress = const [],
    this.filePriorities = const [],
    this.infoHashV1 = '',
    this.infoHashV2 = '',
    this.distributedCopies = 0.0,
    this.activeTime = 0,
    this.seedingTime = 0,
  });

  NativeTorrentStatus copyWith({
    String? name,
    String? savePath,
    String? errorMsg,
    bool clearErrorMsg = false,
    int? state,
    String? stateLabel,
    double? progress,
    int? downloadRate,
    int? uploadRate,
    int? totalDone,
    int? totalWanted,
    int? totalWantedDone,
    int? totalUploaded,
    int? numPeers,
    int? numSeeds,
    int? numComplete,
    int? numIncomplete,
    int? numPieces,
    int? piecesDone,
    List<bool>? pieces,
    bool? isPaused,
    bool? isFinished,
    bool? hasMetadata,
    int? queuePosition,
    List<int>? fileProgress,
    List<int>? filePriorities,
    String? infoHashV1,
    String? infoHashV2,
    double? distributedCopies,
    int? activeTime,
    int? seedingTime,
  }) =>
      NativeTorrentStatus(
        id: id,
        name: name ?? this.name,
        savePath: savePath ?? this.savePath,
        errorMsg: clearErrorMsg ? '' : (errorMsg ?? this.errorMsg),
        state: state ?? this.state,
        stateLabel: stateLabel ?? this.stateLabel,
        progress: progress ?? this.progress,
        downloadRate: downloadRate ?? this.downloadRate,
        uploadRate: uploadRate ?? this.uploadRate,
        totalDone: totalDone ?? this.totalDone,
        totalWanted: totalWanted ?? this.totalWanted,
        totalWantedDone: totalWantedDone ?? this.totalWantedDone,
        totalUploaded: totalUploaded ?? this.totalUploaded,
        numPeers: numPeers ?? this.numPeers,
        numSeeds: numSeeds ?? this.numSeeds,
        numComplete: numComplete ?? this.numComplete,
        numIncomplete: numIncomplete ?? this.numIncomplete,
        numPieces: numPieces ?? this.numPieces,
        piecesDone: piecesDone ?? this.piecesDone,
        pieces: pieces ?? this.pieces,
        isPaused: isPaused ?? this.isPaused,
        isFinished: isFinished ?? this.isFinished,
        hasMetadata: hasMetadata ?? this.hasMetadata,
        queuePosition: queuePosition ?? this.queuePosition,
        fileProgress: fileProgress ?? this.fileProgress,
        filePriorities: filePriorities ?? this.filePriorities,
        infoHashV1: infoHashV1 ?? this.infoHashV1,
        infoHashV2: infoHashV2 ?? this.infoHashV2,
        distributedCopies: distributedCopies ?? this.distributedCopies,
        activeTime: activeTime ?? this.activeTime,
        seedingTime: seedingTime ?? this.seedingTime,
      );
}

/// Strongly typed native file metadata.
class NativeFileInfo {
  final int index;
  final String name;
  final String path;
  final int size;
  final bool isStreamable;

  const NativeFileInfo({
    required this.index,
    required this.name,
    required this.path,
    required this.size,
    required this.isStreamable,
  });
}

/// Strongly typed native tracker metadata.
class NativeTrackerInfo {
  final String url;
  final int tier;
  final String status;
  final int seeds;
  final int peers;
  final String message;

  const NativeTrackerInfo({
    required this.url,
    required this.tier,
    required this.status,
    required this.seeds,
    required this.peers,
    required this.message,
  });
}

/// Strongly typed native engine configuration.
/// FIX: [Audit] Standardized boundary units: cacheSize in Bytes, rate limits in Bytes/second.
class NativeBtConfig {
  /// Cache size in bytes (default 64MB: 64 * 1024 * 1024).
  final int cacheSize;
  final int readerReadAhead;
  final int preloadCache;
  final int connectionsLimit;
  final int torrentDisconnectTimeout;
  final bool forceEncrypt;
  final bool disableTcp;
  final bool disableUtp;
  final bool disableUpload;
  final bool disableDht;
  final bool disableUpnp;
  final bool enableIpv6;

  /// Download rate limit in Bytes/s (0 = unlimited).
  final int downloadRateLimit;

  /// Upload rate limit in Bytes/s (0 = unlimited).
  final int uploadRateLimit;
  final int peersListenPort;
  final bool responsiveMode;

  // FIX P0-6: DHT bootstrap routers for magnet metadata.
  // Without routers, DHT never connects behind NAT on libtorrent 2.x.
  final List<String> dhtBootstrapNodes;

  const NativeBtConfig({
    this.cacheSize = 64 * 1024 * 1024,
    this.readerReadAhead = 95,
    this.preloadCache = 50,
    this.connectionsLimit = 200,
    this.torrentDisconnectTimeout = 30,
    this.forceEncrypt = false,
    this.disableTcp = false,
    this.disableUtp = false,
    this.disableUpload = false,
    this.disableDht = false,
    this.disableUpnp = false,
    this.enableIpv6 = false,
    this.downloadRateLimit = 0,
    this.uploadRateLimit = 0,
    this.peersListenPort = 0,
    this.responsiveMode = true,
    this.dhtBootstrapNodes = const [
      'router.bittorrent.com:6881',
      'dht.transmissionbt.com:6881',
      'router.utorrent.com:6881',
      'dht.libtorrent.org:25401',
    ],
  });
}

/// Capability flags for the loaded native BitTorrent bridge.
///
/// These describe what the bridge can actually do, rather than what the
/// application wishes it could do, so a newer bridge can auto-enable features
/// without editing hardcoded getters. [TorrentNativeCapabilities.v192] pins the
/// exact capabilities of the bundled `libtorrent_flutter` 1.9.2 bridge;
/// [TorrentNativeCapabilities.all] is the optimistic set used by tests and
/// future bridges.
class TorrentNativeCapabilities {
  /// ABI-2-only `lt_get_file_progress` export; absent on 1.9.2.
  final bool fileProgress;

  /// Native file-priority read-back is absent on 1.9.2; priorities are cached
  /// Dart-side instead.
  final bool filePriorities;

  /// Resume-data save/load exports (`lt_save_resume_data` et al.) are ABI-2
  /// only and absent from 1.9.2.
  final bool resumeData;

  /// Force-recheck has a working export on 1.9.2.
  final bool forceRecheck;

  /// Tracker management (`lt_get_trackers`, add/remove) is ABI-2 only.
  final bool trackers;

  /// Reannounce depends on tracker management and is unavailable without it.
  final bool reannounce;

  /// No FFI-bound symbol backs torrent creation on 1.9.2.
  final bool createTorrent;

  /// IP-filter loading has no bound export on 1.9.2.
  final bool ipFilter;

  /// The sequential-download setter is a logged no-op on 1.9.2.
  final bool sequentialDownload;

  /// The super-seeding setter is a logged no-op on 1.9.2.
  final bool superSeeding;

  /// The piece-deadline setter is a logged no-op on 1.9.2.
  final bool pieceDeadline;

  /// addWebSeed/removeWebSeed/getWebSeeds are logged no-ops on 1.9.2.
  final bool webSeeds;

  /// `setProxy` is a logged no-op on 1.9.2.
  final bool proxy;

  /// `setSslCertificate` is a logged no-op on 1.9.2.
  final bool ssl;

  /// 1.9.2's BtConfig exposes no peer-exchange knob.
  final bool peerExchange;

  /// 1.9.2's BtConfig exposes no local peer/service discovery knob.
  final bool localPeerDiscovery;

  /// Standalone NAT-PMP is folded into the UPnP toggle on 1.9.2.
  final bool natPmp;

  /// 1.9.2's BtConfig exposes no anonymous-mode knob.
  final bool anonymousMode;

  /// 1.9.2's BtConfig exposes no per-torrent connection cap.
  final bool perTorrentConnectionLimit;

  const TorrentNativeCapabilities({
    this.fileProgress = false,
    this.filePriorities = false,
    this.resumeData = false,
    this.forceRecheck = true,
    this.trackers = false,
    this.reannounce = false,
    this.createTorrent = false,
    this.ipFilter = false,
    this.sequentialDownload = false,
    this.superSeeding = false,
    this.pieceDeadline = false,
    this.webSeeds = false,
    this.proxy = false,
    this.ssl = false,
    this.peerExchange = false,
    this.localPeerDiscovery = false,
    this.natPmp = false,
    this.anonymousMode = false,
    this.perTorrentConnectionLimit = false,
  });

  /// Capabilities of the pinned `libtorrent_flutter` 1.9.2 bridge.
  ///
  /// Only force-recheck is available. Several flags were previously hardcoded
  /// `true`, which made the app request work the native side could not perform:
  /// `resumeData` sent every graceful pause into a 5s wait for a
  /// save_resume_data alert that no export could ever post, three times over,
  /// and then force-stopped the torrent — dropping all peers and re-handshaking
  /// from scratch. The absent exports are bound as nullable so the calls
  /// themselves are safe; the flags exist so callers can skip them instead of
  /// timing out to find out.
  const factory TorrentNativeCapabilities.v192() =
      TorrentNativeCapabilities._v192;

  /// Capabilities supported by `libtorrent_dart` 1.2.0 (libtorrent 2.0.11).
  const factory TorrentNativeCapabilities.v2011() =
      TorrentNativeCapabilities._v2011;

  /// Every capability advertised as supported.
  const factory TorrentNativeCapabilities.all() =
      TorrentNativeCapabilities._all;

  const TorrentNativeCapabilities._v192()
      : fileProgress = false,
        filePriorities = false,
        resumeData = false,
        forceRecheck = true,
        trackers = false,
        reannounce = false,
        createTorrent = false,
        ipFilter = false,
        sequentialDownload = false,
        superSeeding = false,
        pieceDeadline = false,
        webSeeds = false,
        proxy = false,
        ssl = false,
        peerExchange = false,
        localPeerDiscovery = false,
        natPmp = false,
        anonymousMode = false,
        perTorrentConnectionLimit = false;

  const TorrentNativeCapabilities._v2011()
      : fileProgress = true,
        filePriorities = true,
        resumeData = true,
        forceRecheck = true,
        trackers = true,
        reannounce = true,
        createTorrent = true,
        ipFilter = false,
        sequentialDownload = true,
        superSeeding = true,
        pieceDeadline = true,
        webSeeds = true,
        proxy = true,
        ssl = false,
        peerExchange = false,
        localPeerDiscovery = true,
        natPmp = true,
        anonymousMode = true,
        perTorrentConnectionLimit = true;

  const TorrentNativeCapabilities._all()
      : fileProgress = true,
        filePriorities = true,
        resumeData = true,
        forceRecheck = true,
        trackers = true,
        reannounce = true,
        createTorrent = true,
        ipFilter = true,
        sequentialDownload = true,
        superSeeding = true,
        pieceDeadline = true,
        webSeeds = true,
        proxy = true,
        ssl = true,
        peerExchange = true,
        localPeerDiscovery = true,
        natPmp = true,
        anonymousMode = true,
        perTorrentConnectionLimit = true;
}

/// Abstract contract for typed native BitTorrent engine interactions.
abstract class ITorrentNative {
  bool get isInitialized;
  String get libraryVersion;

  /// One-line health report of the loaded native bridge, or `null` when the
  /// implementation has no native binary to report on.
  ///
  /// Non-null with [isBridgeCompatible] false means the loaded binary does not
  /// match these bindings — struct fields read as zero and exports are missing,
  /// so sizes, per-file progress, trackers and resume data are unreliable.
  String? get bridgeDiagnostics => null;

  /// Whether the loaded native bridge matches the ABI these bindings expect.
  bool get isBridgeCompatible => true;

  /// Capabilities the loaded bridge can actually perform.
  ///
  /// Defaults to the pinned `libtorrent_flutter` 1.9.2 matrix; implementations
  /// backed by a newer bridge override this to advertise the extra features.
  TorrentNativeCapabilities get capabilities =>
      const TorrentNativeCapabilities.v192();

  /// Whether [recheckTorrent] is supported by the loaded bridge.
  bool get forceRecheckSupported => capabilities.forceRecheck;

  Stream<NativeAlertEvent> get alertStream;
  Stream<Map<int, NativeTorrentStatus>> get statusStream;

  Future<void> init({
    String listenInterface = '',
    int downloadLimit = 0,
    int uploadLimit = 0,
    Duration pollInterval = const Duration(milliseconds: 600),
    bool fetchTrackers = true,
    String? defaultSavePath,
  });

  Future<void> dispose();

  int addMagnet(String magnetUri, String savePath,
      {bool streamOnly = false, List<int>? resumeData});
  int addTorrentFile(String filePath, String savePath,
      {bool streamOnly = false, List<int>? resumeData});
  void removeTorrent(int id, {bool deleteFiles = false});
  Future<void> pauseTorrent(int id, {bool graceful = true});
  Future<void> resumeTorrent(int id);
  void recheckTorrent(int id);

  NativeTorrentStatus? getTorrentStatus(int id);
  Map<int, NativeTorrentStatus> getAllTorrentStatuses();

  List<NativeFileInfo> getFiles(int id);
  void setFilePriorities(int id, List<int> priorities);
  List<int> getFilePriorities(int id);
  List<int> getFileProgress(int id);

  // FIX: [Audit] Added getPeers to native contract to feed peer diagnostics / PeerPanel.
  Future<List<PeerConnectionQuality>> getPeers(int torrentId);

  Future<List<int>?> saveResumeData(
    int id, {
    Duration timeout = const Duration(seconds: 5),
  });
  bool loadResumeData(int id, List<int> data);

  void setDownloadLimit(int bps);
  void setUploadLimit(int bps);

  void configureSession(NativeBtConfig config);
  NativeBtConfig getDefaultConfig();

  List<NativeTrackerInfo> getTrackers(int id);
  void addTracker(int id, String trackerUrl, {int tier = 0});
  void removeTracker(int id, String trackerUrl);
  void announceNow(int id);

  void setSequentialDownload(int id, bool enabled);
  void setSuperSeeding(int id, bool enabled);
  void setPieceDeadline(int id, int pieceIndex, int deadlineMs);

  Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  });

  Future<bool> loadIpFilter(String filePath);

  Future<void> setProxy({
    required String host,
    required int port,
    required int type,
    String? username,
    String? password,
  });

  Future<void> setSslCertificate({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  });

  void addWebSeed(int id, String url);
  void removeWebSeed(int id, String url);
  List<String> getWebSeeds(int id);
}
