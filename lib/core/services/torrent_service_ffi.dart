import 'dart:async';
import 'package:libtorrent_flutter/libtorrent_flutter.dart' hide formatBytes;
import 'package:logging/logging.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'torrent_models.dart';
import 'torrent_resume_store.dart';

/// Safe accessors for plugin methods that may not exist in all versions.
/// These replace all `as dynamic` casts with a single guarded boundary.
extension _LibtorrentSafeAccess on LibtorrentFlutter {
  List<dynamic>? tryGetFileProgress(int id) {
    try {
      // ignore: avoid_dynamic_calls
      return (this as dynamic).getFileProgress(id) as List<dynamic>?;
    } on NoSuchMethodError {
      return null;
    }
  }

  List<dynamic>? tryGetFilePriorities(int id) {
    try {
      // ignore: avoid_dynamic_calls
      return (this as dynamic).getFilePriorities(id) as List<dynamic>?;
    } on NoSuchMethodError {
      return null;
    }
  }

  void tryForceRecheck(int id) {
    try {
      // ignore: avoid_dynamic_calls
      (this as dynamic).forceReCheck(id);
    } on NoSuchMethodError {
      // Plugin does not support forceReCheck; skip silently.
    }
  }
}

enum TorrentSessionState {
  uninitialized,
  initializing,
  ready,
  pausing,
  disposing,
  disposed,
}

class TorrentService {
  static final _log = Logger('TorrentService');
  static TorrentSessionState _state = TorrentSessionState.uninitialized;
  static Set<int> _activeTorrentIds = {};
  static StreamSubscription? _updatesSub;
  static StreamController<Map<int, TorrentUpdateInfo>>? _updateController;
  static bool fileProgressSupported = true;
  static bool filePrioritiesSupported = true;
  static final Map<int, double> _latestProgress = {};

  static bool get isSupported => true;
  static bool get isInitialized => _state == TorrentSessionState.ready;
  static Set<int> get activeTorrentIds => Set.unmodifiable(_activeTorrentIds);

  /// Returns the latest known progress for a torrent, or 0.0 if unknown.
  static double progressFor(int id) => _latestProgress[id] ?? 0.0;

  static Future<void> init() async {
    if (_state != TorrentSessionState.uninitialized &&
        _state != TorrentSessionState.disposed) {
      return;
    }

    _state = TorrentSessionState.initializing;
    try {
      await TorrentResumeStore.init();
      await LibtorrentFlutter.init();
      fileProgressSupported = true;
      filePrioritiesSupported = true;
      _configureSessionFromSettings();
      _startTrackingUpdates();
      _state = TorrentSessionState.ready;
    } catch (e) {
      _state = TorrentSessionState.uninitialized;
      rethrow;
    }
  }

  static bool _sequentialDownload = false;
  static double _shareRatioLimit = 2.0;
  static int _maxSeedingTimeMinutes = 0;

  static bool get sequentialDownloadEnabled => _sequentialDownload;
  static double get shareRatioLimit => _shareRatioLimit;
  static int get maxSeedingTimeMinutes => _maxSeedingTimeMinutes;

  static void _configureSessionFromSettings() {
    try {
      final settings = SettingsProvider.instance;
      final config = LibtorrentFlutter.instance.getDefaultConfig().copyWith(
        disableDht: !settings.enableDht,
        disableUpnp: !settings.enableUpnp,
        forceEncrypt: settings.forceEncrypt,
        connectionsLimit: settings.torrentConnectionsLimit,
        downloadRateLimit: settings.speedLimitBytesPerSecond ~/ 1024,
        uploadRateLimit: settings.globalTorrentSeedingLimited
            ? settings.globalTorrentSeedingLimitKbps
            : 0,
      );
      LibtorrentFlutter.instance.configureSession(config);

      _sequentialDownload = settings.sequentialDownload;
      _shareRatioLimit = settings.shareRatioLimit;
      _maxSeedingTimeMinutes = settings.maxSeedingTimeMinutes;
    } catch (e) {
      _log.warning('Session configuration failed: $e');
    }
  }

  static Completer<void>? _trackingCompleter;

