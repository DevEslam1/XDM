import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;

import '../../features/settings/provider/settings_provider.dart';
import '../services/torrent_models.dart';

/// Abstract interface contract for Torrent client operations.
abstract class ITorrentService {
  bool get isSupported;
  bool get isInitialized;
  Future<void> get ready;
  ValueNotifier<bool> get isAvailable;
  Set<int> get activeTorrentIds;
  double progressFor(int id);
  Uint8List? fetchResumeBytes(int id);
  Uint8List? resumeBlobFor(int id);
  bool get fileProgressSupported;
  bool get filePrioritiesSupported;
  bool get resumeDataSupported;
  bool get forceRecheckSupported;
  bool get trackersSupported;
  bool get createTorrentSupported;
  bool get ipFilterSupported;
  bool get sequentialDownloadSupported;
  bool get superSeedingSupported;
  bool get pieceDeadlineSupported;
  bool get sequentialDownloadEnabled;
  double get shareRatioLimit;
  int get maxSeedingTimeMinutes;

  Future<bool> hasResumeData(String source);
  Future<void> init();
  Future<void> saveResumeData(int torrentId);
  Future<void> saveAllResumeData();
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

  /// FIX-C: Hard-stops a native torrent: cancels its update subscription,
  /// pauses/removes it from the session with verification, and clears all
  /// in-memory bookkeeping so the engine fully releases the handle.
  Future<void> forceStopTorrent(int id);
  void resumeTorrent(int id);
  bool loadResumeData(int id, List<int> data);
  bool isTorrentAlive(int id);
  void recheckTorrent(int id);
  void setFilePriorities(int id, List<int> priorities);
  int getFileCount(int id);
  void setUploadLimit(int bps);
  void setDownloadLimit(int bps);
  List<TorrentFileItem> getFiles(int id);
  Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates;
  Map<int, TorrentUpdateInfo> get latestStats;

  /// FIX-D: Point-in-time snapshot of a single torrent's engine state.
  Map<String, dynamic>? getTorrentSnapshot(int id);

  /// FIX-D: Best-effort native libtorrent version string.
  String get nativeVersion;
  void configureSession([SettingsProvider? settings]);
  void reconfigureSession();
  void autoEnableSequentialForVideo(int torrentId);
  Future<void> autoSaveResumeData();

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

  Future<bool> loadIpFilter(String filePath);
  Future<bool> downloadAndApplyBlocklist(String url);

  void enableSequentialDownload(int torrentId, bool enabled);
  void setSequentialDownload(int torrentId, bool enabled);
  void prioritizeFile(int torrentId, int fileIndex, {int priority = 7});
  void setPieceDeadline(int torrentId, int pieceIndex, int deadlineMs);
  void enableSuperSeeding(int torrentId, bool enabled);

  Stream<TorrentAlertEvent> get alertUpdates;
  List<TorrentAlertEvent> getRecentAlerts([int? torrentId]);
  void applySettingsPack(TorrentSettingsPack pack);

  Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  );

  Future<Map<String, dynamic>?> getPieceProgress(int torrentId);

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

  void addWebSeed(int torrentId, String url);
  void removeWebSeed(int torrentId, String url);
  List<String> getWebSeeds(int torrentId);

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
