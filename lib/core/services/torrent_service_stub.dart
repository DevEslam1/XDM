import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'torrent_models.dart';
import '../../features/settings/provider/settings_provider.dart';

class TorrentService {
  static bool get isSupported => false;
  static bool get isInitialized => false;
  static Future<void> get ready => Future.value();
  static final ValueNotifier<bool> isAvailable = ValueNotifier(false);
  static Set<int> get activeTorrentIds => const <int>{};
  static Uint8List? progressFor(int id) => null;
  static Uint8List? fetchResumeBytes(int id) => null;
  static Uint8List? resumeBlobFor(int id) => null;
  static bool fileProgressSupported = false;
  static bool filePrioritiesSupported = false;
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
  }) async =>
      -1;

  static int addTorrentFile(
    String filePath,
    String savePath, {
    String? sourceKey,
  }) =>
      -1;

  static void removeTorrent(int id, {bool deleteFiles = false}) {}
  static Future<void> pauseTorrent(int id) async {}
  static void resumeTorrent(int id) {}
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
  static void configureSession(SettingsProvider settings) {}

  static List<TrackerInfo> getTrackers(int torrentId) => [];
  static void addTracker(int torrentId, String trackerUrl, {int tier = 0}) {}
  static void removeTracker(int torrentId, String trackerUrl) {}
  static void announceNow(int torrentId) {}

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