  static void _startTrackingUpdates() {
    if (_state == TorrentSessionState.disposed || !isInitialized) return;
    if (_updatesSub != null) return;
    if (_trackingCompleter != null) return; // already in progress
    _trackingCompleter = Completer<void>();
    StreamController<Map<int, TorrentUpdateInfo>>? controller;
    StreamSubscription? sub;
    try {
      controller = StreamController<Map<int, TorrentUpdateInfo>>.broadcast();
      sub = LibtorrentFlutter.instance.torrentUpdates.listen(
        (torrents) {
          try {
            _activeTorrentIds = Set<int>.from(torrents.keys);
            final mapped = torrents.map((key, value) {
              _latestProgress[value.id] = value.progress;
              return MapEntry(
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
                  piecesHave: (value.progress * 1000).round(),
                  piecesTotal: 1000,
                  downloadPayloadRate: value.downloadRate,
                  uploadPayloadRate: value.uploadRate,
                  totalPayloadDownload: value.totalDone,
                  totalPayloadUpload: 0,
                  currentTracker: '',
                  nextAnnounceSeconds: 0,
                  distributedCopies: 0.0,
                  fileProgress: const [],
                  filePriorities: const [],
                ),
              );
            });
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

      if (_state == TorrentSessionState.disposed) {
        sub.cancel();
        controller.close();
        _trackingCompleter?.complete();
        _trackingCompleter = null;
        return;
      }
      _updateController = controller;
      _updatesSub = sub;
      _trackingCompleter?.complete();
      _trackingCompleter = null;
    } catch (e) {
      _log.warning('Failed to start torrent tracking: $e');
      sub?.cancel();
      controller?.close();
      if (_trackingCompleter != null && !_trackingCompleter!.isCompleted) {
        _trackingCompleter!.completeError(e);
      }
      _trackingCompleter = null;
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

  static void setUploadLimit(int bps) {
    if (!isInitialized) return;
    try {
      LibtorrentFlutter.instance.setUploadLimit(bps);
    } catch (e) {
      _log.warning('setUploadLimit failed: $e');
    }
  }

  static Future<void> dispose() async {
    if (_state != TorrentSessionState.ready) return;
    _state = TorrentSessionState.pausing;

    _state = TorrentSessionState.disposing;
    await _updatesSub?.cancel();
    _updatesSub = null;
    await _updateController?.close();
    _updateController = null;
    _activeTorrentIds.clear();

    try {
      await LibtorrentFlutter.instance.dispose();
    } catch (e) {
      _log.warning('Error disposing libtorrent: $e');
    }
    _state = TorrentSessionState.disposed;
  }

  static int addMagnet(String magnetUri, String savePath) {
    if (!isInitialized) return -1;
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
    if (!isInitialized) return -1;
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
    if (!isInitialized) return;
    if (id >= 0) {
      try {
        LibtorrentFlutter.instance.removeTorrent(id, deleteFiles: deleteFiles);
        TorrentResumeStore.delete(id);
        _latestProgress.remove(id);
        _activeTorrentIds.remove(id);
      } catch (e) {
        _log.warning('removeTorrent failed for id $id: $e');
      }
    }
  }

  static void pauseTorrent(int id) {
    if (!isInitialized) return;
    if (id >= 0) {
      try {
        final progress = _latestProgress[id] ?? 0.0;
        TorrentResumeStore.save(id, progress: progress);
        LibtorrentFlutter.instance.pauseTorrent(id);
      } catch (e) {
        _log.warning('pauseTorrent failed for id $id: $e');
      }
    }
  }

  static void resumeTorrent(int id) {
    if (!isInitialized) return;
    if (id >= 0) {
      try {
        LibtorrentFlutter.instance.resumeTorrent(id);
      } catch (e) {
        _log.warning('resumeTorrent failed for id $id: $e');
      }
    }
  }

  static void recheckTorrent(int id) {
    if (!isInitialized) return;
    if (id >= 0) {
      LibtorrentFlutter.instance.tryForceRecheck(id);
    }
  }

  static void setFilePriorities(int id, List<int> priorities) {
    if (!isInitialized) return;
    if (id >= 0) {
      try {
        LibtorrentFlutter.instance.setFilePriorities(id, priorities);
      } catch (e) {
        _log.warning('setFilePriorities failed for id $id: $e');
      }
    }
  }

  static int getFileCount(int id) {
    if (!isInitialized || id < 0) return 0;
    try {
      return LibtorrentFlutter.instance.getFiles(id).length;
    } catch (e) {
      _log.warning('getFileCount failed for id $id: $e');
      return 0;
    }
  }

  static List<TorrentFileItem> getFiles(int id) {
    if (!isInitialized) return [];
    if (id >= 0) {
      try {
        final files = LibtorrentFlutter.instance.getFiles(id);
        final progress = fileProgressSupported
            ? LibtorrentFlutter.instance.tryGetFileProgress(id)
            : null;

        final priorities = filePrioritiesSupported
            ? LibtorrentFlutter.instance.tryGetFilePriorities(id)
            : null;

        return List.generate(files.length, (i) {
          final f = files[i];
          return TorrentFileItem(
            index: f.index,
            name: f.name,
            size: f.size,
            downloadedBytes: (progress != null && i < progress.length)
                ? (progress[i] as num).toInt().clamp(0, f.size)
                : 0,
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
    if (!isInitialized) return const Stream.empty();
    _startTrackingUpdates();
    final existing = _updateController;
    if (existing != null) return existing.stream;

    late StreamController<Map<int, TorrentUpdateInfo>> bridging;
    Timer? poller;
    StreamSubscription? innerSub;
    bridging = StreamController<Map<int, TorrentUpdateInfo>>(
      onListen: () {
        poller = Timer.periodic(const Duration(milliseconds: 200), (_) {
          if (_state == TorrentSessionState.disposed ||
              _state == TorrentSessionState.uninitialized) {
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

  static void configureSession(SettingsProvider settings) {
    _configureSessionFromSettings();
  }
}
