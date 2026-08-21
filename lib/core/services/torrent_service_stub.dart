import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueNotifier;
import '../domain/torrent_session_settings.dart';
import '../interfaces/i_torrent_service.dart';
import 'torrent_models.dart';

class TorrentService {
  static bool get isSupported => false;
  static bool get isInitialized => false;
  static Future<void> get ready => Future.value();
  static final ValueNotifier<bool> isAvailable = ValueNotifier(false);
  static Stream<TorrentAlertEvent> get alertUpdates => const Stream.empty();
  static Set<int> get activeTorrentIds => const <int>{};
  static double progressFor(int id) => 0.0;
  static Uint8List? fetchResumeBytes(int id) => null;
  static Uint8List? resumeBlobFor(int id) => null;
  static bool fileProgressSupported = false;
  static bool filePrioritiesSupported = false;
  static bool resumeDataSupported = false;
  static bool get sequentialDownloadEnabled => false;
  static double get shareRatioLimit => 2.0;
  static int get maxSeedingTimeMinutes => 0;

  static Future<bool> hasResumeData(String source) async => false;

  static Future<void> init() async {}
  static Future<void> saveResumeData(int torrentId) async {}
  static Future<void> saveAllResumeData() async {}
  static Future<void> dispose() async {}

  static int addMagnet(String magnetUri, String savePath) => -1;

  static Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
  }) async =>
      -1;

  static int addTorrentFile(
    String filePath,
    String savePath, {
    String? sourceKey,
  }) =>
      -1;

  static void removeTorrent(int id,
      {bool deleteFiles = false, bool deleteResumeData = false}) {}
  static Future<void> pauseTorrent(int id) async {}
  static Future<void> forceStopTorrent(int id) async {}
  static Future<void> resumeTorrent(int id) async {}
  static bool loadResumeData(int id, List<int> data) => false;
  static bool isTorrentAlive(int id) => false;
  static void recheckTorrent(int id) {}
  static void setFilePriorities(int id, List<int> priorities) {}
  static int getFileCount(int id) => 0;
  static void setUploadLimit(int bps) {}
  static void setDownloadLimit(int bps) {}
  static List<TorrentFileItem> getFiles(int id) => [];
  static Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates =>
      const Stream.empty();
  static Map<int, TorrentUpdateInfo> get latestStats => const {};
  static void configureSession([TorrentSessionSettings? settings]) {}
  static void reconfigureSession() {}

  static List<TrackerInfo> getTrackers(int torrentId) => [];
  static void addTracker(int torrentId, String trackerUrl, {int tier = 0}) {}
  static void removeTracker(int torrentId, String trackerUrl) {}
  static void announceNow(int torrentId) {}
  static void boostMagnetDiscovery(int torrentId) {}
  static bool get seedingEnabled => true;

  static Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) async =>
      null;

  static Future<bool> loadIpFilter(String filePath) async => false;
  static Future<bool> downloadAndApplyBlocklist(String url) async => false;

  static void enableSequentialDownload(int torrentId, bool enabled) {}
  static void setPieceDeadline(int torrentId, int pieceIndex, int deadlineMs) {}
  static void enableSuperSeeding(int torrentId, bool enabled) {}

  static Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  ) async =>
      [];

  static void addWebSeed(int torrentId, String url) {}
  static void removeWebSeed(int torrentId, String url) {}
  static List<String> getWebSeeds(int torrentId) => const [];

  static Future<void> setProxy({
    required String host,
    required int port,
    required ProxyType type,
    String? username,
    String? password,
  }) async {}

  static Future<void> setSslCertificate({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  }) async {}

  static bool shouldStopSeeding({
    required double progress,
    required int uploadedBytes,
    required int downloadedBytes,
    required double shareRatioLimit,
    required int maxSeedingMinutes,
    DateTime? completedAt,
  }) {
    if (progress < 1.0 && downloadedBytes <= 0) return false;
    if (shareRatioLimit > 0) {
      final effectiveDownloaded = downloadedBytes > 0 ? downloadedBytes : 1;
      final ratio = uploadedBytes / effectiveDownloaded;
      if (ratio >= shareRatioLimit) return true;
    }
    if (maxSeedingMinutes > 0 && completedAt != null) {
      final minutesSeeding = DateTime.now().difference(completedAt).inMinutes;
      if (minutesSeeding >= maxSeedingMinutes) return true;
    }
    return false;
  }
}

