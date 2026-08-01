import 'dart:async';
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
  static int addTorrentFile(String filePath, String savePath) => -1;
  static void removeTorrent(int id, {bool deleteFiles = false}) {}
  static void pauseTorrent(int id) {}
  static void resumeTorrent(int id) {}
  static void recheckTorrent(int id) {}
  static void setFilePriorities(int id, List<int> priorities) {}
  static int getFileCount(int id) => 0;
  static void setUploadLimit(int bps) {}
  static void setDownloadLimit(int bps) {}
  static List<TorrentFileItem> getFiles(int id) => [];
  static Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates =>
      const Stream.empty();
  static void configureSession(SettingsProvider settings) {}
}
