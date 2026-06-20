import 'dart:async';
import 'package:libtorrent_flutter/libtorrent_flutter.dart' hide formatBytes;
import 'package:logging/logging.dart';
import 'torrent_models.dart';

class TorrentService {
  static final _log = Logger('TorrentService');
  static Set<int> _activeTorrentIds = {};
  static StreamSubscription? _updatesSub;
  static Stream<Map<int, TorrentUpdateInfo>>? _torrentUpdatesStream;

  static bool get isSupported => true;
  static bool get isInitialized => LibtorrentFlutter.isInitialized;

  static Future<void> init() async {
    await LibtorrentFlutter.init();
    _startTrackingUpdates();
  }

  static void _startTrackingUpdates() {
    if (_updatesSub != null) return;
    _updatesSub = LibtorrentFlutter.instance.torrentUpdates.listen((torrents) {
      _activeTorrentIds = Set<int>.from(torrents.keys);
    });
  }

  static Future<void> dispose() async {
    await _updatesSub?.cancel();
    _updatesSub = null;
    _torrentUpdatesStream = null;
    _activeTorrentIds.clear();
    if (isInitialized) {
      try {
        await LibtorrentFlutter.instance.dispose();
      } catch (e) {
        _log.warning('Error disposing libtorrent: $e');
      }
    }
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
    if (id >= 0) {
      try {
        LibtorrentFlutter.instance.removeTorrent(id, deleteFiles: deleteFiles);
      } catch (e) {
        _log.warning('removeTorrent failed for id $id: $e');
      }
      _activeTorrentIds.remove(id);
    }
  }

  static void pauseTorrent(int id) {
    _startTrackingUpdates();
    if (id >= 0) {
      try {
        LibtorrentFlutter.instance.pauseTorrent(id);
      } catch (e) {
        _log.warning('pauseTorrent failed for id $id: $e');
      }
    }
  }

  static void resumeTorrent(int id) {
    _startTrackingUpdates();
    if (id >= 0) {
      try {
        LibtorrentFlutter.instance.resumeTorrent(id);
      } catch (e) {
        _log.warning('resumeTorrent failed for id $id: $e');
      }
    }
  }

  static void setFilePriorities(int id, List<int> priorities) {
    _startTrackingUpdates();
    if (id >= 0) {
      try {
        LibtorrentFlutter.instance.setFilePriorities(id, priorities);
      } catch (e) {
        _log.warning('setFilePriorities failed for id $id: $e');
      }
    }
  }

  static List<TorrentFileItem> getFiles(int id) {
    _startTrackingUpdates();
    if (id >= 0) {
      try {
        final files = LibtorrentFlutter.instance.getFiles(id);
        return files.map((f) => TorrentFileItem(
          index: f.index,
          name: f.name,
          size: f.size,
        )).toList();
      } catch (e) {
        _log.warning('getFiles failed for id $id: $e');
      }
    }
    return [];
  }

  static Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates {
    _startTrackingUpdates();
    return _torrentUpdatesStream ??= LibtorrentFlutter.instance.torrentUpdates.map((map) {
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
      } catch (e) {
        _log.warning('setUploadLimit failed: $e');
      }
    }
  }
}
