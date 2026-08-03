import 'dart:async';
import 'dart:typed_data';
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
      // FIX(1): Plugin build lacks per-file progress. Record it so callers fall back
      // to priority-based estimation instead of silently reporting 0 B.
      TorrentService.fileProgressSupported = false;
      return null;
    }
  }

  List<dynamic>? tryGetFilePriorities(int id) {
    try {
      // ignore: avoid_dynamic_calls
      return (this as dynamic).getFilePriorities(id) as List<dynamic>?;
    } on NoSuchMethodError {
      // FIX(1): Plugin build lacks per-file priorities. Record it.
      TorrentService.filePrioritiesSupported = false;
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

  /// Guarded call to saveResumeData.
  /// Returns a Uint8List if the plugin supports it, or null if not.
  ///
  /// Migration note: once libtorrent_flutter exposes saveResumeData natively,
  /// the dynamic dispatch can be replaced with the typed API directly. The
  /// native API should return fast-resume data as a serialized Uint8List that
  /// can be persisted and passed back to loadResumeData on restart, avoiding
  /// the full piece recheck.
  Uint8List? trySaveResumeData(int id) {
    try {
      // ignore: avoid_dynamic_calls
      return (this as dynamic).saveResumeData(id) as Uint8List?;
    } on NoSuchMethodError {
      // Plugin does not support saveResumeData — marker-only fallback.
      return null;
    }
  }

  /// Guarded call to loadResumeData.
  /// Returns true if the plugin accepted the resume data.
  ///
  /// Migration note: once libtorrent_flutter exposes loadResumeData natively,
  /// the dynamic dispatch can be removed. The native implementation should
  /// accept a torrent ID and a Uint8List of previously saved fast-resume data.
  // ignore: unused_element
  bool tryLoadResumeData(int id, Uint8List data) {
    try {
      // ignore: avoid_dynamic_calls
      (this as dynamic).loadResumeData(id, data);
      return true;
    } on NoSuchMethodError {
      return false;
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
  static Completer<void>? _initCompleter;
  static Completer<void>? _disposeCompleter;
  static Set<int> _activeTorrentIds = {};
  static StreamSubscription? _updatesSub;
  static StreamController<Map<int, TorrentUpdateInfo>>? _updateController;
  static bool fileProgressSupported = true;
  static bool filePrioritiesSupported = true;
  static final Map<int, double> _latestProgress = {};
  static final Map<int, String> _torrentSources = {};

  static bool get isSupported => true;
  static bool get isInitialized => _state == TorrentSessionState.ready;
  static Set<int> get activeTorrentIds => Set.unmodifiable(_activeTorrentIds);

  /// Returns the latest known progress for a torrent, or 0.0 if unknown.
  static double progressFor(int id) => _latestProgress[id] ?? 0.0;

  static Future<void> init() async {
    if (_state == TorrentSessionState.ready) return;
    if (_state == TorrentSessionState.initializing && _initCompleter != null) {
      return _initCompleter!.future;
    }
    // FIX(5): Wait for any in-progress dispose before re-initializing
    if (_state == TorrentSessionState.pausing ||
        _state == TorrentSessionState.disposing) {
      if (_disposeCompleter != null) {
        try {
          await _disposeCompleter!.future;
        } catch (e, st) {
          _log.warning('[torrent_service_ffi] operation failed', e, st);
        }
      }
    }

    _state = TorrentSessionState.initializing;
    _initCompleter = Completer<void>();
    try {
      await TorrentResumeStore.init();
      await LibtorrentFlutter.init();
      fileProgressSupported = true;
      filePrioritiesSupported = true;
      _configureSessionFromSettings();
      _startTrackingUpdates();
      _state = TorrentSessionState.ready;
      _initCompleter?.complete();
    } catch (e) {
      _state = TorrentSessionState.uninitialized;
      _initCompleter?.completeError(e);
      rethrow;
    } finally {
      _initCompleter = null;
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
            // FIX(3): Merge native IDs with Dart-side additions instead of
            // replacing the entire set, which would wipe IDs just added by
            // addMagnet/addTorrentFile that haven't appeared in native updates.
            final nativeIds = Set<int>.from(torrents.keys);
            _activeTorrentIds = _activeTorrentIds.union(nativeIds);
            // Remove IDs that libtorrent no longer knows about, but keep
            // freshly-added IDs that haven't been reported by native yet.
            final previousIds = Set<int>.from(_latestProgress.keys);
            _activeTorrentIds.retainWhere(
              (id) =>
                  nativeIds.contains(id) || !_latestProgress.containsKey(id),
            );
            final removedIds = previousIds.difference(_activeTorrentIds);
            for (final removedId in removedIds) {
              _latestProgress.remove(removedId);
              _torrentSources.remove(removedId);
            }
            final mapped = torrents.map((key, value) {
              _latestProgress[value.id] = value.progress;
              // FIX(6): Clamp NaN/Infinity progress to avoid toInt() crash
              final safeProgress = value.progress.isFinite
                  ? value.progress.clamp(0.0, 1.0)
                  : 0.0;
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
                  totalWantedDone: (safeProgress * value.totalWanted).toInt(),
                  hasMetadata: value.hasMetadata,
                  stateLabel: value.state.label,
                  numSeeds: value.numSeeds,
                  numPeers: value.numPeers,
                  // FIX(8): Use safe progress for piece count estimation
                  piecesHave: (safeProgress * 1000).round(),
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
        // FIX(7): Close orphaned _updateController when stream ends so
        // the next _startTrackingUpdates() creates a fresh one and old
        // listeners aren't stuck on a dead controller.
        onDone: () {
          if (identical(_updatesSub, sub)) {
            _updatesSub = null;
            _updateController?.close();
            _updateController = null;
          }
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

  /// Attempts to save native fast-resume data for [torrentId].
  ///
  /// The native libtorrent_flutter plugin may or may not expose
  /// saveResumeData. When it does, the raw binary data is persisted via
  /// [TorrentResumeStore.saveResumeData] and can be reloaded on the next
  /// session to skip the full piece recheck.
  ///
  /// Migration note: once libtorrent_flutter exposes saveResumeData with a
  /// typed API, the native code should return serialized add_torrent_params /
  /// fast-resume data that libtorrent can consume via loadResumeData. The
  /// method signature needed is:
  ///   Uint8List saveResumeData(int torrentId);
  ///   void loadResumeData(int torrentId, Uint8List data);
  static Future<void> saveResumeData(int torrentId) async {
    if (_state == TorrentSessionState.uninitialized ||
        _state == TorrentSessionState.initializing) {
      return;
    }
    try {
      final data = LibtorrentFlutter.instance.trySaveResumeData(torrentId);
      if (data != null) {
        final source = _torrentSources[torrentId];
        if (source != null) {
          await TorrentResumeStore.saveResumeDataForSource(source, data);
        }
        // Keep the ID-keyed file for backward compatibility with existing installs.
        await TorrentResumeStore.saveResumeData(torrentId, data);
      }
    } catch (e) {
      _log.warning('trySaveResumeData failed for torrentId $torrentId: $e');
    }
  }

  /// Saves native resume data for all active torrents.
  static Future<void> saveAllResumeData() async {
    final activeIds = Set<int>.from(_activeTorrentIds);
    for (final id in activeIds) {
      try {
        await saveResumeData(id);
      } catch (e) {
        _log.warning('saveResumeData failed during batch save for $id: $e');
      }
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

  // FIX(2): Robust dispose that handles all states and prevents segfaults
  // by ensuring all FFI calls complete before native teardown.
  static Future<void> dispose() async {
    if (_state == TorrentSessionState.disposed ||
        _state == TorrentSessionState.uninitialized) {
      return;
    }

    // If currently initializing, wait for it to complete first
    if (_state == TorrentSessionState.initializing && _initCompleter != null) {
      try {
        await _initCompleter!.future;
      } catch (e, st) {
        _log.warning('[torrent_service_ffi] operation failed', e, st);
      }
    }

    // If already disposing, wait for the existing dispose to finish
    if (_disposeCompleter != null) return _disposeCompleter!.future;

    _disposeCompleter = Completer<void>();
    _state = TorrentSessionState.pausing;

    // Save native resume data for all active torrents before shutdown
    try {
      await saveAllResumeData();
      await TorrentResumeStore.saveAll(
        _activeTorrentIds,
        (id) => _latestProgress[id] ?? 0.0,
      );
    } catch (e) {
      _log.warning('Error saving resume data during dispose: $e');
    }

    _state = TorrentSessionState.disposing;
    await _updatesSub?.cancel();
    _updatesSub = null;
    await _updateController?.close();
    _updateController = null;
    _activeTorrentIds.clear();
    _torrentSources.clear();
    _latestProgress.clear();

    try {
      await LibtorrentFlutter.instance.dispose();
    } catch (e) {
      _log.warning('Error disposing libtorrent: $e');
    }
    _state = TorrentSessionState.disposed;
    _disposeCompleter?.complete();
    _disposeCompleter = null;
  }

  static int addMagnet(String magnetUri, String savePath) {
    if (!isInitialized) return -1;
    _startTrackingUpdates();
    try {
      final id = LibtorrentFlutter.instance.addMagnet(magnetUri, savePath);
      if (id >= 0) {
        _activeTorrentIds.add(id);
        _torrentSources[id] = magnetUri;
      }
      return id;
    } catch (e) {
      _log.warning('addMagnet failed: $e');
      return -1;
    }
  }

  static int addTorrentFile(
    String filePath,
    String savePath, {
    String? sourceKey,
  }) {
    if (!isInitialized) return -1;
    _startTrackingUpdates();
    try {
      final id = LibtorrentFlutter.instance.addTorrentFile(filePath, savePath);
      if (id >= 0) {
        _activeTorrentIds.add(id);
        _torrentSources[id] = sourceKey ?? filePath;
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
        unawaited(TorrentResumeStore.delete(id));
        final source = _torrentSources.remove(id);
        if (source != null) {
          unawaited(TorrentResumeStore.deleteResumeDataForSource(source));
        }
        _latestProgress.remove(id);
        _activeTorrentIds.remove(id);
      } catch (e) {
        _log.warning('removeTorrent failed for id $id: $e');
      }
    }
  }

  // FIX(4): Await saveResumeData before pausing to prevent FFI race
  // condition where native state is modified while querying fast-resume data.
  static Future<void> pauseTorrent(int id) async {
    if (!isInitialized) return;
    if (id >= 0) {
      try {
        final progress = _latestProgress[id] ?? 0.0;
        await TorrentResumeStore.save(id, progress: progress);
        // Save native fast-resume data before pausing
        try {
          await saveResumeData(id);
        } catch (e) {
          _log.warning('saveResumeData failed for id $id: $e');
        }
        LibtorrentFlutter.instance.pauseTorrent(id);
      } catch (e) {
        _log.warning('pauseTorrent failed for id $id: $e');
      }
    }
  }

  static bool loadResumeData(int id, Uint8List data) {
    if (!isInitialized || id < 0) return false;
    return LibtorrentFlutter.instance.tryLoadResumeData(id, data);
  }

  static bool isTorrentAlive(int id) {
    if (!isInitialized || id < 0) return false;
    return _activeTorrentIds.contains(id);
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
            // FIX(1): Return -1 when native progress is unavailable to signal
            // "unknown" — caller should use estimation fallback instead of 0.
            // FIX(9): Safe null-aware casts for native data that may
            // return null or non-numeric types.
            downloadedBytes: (progress != null && i < progress.length)
                ? ((progress[i] as num?)?.toInt() ?? 0).clamp(0, f.size)
                : -1,
            priority: (priorities != null && i < priorities.length)
                ? ((priorities[i] as num?)?.toInt() ?? 4)
                : 4,
            selected: (priorities != null && i < priorities.length)
                ? ((priorities[i] as num?)?.toInt() ?? 1) > 0
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
            // FIX(1): Cancel the periodic timer to prevent infinite CPU leak
            poller?.cancel();
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

  // ---------------------------------------------------------------------------
  // Trackers, Torrent Creation & IP Filtering
  // ---------------------------------------------------------------------------
  static List<TrackerInfo> getTrackers(int torrentId) {
    if (!isInitialized || torrentId < 0) return [];
    try {
      // ignore: avoid_dynamic_calls
      final raw = (LibtorrentFlutter.instance as dynamic).getTrackers(torrentId)
          as List<dynamic>?;
      if (raw == null) return [];
      return raw.map((t) {
        final map = t as Map<String, dynamic>;
        return TrackerInfo(
          url: map['url'] as String? ?? '',
          tier: (map['tier'] as num?)?.toInt() ?? 0,
          status: map['status'] as String? ?? 'working',
          seeds: (map['seeds'] as num?)?.toInt() ?? 0,
          peers: (map['peers'] as num?)?.toInt() ?? 0,
          message: map['message'] as String? ?? '',
        );
      }).toList();
    } catch (e, st) {
      _log.warning('[torrent_service_ffi] operation failed', e, st);
      return [];
    }
  }

  static void addTracker(int torrentId, String trackerUrl, {int tier = 0}) {
    if (!isInitialized || torrentId < 0) return;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).addTracker(
        torrentId,
        trackerUrl,
        tier,
      );
    } catch (e) {
      _log.warning('addTracker failed: $e');
    }
  }

  static void removeTracker(int torrentId, String trackerUrl) {
    if (!isInitialized || torrentId < 0) return;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).removeTracker(
        torrentId,
        trackerUrl,
      );
    } catch (e) {
      _log.warning('removeTracker failed: $e');
    }
  }

  static void announceNow(int torrentId) {
    if (!isInitialized || torrentId < 0) return;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).announceNow(torrentId);
    } catch (e) {
      _log.warning('announceNow failed: $e');
    }
  }

  static Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) async {
    if (!isInitialized) return null;
    try {
      // ignore: avoid_dynamic_calls
      final res = await (LibtorrentFlutter.instance as dynamic).createTorrent(
        sourcePath: sourcePath,
        outputPath: outputPath,
        trackers: trackers,
        comment: comment,
        pieceSize: pieceSize,
        isPrivate: isPrivate,
      );
      return res as String?;
    } catch (e) {
      _log.warning('createTorrent failed: $e');
      return null;
    }
  }

  static Future<bool> loadIpFilter(String filePath) async {
    if (!isInitialized) return false;
    try {
      // ignore: avoid_dynamic_calls
      await (LibtorrentFlutter.instance as dynamic).loadIpFilter(filePath);
      return true;
    } catch (e) {
      _log.warning('loadIpFilter failed: $e');
      return false;
    }
  }
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
