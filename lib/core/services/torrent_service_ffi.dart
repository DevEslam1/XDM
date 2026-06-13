import 'dart:async';
import 'package:libtorrent_flutter/libtorrent_flutter.dart' hide formatBytes;

class TorrentService {
  static final Set<int> _activeTorrentIds = {};
  static StreamSubscription? _updatesSub;

  static bool get isSupported => true;
  static bool get isInitialized => LibtorrentFlutter.isInitialized;

  static Future<void> init() async {
    await LibtorrentFlutter.init();
    _startTrackingUpdates();
  }

  static void _startTrackingUpdates() {
    if (_updatesSub != null) return;
    _updatesSub = LibtorrentFlutter.instance.torrentUpdates.listen((torrents) {
      _activeTorrentIds.clear();
      _activeTorrentIds.addAll(torrents.keys);
    });
  }

  static int addMagnet(String magnetUri, String savePath) {
    _startTrackingUpdates();
    final id = LibtorrentFlutter.instance.addMagnet(magnetUri, savePath);
    if (id >= 0) {
      _activeTorrentIds.add(id);
    }
    return id;
  }

  static int addTorrentFile(String filePath, String savePath) {
    _startTrackingUpdates();
    final id = LibtorrentFlutter.instance.addTorrentFile(filePath, savePath);
    if (id >= 0) {
      _activeTorrentIds.add(id);
    }
    return id;
  }

  static void removeTorrent(int id, {bool deleteFiles = false}) {
    _startTrackingUpdates();
    if (id >= 0 && _activeTorrentIds.contains(id)) {
      _activeTorrentIds.remove(id);
      try {
        LibtorrentFlutter.instance.removeTorrent(id, deleteFiles: deleteFiles);
      } catch (_) {}
    }
  }

  static void pauseTorrent(int id) {
    _startTrackingUpdates();
    if (id >= 0 && _activeTorrentIds.contains(id)) {
      try {
        LibtorrentFlutter.instance.pauseTorrent(id);
      } catch (_) {}
    }
  }

  static void resumeTorrent(int id) {
    _startTrackingUpdates();
    if (id >= 0 && _activeTorrentIds.contains(id)) {
      try {
        LibtorrentFlutter.instance.resumeTorrent(id);
      } catch (_) {}
    }
  }

  static void setFilePriorities(int id, List<int> priorities) {
    _startTrackingUpdates();
    if (id >= 0 && _activeTorrentIds.contains(id)) {
      try {
        LibtorrentFlutter.instance.setFilePriorities(id, priorities);
      } catch (_) {}
    }
  }

  static List<TorrentFileItem> getFiles(int id) {
    _startTrackingUpdates();
    if (id >= 0 && _activeTorrentIds.contains(id)) {
      try {
        final files = LibtorrentFlutter.instance.getFiles(id);
        return files.map((f) => TorrentFileItem(
          index: f.index,
          name: f.name,
          size: f.size,
        )).toList();
      } catch (_) {}
    }
    return [];
  }

  static Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates {
    _startTrackingUpdates();
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
        numSeeds: value.numSeeds,
        numPeers: value.numPeers,
      )));
    });
  }

  static void setUploadLimit(int bps) {
    _startTrackingUpdates();
    if (isInitialized) {
      try {
        LibtorrentFlutter.instance.setUploadLimit(bps);
      } catch (_) {}
    }
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
  final int numSeeds;
  final int numPeers;

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
    this.numSeeds = 0,
    this.numPeers = 0,
  });
}
