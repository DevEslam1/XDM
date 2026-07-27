import 'dart:async';
import 'torrent_models.dart';
import '../../features/settings/provider/settings_provider.dart';

class TorrentService {
  static bool get isSupported => false;
  static bool get isInitialized => false;

  static Future<void> init() async {}
  static Future<void> dispose() async {}

  static int addMagnet(String magnetUri, String savePath) => -1;
  static int addTorrentFile(String filePath, String savePath) => -1;
  static void removeTorrent(int id, {bool deleteFiles = false}) {}
  static void pauseTorrent(int id) {}
  static void resumeTorrent(int id) {}
  static void setFilePriorities(int id, List<int> priorities) {}

  static int getFileCount(int id) => 0;
  static void setUploadLimit(int bps) {}
  static void setDownloadLimit(int bps) {}
  static List<TorrentFileItem> getFiles(int id) => [];

  static Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates => const Stream.empty();

  static void applyAdvancedSettings(SettingsProvider settings) {}
}
