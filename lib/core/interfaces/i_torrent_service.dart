import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;

import '../domain/torrent_models.dart';
import '../domain/torrent_session_settings.dart';

/// Lifecycle operations for torrent session and individual torrent handles.
abstract class ITorrentLifecycle {
  bool get isSupported;
  bool get isInitialized;
  Future<void> get ready;
  ValueNotifier<bool> get isAvailable;

  Future<void> init();
  Future<void> dispose();

  int addMagnet(String magnetUri, String savePath);
  Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
  });
  int addTorrentFile(
    String filePath,
    String savePath, {
    String? sourceKey,
  });

  void removeTorrent(
    int id, {
    bool deleteFiles = false,
    bool deleteResumeData = false,
  });
  Future<void> pauseTorrent(int id);
  Future<void> forceStopTorrent(int id);
  Future<void> resumeTorrent(int id);
  bool isTorrentAlive(int id);
}

/// Query and observation operations for torrent statistics and events.
abstract class ITorrentStats {
  Set<int> get activeTorrentIds;
  double progressFor(int id);
  List<TorrentFileItem> getFiles(int id);
  int getFileCount(int id);
  Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates;
  Map<int, TorrentUpdateInfo> get latestStats;
  Map<String, dynamic>? getTorrentSnapshot(int id);
  String get nativeVersion;
  Stream<TorrentAlertEvent> get alertUpdates;
  List<TorrentAlertEvent> getRecentAlerts([int? torrentId]);
  Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  );
  Future<Map<String, dynamic>?> getPieceProgress(int torrentId);
}

/// Persistence and restoration operations for torrent fast-resume data.
abstract class ITorrentResume {
  Uint8List? fetchResumeBytes(int id);
  Uint8List? resumeBlobFor(int id);
  bool get resumeDataSupported;
  Future<bool> hasResumeData(String source);
  Future<void> saveResumeData(int torrentId);
  Future<void> saveAllResumeData();
  bool loadResumeData(int id, List<int> data);
  Future<void> autoSaveResumeData();
}

/// Configuration, throttling, and session tuning operations.
abstract class ITorrentConfig {
  bool get fileProgressSupported;
  bool get filePrioritiesSupported;
  bool get forceRecheckSupported;
  bool get sequentialDownloadSupported;
  bool get superSeedingSupported;
  bool get pieceDeadlineSupported;
  bool get sequentialDownloadEnabled;
  bool get seedingEnabled;
  double get shareRatioLimit;
  int get maxSeedingTimeMinutes;

  void setFilePriorities(int id, List<int> priorities);
  void recheckTorrent(int id);
  void setUploadLimit(int bps);
  void setDownloadLimit(int bps);
  void configureSession([TorrentSessionSettings? settings]);
  void reconfigureSession();
  void autoEnableSequentialForVideo(int torrentId);
  void enableSequentialDownload(int torrentId, bool enabled);
  void setSequentialDownload(int torrentId, bool enabled);
  void prioritizeFile(int torrentId, int fileIndex, {int priority = 7});
  void setPieceDeadline(int torrentId, int pieceIndex, int deadlineMs);
  void enableSuperSeeding(int torrentId, bool enabled);
  void applySettingsPack(TorrentSettingsPack pack);
  Future<void> setProxy({
    required String host,
    required int port,
    required ProxyType type,
    String? username,
    String? password,
  });
  Future<void> setSslCertificate({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  });
  bool get ipFilterSupported;
  Future<bool> loadIpFilter(String filePath);
  Future<bool> downloadAndApplyBlocklist(String url);
  bool shouldStopSeeding({
    required double progress,
    required int uploadedBytes,
    int? totalBytes,
    int? downloadedBytes,
    Duration? seedingDuration,
    double? shareRatioLimit,
    double? customRatioLimit,
    int? maxSeedingMinutes,
    int? customMaxTimeMinutes,
    DateTime? completedAt,
  });
}

/// Tracker discovery, announce, and torrent creation operations.
abstract class ITorrentTrackers {
  bool get trackersSupported;
  bool get createTorrentSupported;
  List<TrackerInfo> getTrackers(int torrentId);
  void addTracker(int torrentId, String trackerUrl, {int tier = 0});
  void removeTracker(int torrentId, String trackerUrl);
  void announceNow(int torrentId);
  void boostMagnetDiscovery(int torrentId);
  Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  });
  void addWebSeed(int torrentId, String url);
  void removeWebSeed(int torrentId, String url);
  List<String> getWebSeeds(int torrentId);
  int? idForSource(String source);
}

/// Composite interface contract for Torrent client operations.
/// Extends segregated sub-interfaces to maintain complete backward compatibility.
abstract class ITorrentService
    implements
        ITorrentLifecycle,
        ITorrentStats,
        ITorrentResume,
        ITorrentConfig,
        ITorrentTrackers {}
