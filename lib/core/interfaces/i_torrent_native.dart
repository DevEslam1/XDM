import 'dart:async';

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
  stoppedAnnounce,
  statusTick,
  other;

  /// Pinned libtorrent alert codes
  static const int alertTrackerReply = 16;
  static const int alertTrackerError = 17;
  static const int alertFastresumeRejected = 19;
  static const int alertPieceFinished = 26;
  static const int alertSaveResumeDataCompleted = 30;
  static const int alertSaveResumeDataFailed = 31;
  static const int alertTorrentPaused = 34;
  static const int alertTorrentResumed = 35;
  static const int alertMetadataReceived = 38;
  static const int alertStoppedAnnounce = 45;
  static const int alertTorrentError = 64;

  /// Mappings pinned to libtorrent v1.2.x / v2.0.x alert codes.
  static const Map<int, TorrentAlertType> _nativeTypeMap = {
    alertMetadataReceived:
        TorrentAlertType.metadataReceived, // metadata_received_alert
    alertTorrentPaused: TorrentAlertType.torrentPaused, // torrent_paused_alert
    alertTorrentResumed:
        TorrentAlertType.torrentResumed, // torrent_resumed_alert
    alertPieceFinished: TorrentAlertType.pieceFinished, // piece_finished_alert
    alertSaveResumeDataCompleted:
        TorrentAlertType.saveResumeDataCompleted, // save_resume_data_alert
    alertSaveResumeDataFailed:
        TorrentAlertType.saveResumeDataFailed, // save_resume_data_failed_alert
    alertTrackerReply: TorrentAlertType.trackerReply, // tracker_reply_alert
    alertTrackerError: TorrentAlertType.trackerError, // tracker_error_alert
    alertFastresumeRejected:
        TorrentAlertType.fastresumeRejected, // fastresume_rejected_alert
    alertTorrentError: TorrentAlertType.torrentError, // torrent_error_alert
    alertStoppedAnnounce: TorrentAlertType
        .stoppedAnnounce, // tracker_announce_alert / stopped announce
  };

  // FIX(M5): Replace magic switch ints with pinned const Map lookup.
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

/// Strongly typed native snapshot for a torrent.
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
  final int numPieces;
  final int piecesDone;
  final List<bool> pieces;
  final bool isPaused;
  final bool isFinished;
  final bool hasMetadata;
  final int queuePosition;
  final List<int> fileProgress;
  final List<int> filePriorities;

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
    this.numPieces = 0,
    this.piecesDone = 0,
    this.pieces = const [],
    required this.isPaused,
    required this.isFinished,
    required this.hasMetadata,
    required this.queuePosition,
    this.fileProgress = const [],
    this.filePriorities = const [],
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
    int? numPieces,
    int? piecesDone,
    List<bool>? pieces,
    bool? isPaused,
    bool? isFinished,
    bool? hasMetadata,
    int? queuePosition,
    List<int>? fileProgress,
    List<int>? filePriorities,
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
        numPieces: numPieces ?? this.numPieces,
        piecesDone: piecesDone ?? this.piecesDone,
        pieces: pieces ?? this.pieces,
        isPaused: isPaused ?? this.isPaused,
        isFinished: isFinished ?? this.isFinished,
        hasMetadata: hasMetadata ?? this.hasMetadata,
        queuePosition: queuePosition ?? this.queuePosition,
        fileProgress: fileProgress ?? this.fileProgress,
        filePriorities: filePriorities ?? this.filePriorities,
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
class NativeBtConfig {
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
  final int downloadRateLimit;
  final int uploadRateLimit;
  final int peersListenPort;
  final bool responsiveMode;

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
  });
}

/// Abstract contract for typed native BitTorrent engine interactions.
abstract class ITorrentNative {
  bool get isInitialized;
  String get libraryVersion;

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
      {bool streamOnly = false});
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
