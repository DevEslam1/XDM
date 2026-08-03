import 'dart:async';
import 'dart:typed_data';
import 'torrent_models.dart';
import '../../features/settings/provider/settings_provider.dart';

class TorrentService {
  static bool get isSupported => false;
  static bool get isInitialized => false;
  static Set<int> get activeTorrentIds => const <int>{};
  static double progressFor(int id) => 0.0;
  static bool fileProgressSupported = false;
  static bool filePrioritiesSupported = false;
  static bool get sequentialDownloadEnabled => false;
  static double get shareRatioLimit => 2.0;
  static int get maxSeedingTimeMinutes => 0;
  static Future<void> init() async {}
  static Future<void> saveAllResumeData() async {}
  static Future<void> dispose() async {}
  static int addMagnet(String magnetUri, String savePath) => -1;
  static int addTorrentFile(
    String filePath,
    String savePath, {
    String? sourceKey,
  }) =>
      -1;
  static void removeTorrent(int id, {bool deleteFiles = false}) {}
  static Future<void> pauseTorrent(int id) async {}
  static void resumeTorrent(int id) {}
  static Uint8List? saveResumeData(int id) => null;
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