class TorrentServiceImpl implements ITorrentService {
  @override
  bool get isSupported => false;
  @override
  bool get isInitialized => false;
  @override
  Future<void> get ready => Future.value();
  @override
  final ValueNotifier<bool> isAvailable = ValueNotifier(false);
  @override
  Set<int> get activeTorrentIds => const <int>{};
  @override
  double progressFor(int id) => 0.0;
  @override
  Uint8List? fetchResumeBytes(int id) => null;
  @override
  Uint8List? resumeBlobFor(int id) => null;
  @override
  bool get fileProgressSupported => false;
  @override
  bool get filePrioritiesSupported => false;
  @override
  bool get resumeDataSupported => false;
  @override
  bool get forceRecheckSupported => false;
  @override
  bool get trackersSupported => false;
  @override
  bool get createTorrentSupported => false;
  @override
  bool get ipFilterSupported => false;
  @override
  bool get sequentialDownloadSupported => false;
  @override
  bool get superSeedingSupported => false;
  @override
  bool get pieceDeadlineSupported => false;
  @override
  bool get sequentialDownloadEnabled => false;
  @override
  double get shareRatioLimit => 2.0;
  @override
  int get maxSeedingTimeMinutes => 0;

  @override
  Future<bool> hasResumeData(String source) async => false;
  @override
  Future<void> init() async {}
  @override
  Future<void> saveResumeData(int torrentId) async {}
  @override
  Future<void> saveAllResumeData() async {}
  @override
  Future<void> dispose() async {}

  @override
  int addMagnet(String magnetUri, String savePath) => -1;
  @override
  Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
  }) async =>
      -1;
  @override
  int addTorrentFile(String filePath, String savePath, {String? sourceKey}) =>
      -1;

  @override
  void removeTorrent(int id,
      {bool deleteFiles = false, bool deleteResumeData = false}) {}
  @override
  Future<void> pauseTorrent(int id) async {}
  @override
  Future<void> forceStopTorrent(int id) async {}
  @override
  Future<void> resumeTorrent(int id) async {}
  @override
  bool loadResumeData(int id, List<int> data) => false;
  @override
  bool isTorrentAlive(int id) => false;
  @override
  void recheckTorrent(int id) {}
  @override
  void setFilePriorities(int id, List<int> priorities) {}
  @override
  int getFileCount(int id) => 0;
  @override
  void setUploadLimit(int bps) {}
  @override
  void setDownloadLimit(int bps) {}
  @override
  List<TorrentFileItem> getFiles(int id) => [];
  @override
  Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates =>
      const Stream.empty();
  @override
  Map<int, TorrentUpdateInfo> get latestStats => const {};
  @override
  Map<String, dynamic>? getTorrentSnapshot(int id) => null;
  @override
  String get nativeVersion => 'stub';
  @override
  void configureSession([TorrentSessionSettings? settings]) {}
  @override
  void reconfigureSession() {}
  @override
  void autoEnableSequentialForVideo(int torrentId) {}
  @override
  Future<void> autoSaveResumeData() async {}

  @override
  List<TrackerInfo> getTrackers(int torrentId) => [];
  @override
  void addTracker(int torrentId, String trackerUrl, {int tier = 0}) {}
  @override
  void removeTracker(int torrentId, String trackerUrl) {}
  @override
  void announceNow(int torrentId) {}
  @override
  void boostMagnetDiscovery(int torrentId) {}

  @override
  Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) async =>
      null;

  @override
  Future<bool> loadIpFilter(String filePath) async => false;
  @override
  Future<bool> downloadAndApplyBlocklist(String url) async => false;

  @override
  void enableSequentialDownload(int torrentId, bool enabled) {}
  @override
  void setSequentialDownload(int torrentId, bool enabled) {}
  @override
  void prioritizeFile(int torrentId, int fileIndex, {int priority = 7}) {}
  @override
  void setPieceDeadline(int torrentId, int pieceIndex, int deadlineMs) {}
  @override
  void enableSuperSeeding(int torrentId, bool enabled) {}

  @override
  Stream<TorrentAlertEvent> get alertUpdates => const Stream.empty();
  @override
  List<TorrentAlertEvent> getRecentAlerts([int? torrentId]) => const [];
  @override
  void applySettingsPack(TorrentSettingsPack pack) {}

  @override
  Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  ) async =>
      [];

  @override
  Future<Map<String, dynamic>?> getPieceProgress(int torrentId) async => null;

  @override
  Future<void> setProxy({
    required String host,
    required int port,
    required ProxyType type,
    String? username,
    String? password,
  }) async {}

  @override
  Future<void> setSslCertificate({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  }) async {}

  @override
  void addWebSeed(int torrentId, String url) {}
  @override
  void removeWebSeed(int torrentId, String url) {}
  @override
  List<String> getWebSeeds(int torrentId) => const [];

  @override
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
  }) =>
      false;
}

class TorrentServiceStub extends TorrentServiceImpl {}
