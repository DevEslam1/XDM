import 'dart:async';

class TorrentService {
  static bool get isSupported => false;
  static bool get isInitialized => false;

  static Future<void> init() async {}

  static int addMagnet(String magnetUri, String savePath) => -1;
  static int addTorrentFile(String filePath, String savePath) => -1;
  static void removeTorrent(int id, {bool deleteFiles = false}) {}
  static void pauseTorrent(int id) {}
  static void resumeTorrent(int id) {}
  static void setFilePriorities(int id, List<int> priorities) {}
  static List<TorrentFileItem> getFiles(int id) => [];

  static Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates => const Stream.empty();
}

class TorrentFileItem {
  final int index;
  final String name;
  final int size;
  TorrentFileItem({required this.index, required this.name, required this.size});
}

class TorrentUpdateInfo {
  final int id;
  final String name;
  final double progress;
  final int downloadRate;
  final int uploadRate;
  final int totalDone;
  final int totalWanted;
  final bool hasMetadata;
  final String stateLabel;

  TorrentUpdateInfo({
    required this.id,
    required this.name,
    required this.progress,
    required this.downloadRate,
    required this.uploadRate,
    required this.totalDone,
    required this.totalWanted,
    required this.hasMetadata,
    required this.stateLabel,
  });
}
