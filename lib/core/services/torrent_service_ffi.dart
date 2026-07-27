import 'dart:async';
import 'package:libtorrent_flutter/libtorrent_flutter.dart' hide formatBytes;
import 'package:logging/logging.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'torrent_models.dart';

class TorrentService {
  static final _log = Logger('TorrentService');
  static Set<int> _activeTorrentIds = {};
  static StreamSubscription? _updatesSub;
  static StreamController<Map<int, TorrentUpdateInfo>>? _updateController;
  static bool _disposed = false;

  static bool get isSupported => true;
  static bool get isInitialized => LibtorrentFlutter.isInitialized;

  static Future<void> init() async {
    _disposed = false;
    _updatesSub?.cancel();
    _updatesSub = null;
    _updateController = null;
    _isStartingTracking = false;
    await LibtorrentFlutter.init();
    _startTrackingUpdates();
  }

  static bool _isStartingTracking = false;

  static void _startTrackingUpdates() {
    if (_disposed || !isInitialized) return;
    if (_updatesSub != null || _isStartingTracking) return;
    _isStartingTracking = true;
    try {
      final controller =
          StreamController<Map<int, TorrentUpdateInfo>>.broadcast();
      final sub = LibtorrentFlutter.instance.torrentUpdates.listen(
        (torrents) {
          try {
            _activeTorrentIds = Set<int>.from(torrents.keys);
            final mapped = torrents.map(
              (key, value) => MapEntry(
                key,
                TorrentUpdateInfo(
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
                ),
              ),
            );
            controller.add(mapped);
          } catch (e) {
            _log.warning('Error processing torrent update: $e');
          }
        },
        cancelOnError: false,
        onError: (e) {
          _log.warning('Torrent updates stream error: $e');
        },
        onDone: () {
          _updatesSub = null;
        },
      );
      _updateController = controller;
      _updatesSub = sub;
    } catch (e) {
      _log.warning('Failed to start torrent tracking: $e');
      _updatesSub = null;
    } finally {
      _isStartingTracking = false;
    }
  }

  static void setDownloadLimit(int bytesPerSecond) {
    if (!isInitialized) return;
    try {
      LibtorrentFlutter.instance.setDownloadLimit(bytesPerSecond);
    } catch (e) {
      _log.warning('setDownloadLimit failed: $e');
    }
  }

  static Future<void> dispose() async {
    _disposed = true;
    await _updatesSub?.cancel();
    _updatesSub = null;
    await _updateController?.close();
    _updateController = null;
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
    if (_disposed || !isInitialized) return -1;
    _startTrackingUpdates();
    try {
      final id = LibtorrentFlutter.instance.addMagnet(magnetUri, savePath);
      if (id >= 0) {
        _activeTorrentIds.add(id);
      }
      return id;
    } catch (e) {
      _log.warning('addMagnet failed: $e');
      return -1;
    }
  }

  static int addTorrentFile(String filePath, String savePath) {
    if (_disposed || !isInitialized) return -1;
    _startTrackingUpdates();
    try {
      final id = LibtorrentFlutter.instance.addTorrentFile(filePath, savePath);
      if (id >= 0) {
        _activeTorrentIds.add(id);
      }
      return id;
    } catch (e) {
      _log.warning('addTorrentFile failed: $e');
      return -1;
    }
  }

  static void removeTorrent(int id, {bool deleteFiles = false}) {
    if (_disposed || !isInitialized) return;
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
    if (_disposed || !isInitialized) return;
    if (id >= 0) {
      try {
        LibtorrentFlutter.instance.pauseTorrent(id);
      } catch (e) {
        _log.warning('pauseTorrent failed for id $id: $e');
      }
    }
  }

  static void resumeTorrent(int id) {
    if (_disposed || !isInitialized) return;
    if (id >= 0) {
      try {
        LibtorrentFlutter.instance.resumeTorrent(id);
      } catch (e) {
        _log.warning('resumeTorrent failed for id $id: $e');
      }
    }
  }

  /// Forces libtorrent to re-hash the files already on disk for this torrent.
  ///
  /// This is what makes "resume into an existing folder" work like a proper
  /// BitTorrent client: libtorrent verifies which pieces are already present
  /// and only downloads the missing ones, instead of starting from zero.
  ///
  /// libtorrent also performs an initial check when a torrent is first added,
  /// so this call is a belt-and-braces trigger; it's wrapped so that a plugin
  /// build without the method degrades gracefully to that default behaviour.
  static void forceReCheck(int id) {
    if (_disposed || !isInitialized) return;
    if (id < 0) return;
    try {
      (LibtorrentFlutter.instance as dynamic).forceReCheck(id);
    } on NoSuchMethodError {
      _log.info('forceReCheck not exposed by plugin; relying on default add-time check.');
    } catch (e) {
      _log.warning('forceReCheck failed for torrent $id: $e');
    }
  }

  static void setFilePriorities(int id, List<int> priorities) {
    if (_disposed || !isInitialized) return;
    if (id >= 0) {
      try {
        LibtorrentFlutter.instance.setFilePriorities(id, priorities);
      } catch (e) {
        _log.warning('setFilePriorities failed for id $id: $e');
      }
    }
  }

  static int getFileCount(int id) {
    if (_disposed || !isInitialized || id < 0) return 0;
    try {
      return LibtorrentFlutter.instance.getFiles(id).length;
    } catch (e) {
      _log.warning('getFileCount failed for id $id: $e');
      return 0;
    }
  }

  static List<TorrentFileItem> getFiles(int id) {
    if (_disposed || !isInitialized) return [];
    if (id >= 0) {
      try {
        final files = LibtorrentFlutter.instance.getFiles(id);
        return files
            .map(
              (f) =>
                  TorrentFileItem(index: f.index, name: f.name, size: f.size),
            )
            .toList();
      } catch (e) {
        _log.warning('getFiles failed for id $id: $e');
      }
    }
    return [];
  }

  static Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates {
    if (_disposed || !isInitialized) return const Stream.empty();
    _startTrackingUpdates();
    return _updateController?.stream ?? const Stream.empty();
  }

  static void setUploadLimit(int bps) {
    if (_disposed || !isInitialized) return;
    try {
      LibtorrentFlutter.instance.setUploadLimit(bps);
    } catch (e) {
      _log.warning('setUploadLimit failed: $e');
    }
  }

  static void applyAdvancedSettings(SettingsProvider settings) {
    if (_disposed || !isInitialized) return;
    if (_activeTorrentIds.isNotEmpty) {
      _log.warning(
        'Applying settings while torrents are active may cause connection resets or instability.',
      );
    }
    try {
      final currentConfig = LibtorrentFlutter.instance.getDefaultConfig();
      final newConfig = currentConfig.copyWith(
        disableDht: !settings.enableDht,
        disableUpnp: !settings.enableUpnp,
        forceEncrypt: settings.forceEncrypt,
        connectionsLimit: settings.torrentConnectionsLimit,
      );
      LibtorrentFlutter.instance.configureSession(newConfig);
    } catch (e) {
      _log.warning('applyAdvancedSettings failed: $e');
    }
  }
}
