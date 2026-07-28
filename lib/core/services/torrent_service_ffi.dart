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
  static bool fileProgressSupported = true;
  static bool filePrioritiesSupported = true;
  static final Map<int, double> _latestTorrentProgress = {};

  static bool get isSupported => true;
  static bool get isInitialized => LibtorrentFlutter.isInitialized;

  static Future<void> init() async {
    _disposed = false;
    await _updatesSub?.cancel();
    _updatesSub = null;
    // Close the previous controller (if any) before dropping the reference —
    // otherwise a re-init without an intervening dispose() leaks the old
    // broadcast StreamController and any listeners still attached to it.
    await _updateController?.close();
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
    StreamController<Map<int, TorrentUpdateInfo>>? controller;
    StreamSubscription? sub;
    try {
      controller = StreamController<Map<int, TorrentUpdateInfo>>.broadcast();
      sub = LibtorrentFlutter.instance.torrentUpdates.listen(
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
                  totalWantedDone: (value.progress * value.totalWanted).toInt(),
                  hasMetadata: value.hasMetadata,
                  stateLabel: value.state.label,
                  numSeeds: value.numSeeds,
                  numPeers: value.numPeers,
                ),
              ),
            );
            _latestTorrentProgress.addAll(
              mapped.map((key, value) => MapEntry(key, value.progress)),
            );
            if (!controller!.isClosed) controller.add(mapped);
          } catch (e) {
            _log.warning('Error processing torrent update: $e');
          }
        },
        cancelOnError: false,
        onError: (e) {
          _log.warning('Torrent updates stream error: $e');
        },
        onDone: () {
          if (identical(_updatesSub, sub)) _updatesSub = null;
        },
      );

      if (_disposed) {
        sub.cancel();
        controller.close();
        return;
      }
      _updateController = controller;
      _updatesSub = sub;
    } catch (e) {
      _log.warning('Failed to start torrent tracking: $e');
      sub?.cancel();
      controller?.close();
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

  static bool forceReCheckSupported = true;

  static void forceReCheck(int id) {
    if (_disposed || !isInitialized) return;
    if (id < 0) return;
    try {
      final instance = LibtorrentFlutter.instance;
      try {
        // ignore: avoid_dynamic_calls
        (instance as dynamic).forceReCheck(id);
      } on NoSuchMethodError {
        forceReCheckSupported = false;
        _log.warning(
          'forceReCheck not available in this plugin version. '
          'Torrent $id will rely on default add-time check. '
          'Update libtorrent_flutter plugin to enable forced re-check.',
        );
      }
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
        final progress = fileProgressSupported ? () {
          try {
            return (LibtorrentFlutter.instance as dynamic).getFileProgress(id)
                as List<dynamic>?;
          } on NoSuchMethodError {
            fileProgressSupported = false;
            return null;
          } catch (_) {
            return null;
          }
        }() : null;
        final priorities = filePrioritiesSupported ? () {
          try {
            return (LibtorrentFlutter.instance as dynamic).getFilePriorities(id)
                as List<dynamic>?;
          } on NoSuchMethodError {
            filePrioritiesSupported = false;
            return null;
          } catch (_) {
            return null;
          }
        }() : null;

        final overallProgress = _latestTorrentProgress[id] ?? 0.0;

        return List.generate(files.length, (i) {
          final f = files[i];
          return TorrentFileItem(
            index: f.index,
            name: f.name,
            size: f.size,
            downloadedBytes: fileProgressSupported
                ? ((progress != null && i < progress.length)
                    ? (progress[i] as num).toInt().clamp(0, f.size)
                    : 0)
                : (overallProgress * f.size).round().clamp(0, f.size),
            priority: (priorities != null && i < priorities.length)
                ? (priorities[i] as num).toInt()
                : 4,
            selected: (priorities != null && i < priorities.length)
                ? (priorities[i] as num).toInt() > 0
                : true,
          );
        });
      } catch (e) {
        _log.warning('getFiles failed for id $id: $e');
      }
    }
    return [];
  }

  static Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates {
    if (_disposed || !isInitialized) return const Stream.empty();
    _startTrackingUpdates();
    final existing = _updateController;
    if (existing != null) return existing.stream;

    late StreamController<Map<int, TorrentUpdateInfo>> bridging;
    Timer? poller;
    StreamSubscription? innerSub;
    bridging = StreamController<Map<int, TorrentUpdateInfo>>(
      onListen: () {
        poller = Timer.periodic(const Duration(milliseconds: 200), (_) {
          if (_disposed) {
            bridging.close();
            return;
          }
          final c = _updateController;
          if (c != null) {
            poller?.cancel();
            innerSub = c.stream.listen(
              bridging.add,
              onError: bridging.addError,
              onDone: bridging.close,
            );
          }
        });
      },
      onCancel: () {
        poller?.cancel();
        innerSub?.cancel();
      },
    );
    return bridging.stream;
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
