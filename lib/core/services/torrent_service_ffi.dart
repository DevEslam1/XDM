import 'dart:async';
import 'package:libtorrent_flutter/libtorrent_flutter.dart' hide formatBytes;

class TorrentService {
  static bool get isSupported => true;
  static bool get isInitialized => LibtorrentFlutter.isInitialized;

  static Future<void> init() async {
    await LibtorrentFlutter.init();
  }

  static int addMagnet(String magnetUri, String savePath) {
    return LibtorrentFlutter.instance.addMagnet(magnetUri, savePath);
  }

  static int addTorrentFile(String filePath, String savePath) {
    return LibtorrentFlutter.instance.addTorrentFile(filePath, savePath);
  }

  static void removeTorrent(int id, {bool deleteFiles = false}) {
    LibtorrentFlutter.instance.removeTorrent(id, deleteFiles: deleteFiles);
  }

  static void pauseTorrent(int id) {
    LibtorrentFlutter.instance.pauseTorrent(id);
  }

  static void resumeTorrent(int id) {
    LibtorrentFlutter.instance.resumeTorrent(id);
  }

  static void setFilePriorities(int id, List<int> priorities) {
    LibtorrentFlutter.instance.setFilePriorities(id, priorities);
  }

  static List<TorrentFileItem> getFiles(int id) {
    final files = LibtorrentFlutter.instance.getFiles(id);
    return files.map((f) => TorrentFileItem(
      index: f.index,
      name: f.name,
      size: f.size,
    )).toList();
  }

  static Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates {
    return LibtorrentFlutter.instance.torrentUpdates.map((map) {
      return map.map((key, value) => MapEntry(key, TorrentUpdateInfo(
        id: value.id,
        name: value.name,
        progress: value.progress,
        downloadRate: value.downloadRate,
        uploadRate: value.uploadRate,
        totalDone: value.totalDone,
        totalWanted: value.totalWanted,
        hasMetadata: value.hasMetadata,
        stateLabel: value.state.label,
      )));
    });
  }
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
