import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;

import '../../features/settings/provider/settings_provider.dart';
import '../di/injection.dart';
import '../interfaces/i_torrent_service.dart';
import 'torrent_models.dart';

class TorrentServiceStub implements ITorrentService {
  TorrentServiceStub();

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
  int addTorrentFile(
    String filePath,
    String savePath, {
    String? sourceKey,
  }) =>
      -1;

  @override
  void removeTorrent(int id,
      {bool deleteFiles = false, bool deleteResumeData = false}) {}
  @override
  Future<void> pauseTorrent(int id) async {}
  @override
  void resumeTorrent(int id) {}
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
  void configureSession([SettingsProvider? settings]) {}
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
  void setPieceDeadline(int torrentId, int pieceIndex, int deadlineMs) {}
  @override
  void enableSuperSeeding(int torrentId, bool enabled) {}

  @override
  Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  ) async =>
      [];

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
  }) {
    final effectiveDownloaded = totalBytes ?? downloadedBytes ?? 0;
    if (progress < 1.0 && effectiveDownloaded <= 0) return false;
    final ratioLimit = customRatioLimit ?? shareRatioLimit ?? this.shareRatioLimit;
    if (ratioLimit > 0) {
      final effectiveTotal = effectiveDownloaded > 0 ? effectiveDownloaded : 1;
      final ratio = uploadedBytes / effectiveTotal;
      if (ratio >= ratioLimit) return true;
    }
    final maxMins = customMaxTimeMinutes ?? maxSeedingMinutes ?? maxSeedingTimeMinutes;
    if (maxMins > 0) {
      if (seedingDuration != null) {
        if (seedingDuration.inMinutes >= maxMins) return true;
      } else if (completedAt != null) {
        final minutesSeeding = DateTime.now().difference(completedAt).inMinutes;
        if (minutesSeeding >= maxMins) return true;
      }
    }
    return false;
  }
}

typedef TorrentServiceImpl = TorrentServiceStub;

class TorrentService {
  static final ITorrentService _defaultStub = TorrentServiceStub();
  static ITorrentService get _activeService =>
      getIt.isRegistered<ITorrentService>() ? getIt<ITorrentService>() : _defaultStub;

  static bool get isSupported => _activeService.isSupported;
  static bool get isInitialized => _activeService.isInitialized;
  static Future<void> get ready => _activeService.ready;
  static ValueNotifier<bool> get isAvailable => _activeService.isAvailable;
  static Set<int> get activeTorrentIds => _activeService.activeTorrentIds;
  static double progressFor(int id) => _activeService.progressFor(id);
  static Uint8List? fetchResumeBytes(int id) => _activeService.fetchResumeBytes(id);
  static Uint8List? resumeBlobFor(int id) => _activeService.resumeBlobFor(id);
  static bool get fileProgressSupported => _activeService.fileProgressSupported;
  static bool get filePrioritiesSupported => _activeService.filePrioritiesSupported;
  static bool get sequentialDownloadEnabled => _activeService.sequentialDownloadEnabled;
  static double get shareRatioLimit => _activeService.shareRatioLimit;
  static int get maxSeedingTimeMinutes => _activeService.maxSeedingTimeMinutes;

  static Future<bool> hasResumeData(String source) => _activeService.hasResumeData(source);
  static Future<void> init() => _activeService.init();
  static Future<void> saveResumeData(int torrentId) => _activeService.saveResumeData(torrentId);
  static Future<void> saveAllResumeData() => _activeService.saveAllResumeData();
  static Future<void> dispose() => _activeService.dispose();

  static int addMagnet(String magnetUri, String savePath) =>
      _activeService.addMagnet(magnetUri, savePath);

  static Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
  }) =>
      _activeService.addMagnetWithMetadataTimeout(
        magnetUri,
        savePath,
        timeout: timeout,
        onStatusUpdate: onStatusUpdate,
        maxRetries: maxRetries,
        retryDelay: retryDelay,
      );

  static int addTorrentFile(
    String filePath,
    String savePath, {
    String? sourceKey,
  }) =>
      _activeService.addTorrentFile(filePath, savePath, sourceKey: sourceKey);

  static void removeTorrent(int id,
          {bool deleteFiles = false, bool deleteResumeData = false}) =>
      _activeService.removeTorrent(id,
          deleteFiles: deleteFiles, deleteResumeData: deleteResumeData);
  static Future<void> pauseTorrent(int id) => _activeService.pauseTorrent(id);
  static void resumeTorrent(int id) => _activeService.resumeTorrent(id);
  static bool loadResumeData(int id, List<int> data) =>
      _activeService.loadResumeData(id, data);
  static bool isTorrentAlive(int id) => _activeService.isTorrentAlive(id);
  static void recheckTorrent(int id) => _activeService.recheckTorrent(id);
  static void setFilePriorities(int id, List<int> priorities) =>
      _activeService.setFilePriorities(id, priorities);
  static int getFileCount(int id) => _activeService.getFileCount(id);
  static void setUploadLimit(int bps) => _activeService.setUploadLimit(bps);
  static void setDownloadLimit(int bps) => _activeService.setDownloadLimit(bps);
  static List<TorrentFileItem> getFiles(int id) => _activeService.getFiles(id);
  static Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates =>
      _activeService.torrentUpdates;
  static Map<int, TorrentUpdateInfo> get latestStats =>
      _activeService.latestStats;
  static void configureSession([SettingsProvider? settings]) =>
      _activeService.configureSession(settings);
  static void reconfigureSession() => _activeService.reconfigureSession();
  static void autoEnableSequentialForVideo(int torrentId) =>
      _activeService.autoEnableSequentialForVideo(torrentId);
  static Future<void> autoSaveResumeData() =>
      _activeService.autoSaveResumeData();

  static List<TrackerInfo> getTrackers(int torrentId) =>
      _activeService.getTrackers(torrentId);
  static void addTracker(int torrentId, String trackerUrl, {int tier = 0}) =>
      _activeService.addTracker(torrentId, trackerUrl, tier: tier);
  static void removeTracker(int torrentId, String trackerUrl) =>
      _activeService.removeTracker(torrentId, trackerUrl);
  static void announceNow(int torrentId) => _activeService.announceNow(torrentId);

  static Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) =>
      _activeService.createTorrent(
        sourcePath: sourcePath,
        outputPath: outputPath,
        trackers: trackers,
        comment: comment,
        pieceSize: pieceSize,
        isPrivate: isPrivate,
      );

  static Future<bool> loadIpFilter(String filePath) =>
      _activeService.loadIpFilter(filePath);
  static Future<bool> downloadAndApplyBlocklist(String url) =>
      _activeService.downloadAndApplyBlocklist(url);

  static void enableSequentialDownload(int torrentId, bool enabled) =>
      _activeService.enableSequentialDownload(torrentId, enabled);
  static void setPieceDeadline(int torrentId, int pieceIndex, int deadlineMs) =>
      _activeService.setPieceDeadline(torrentId, pieceIndex, deadlineMs);
  static void enableSuperSeeding(int torrentId, bool enabled) =>
      _activeService.enableSuperSeeding(torrentId, enabled);

  static Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  ) =>
      _activeService.getAccurateFileProgress(torrentId, savePath);

  static bool shouldStopSeeding({
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
      _activeService.shouldStopSeeding(
        progress: progress,
        uploadedBytes: uploadedBytes,
        totalBytes: totalBytes,
        downloadedBytes: downloadedBytes,
        seedingDuration: seedingDuration,
        shareRatioLimit: shareRatioLimit,
        customRatioLimit: customRatioLimit,
        maxSeedingMinutes: maxSeedingMinutes,
        customMaxTimeMinutes: customMaxTimeMinutes,
        completedAt: completedAt,
      );
}
