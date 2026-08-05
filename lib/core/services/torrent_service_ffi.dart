import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueNotifier, listEquals;
import 'package:libtorrent_flutter/libtorrent_flutter.dart' hide formatBytes;
import 'package:logging/logging.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'torrent_models.dart';
import 'torrent_resume_store.dart';

final _log = Logger('TorrentService');

/// Isolated capability gate for optional/dynamic libtorrent_flutter methods.
/// All `as dynamic` calls in FFI MUST be contained strictly within this gate.
class _CapabilityGate {
  _CapabilityGate._();
  static final _CapabilityGate instance = _CapabilityGate._();

  bool fileProgressSupported = true;
  bool filePrioritiesSupported = true;
  bool resumeDataSupported = true;
  bool forceRecheckSupported = true;
  bool trackersSupported = true;
  bool createTorrentSupported = true;
  bool ipFilterSupported = true;
  bool sequentialDownloadSupported = true;

  /// Probes capabilities ONCE during initialization.
  void probeCapabilities() {
    fileProgressSupported = true;
    filePrioritiesSupported = true;
    resumeDataSupported = true;
    forceRecheckSupported = true;
    trackersSupported = true;
    createTorrentSupported = true;
    ipFilterSupported = true;
    sequentialDownloadSupported = true;

    final target = LibtorrentFlutter.instance;

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).getFileProgress(-1);
    } on NoSuchMethodError {
      fileProgressSupported = false;
    } catch (_) {}

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).getFilePriorities(-1);
    } on NoSuchMethodError {
      filePrioritiesSupported = false;
    } catch (_) {}

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).saveResumeData(-1);
    } on NoSuchMethodError {
      resumeDataSupported = false;
    } catch (_) {}

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).forceReCheck(-1);
    } on NoSuchMethodError {
      forceRecheckSupported = false;
    } catch (_) {}

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).getTrackers(-1);
    } on NoSuchMethodError {
      trackersSupported = false;
    } catch (_) {}

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).createTorrent(
        sourcePath: '',
        outputPath: '',
        trackers: <String>[],
      );
    } on NoSuchMethodError {
      createTorrentSupported = false;
    } catch (_) {}

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).loadIpFilter('');
    } on NoSuchMethodError {
      ipFilterSupported = false;
    } catch (_) {}

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).setSequentialDownload(-1, false);
    } on NoSuchMethodError {
      sequentialDownloadSupported = false;
    } catch (_) {}

    _log.fine(
      'Capability probe complete: fileProgress=$fileProgressSupported, '
      'filePriorities=$filePrioritiesSupported, resumeData=$resumeDataSupported, '
      'forceRecheck=$forceRecheckSupported, trackers=$trackersSupported, '
      'createTorrent=$createTorrentSupported, ipFilter=$ipFilterSupported, '
      'sequentialDownload=$sequentialDownloadSupported',
    );
  }

  List<dynamic>? fileProgress(int id) {
    if (!fileProgressSupported) return null;
    try {
      // ignore: avoid_dynamic_calls
      return (LibtorrentFlutter.instance as dynamic).getFileProgress(id)
          as List<dynamic>?;
    } catch (_) {
      return null;
    }
  }

  List<dynamic>? filePriorities(int id) {
    if (!filePrioritiesSupported) return null;
    try {
      // ignore: avoid_dynamic_calls
      return (LibtorrentFlutter.instance as dynamic).getFilePriorities(id)
          as List<dynamic>?;
    } catch (_) {
      return null;
    }
  }

  void setFilePriorities(int id, List<int> priorities) {
    if (!filePrioritiesSupported) return;
    try {
      LibtorrentFlutter.instance.setFilePriorities(id, priorities);
    } catch (e) {
      _log.warning('setFilePriorities failed for id $id: $e');
    }
  }

  void forceRecheck(int id) {
    if (!forceRecheckSupported) return;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).forceReCheck(id);
    } catch (_) {}
  }

  Uint8List? saveResumeData(int id) {
    if (!resumeDataSupported) return null;
    try {
      // ignore: avoid_dynamic_calls
      return (LibtorrentFlutter.instance as dynamic).saveResumeData(id)
          as Uint8List?;
    } catch (_) {
      return null;
    }
  }

  bool loadResumeData(int id, Uint8List data) {
    if (!resumeDataSupported) return false;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).loadResumeData(id, data);
      return true;
    } catch (_) {
      return false;
    }
  }

  List<TrackerInfo>? trackers(int id) {
    if (!trackersSupported) return null;
    try {
      // ignore: avoid_dynamic_calls
      final raw = (LibtorrentFlutter.instance as dynamic).getTrackers(id)
          as List<dynamic>?;
      if (raw == null) return null;
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
    } catch (_) {
      return null;
    }
  }

  bool addTracker(int id, String trackerUrl, {int tier = 0}) {
    if (!trackersSupported) return false;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).addTracker(id, trackerUrl, tier);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool removeTracker(int id, String trackerUrl) {
    if (!trackersSupported) return false;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).removeTracker(id, trackerUrl);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool announceNow(int id) {
    if (!trackersSupported) return false;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).announceNow(id);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) async {
    if (!createTorrentSupported) return null;
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

  Future<bool> loadIpFilter(String path) async {
    if (!ipFilterSupported) return false;
    try {
      // ignore: avoid_dynamic_calls
      await (LibtorrentFlutter.instance as dynamic).loadIpFilter(path);
      return true;
    } catch (e) {
      _log.warning('loadIpFilter failed: $e');
      return false;
    }
  }

  void setSequentialDownload(int id, bool enabled) {
    if (!sequentialDownloadSupported) return;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).setSequentialDownload(id, enabled);
    } catch (e) {
      _log.warning('setSequentialDownload failed for id $id: $e');
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
  static TorrentSessionState _state = TorrentSessionState.uninitialized;
  static Completer<void>? _initCompleter;
  static Completer<void>? _disposeCompleter;
  static Set<int> _activeTorrentIds = {};
  static StreamSubscription? _updatesSub;
  static StreamController<Map<int, TorrentUpdateInfo>>? _updateController;

  static bool get fileProgressSupported =>
      _CapabilityGate.instance.fileProgressSupported;

  static bool get filePrioritiesSupported =>
      _CapabilityGate.instance.filePrioritiesSupported;

  static final Map<int, double> _latestProgress = {};
  static final Map<int, String> _torrentSources = {};
  static final Map<int, List<int>> _cachedPrioritiesSnapshot = {};

  static final ValueNotifier<bool> isAvailable = ValueNotifier(false);

  static bool get isSupported => true;
  static bool get isInitialized => _state == TorrentSessionState.ready;
  static Set<int> get activeTorrentIds => Set.unmodifiable(_activeTorrentIds);

  /// Future getter that callers can await to ensure TorrentService is ready.
  static Future<void> get ready {
    if (_state == TorrentSessionState.ready) return Future.value();
    if (_state == TorrentSessionState.initializing && _initCompleter != null) {
      return _initCompleter!.future;
    }
    if (_state == TorrentSessionState.uninitialized) {
      return init();
    }
    return Future.error(StateError('TorrentService is in state $_state'));
  }

  /// Checks if fast-resume binary data exists for [source].
  static Future<bool> hasResumeData(String source) async {
    await _readyOrThrow();
    final bytes = await TorrentResumeStore.loadResumeDataForSource(source);
    return bytes != null && bytes.isNotEmpty;
  }

  /// Returns the latest known progress for a torrent, or 0.0 if unknown.
  static double progressFor(int id) => _latestProgress[id] ?? 0.0;

  static Future<void> _readyOrThrow() async {
    if (_state == TorrentSessionState.ready) return;
    await ready;
  }

  static Future<void> init() async {
    if (_state == TorrentSessionState.ready) return;
    if (_state == TorrentSessionState.initializing && _initCompleter != null) {
      return _initCompleter!.future;
    }
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
      try {
        await LibtorrentFlutter.init();
        _CapabilityGate.instance.probeCapabilities();
        _configureSessionFromSettings();
        _startTrackingUpdates();
        _state = TorrentSessionState.ready;
        isAvailable.value = true;
      } catch (nativeErr) {
        _log.warning(
          'Native libtorrent init failed (unsupported platform or native library missing): $nativeErr',
        );
        _state = TorrentSessionState.uninitialized;
        isAvailable.value = false;
      }
      _initCompleter?.complete();
    } catch (e) {
      _state = TorrentSessionState.uninitialized;
      isAvailable.value = false;
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

  static void configureSession([SettingsProvider? settings]) {
    try {
      final s = settings ?? SettingsProvider.instance;
      final config = LibtorrentFlutter.instance.getDefaultConfig().copyWith(
            disableDht: !s.enableDht,
            disableUpnp: !s.enableUpnp,
            forceEncrypt: s.forceEncrypt,
            connectionsLimit: s.torrentConnectionsLimit,
            downloadRateLimit: s.effectiveSpeedLimitBytesPerSecond ~/ 1024,
            uploadRateLimit: s.globalTorrentSeedingLimited
                ? s.globalTorrentSeedingLimitKbps
                : 0,
          );
      LibtorrentFlutter.instance.configureSession(config);

      _sequentialDownload = s.sequentialDownload;
      _shareRatioLimit = s.shareRatioLimit;
      _maxSeedingTimeMinutes = s.maxSeedingTimeMinutes;

      for (final id in _activeTorrentIds) {
        _CapabilityGate.instance.setSequentialDownload(id, _sequentialDownload);
      }
    } catch (e) {
      _log.warning('Session configuration failed: $e');
    }
  }

  static void _configureSessionFromSettings() => configureSession();

  static Completer<void>? _trackingCompleter;

  static void _startTrackingUpdates() {
    if (_state == TorrentSessionState.disposed || !isInitialized) return;
    if (_updatesSub != null) return;
    if (_trackingCompleter != null) return;
    _trackingCompleter = Completer<void>();
    StreamController<Map<int, TorrentUpdateInfo>>? controller;
    StreamSubscription? sub;
    try {
      controller = StreamController<Map<int, TorrentUpdateInfo>>.broadcast();
      sub = LibtorrentFlutter.instance.torrentUpdates.listen(
        (torrents) {
          try {
            final nativeIds = Set<int>.from(torrents.keys);
            _activeTorrentIds = _activeTorrentIds.union(nativeIds);
            final previousIds = Set<int>.from(_latestProgress.keys);
            _activeTorrentIds.retainWhere(
              (id) =>
                  nativeIds.contains(id) || !_latestProgress.containsKey(id),
            );
            final removedIds = previousIds.difference(_activeTorrentIds);
            for (final removedId in removedIds) {
              _latestProgress.remove(removedId);
              _torrentSources.remove(removedId);
              _cachedPrioritiesSnapshot.remove(removedId);
            }
            final mapped = torrents.map((key, value) {
              _latestProgress[value.id] = value.progress;
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
                  piecesHave: (safeProgress * 1000).round(),
                  piecesTotal: 1000,
                  downloadPayloadRate: value.downloadRate,
                  uploadPayloadRate: value.uploadRate,
                  totalPayloadDownload: value.totalDone,
                  totalPayloadUpload: value.totalUploaded,
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
  static Future<void> saveResumeData(int torrentId) async {
    if (_state == TorrentSessionState.uninitialized ||
        _state == TorrentSessionState.initializing) {
      return;
    }
    try {
      final data = _CapabilityGate.instance.saveResumeData(torrentId);
      if (data != null) {
        final source = _torrentSources[torrentId];
        if (source != null) {
          await TorrentResumeStore.saveResumeDataForSource(source, data);
        }
        await TorrentResumeStore.saveResumeData(torrentId, data);
      }
    } catch (e) {
      _log.warning('saveResumeData failed for torrentId $torrentId: $e');
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

  static Future<void> dispose() async {
    if (_state == TorrentSessionState.disposed ||
        _state == TorrentSessionState.uninitialized) {
      return;
    }

    if (_state == TorrentSessionState.initializing && _initCompleter != null) {
      try {
        await _initCompleter!.future;
      } catch (e, st) {
        _log.warning('[torrent_service_ffi] operation failed', e, st);
      }
    }

    if (_disposeCompleter != null) return _disposeCompleter!.future;

    _disposeCompleter = Completer<void>();
    _state = TorrentSessionState.pausing;

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
    _cachedPrioritiesSnapshot.clear();

    try {
      await LibtorrentFlutter.instance.dispose();
    } catch (e) {
      _log.warning('Error disposing libtorrent: $e');
    }
    _state = TorrentSessionState.disposed;
    isAvailable.value = false;
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
        unawaited(_tryLoadFastResumeForSource(id, magnetUri)); // FIX-02: kept async
      }
      return id;
    } catch (e) {
      _log.warning('addMagnet failed: $e');
      return -1;
    }
  }

  /// Adds a magnet link and waits up to [timeout] for metadata, emitting periodic status messages.
  static Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
  }) async {
    final id = addMagnet(magnetUri, savePath);
    if (id < 0) return -1;

    final stopwatch = Stopwatch()..start();
    final completer = Completer<int>();
    Timer? messageTimer;
    StreamSubscription? sub;

    messageTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final elapsedSec = stopwatch.elapsed.inSeconds;
      final msg = 'Fetching metadata… ${elapsedSec}s';
      onStatusUpdate?.call(msg);
      _log.fine('Magnet $id: $msg');
    });

    sub = torrentUpdates.listen((updateMap) {
      final info = updateMap[id];
      if (info != null && info.hasMetadata) {
        messageTimer?.cancel();
        sub?.cancel();
        stopwatch.stop();
        if (!completer.isCompleted) completer.complete(id);
      }
    });

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      messageTimer.cancel();
      sub.cancel();
      stopwatch.stop();
      _log.warning(
        'Magnet metadata fetch timed out after ${timeout.inSeconds}s for $magnetUri',
      );
      removeTorrent(id, deleteFiles: true);
      throw TimeoutException('Magnet metadata fetch timed out', timeout);
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
      final source = sourceKey ?? filePath;
      final id = LibtorrentFlutter.instance.addTorrentFile(filePath, savePath);
      if (id >= 0) {
        _activeTorrentIds.add(id);
        _torrentSources[id] = source;
        unawaited(_tryLoadFastResumeForSource(id, source)); // FIX-02: kept async
      }
      return id;
    } catch (e) {
      _log.warning('addTorrentFile failed: $e');
      return -1;
    }
  }

  static Future<void> _tryLoadFastResumeForSource(
    int id,
    String source,
  ) async {
    try {
      final resumeBytes =
          await TorrentResumeStore.loadResumeDataForSource(source);
      if (resumeBytes != null && resumeBytes.isNotEmpty) {
        final loaded =
            _CapabilityGate.instance.loadResumeData(id, resumeBytes);
        if (loaded) {
          _log.fine(
            'Fast-resume data loaded successfully for torrent $id ($source)',
          );
        }
      }
    } catch (e) {
      _log.warning('Failed to load fast-resume for $id: $e');
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
        _cachedPrioritiesSnapshot.remove(id);
      } catch (e) {
        _log.warning('removeTorrent failed for id $id: $e');
      }
    }
  }

  static Future<void> pauseTorrent(int id) async {
    if (!isInitialized) return;
    if (id >= 0) {
      try {
        final progress = _latestProgress[id] ?? 0.0;

        // Snapshot torrent file priorities/selections BEFORE pausing so they
        // survive a forced kill. getFiles() calls the native session which is
        // still running at this point.
        List<Map<String, dynamic>>? torrentFiles;
        try {
          final items = getFiles(id);
          if (items.isNotEmpty) {
            torrentFiles = items
                .map((f) => {
                      'name': f.name,
                      'size': f.size,
                      'priority': f.priority,
                      'selected': f.selected,
                      'downloadedBytes': f.downloadedBytes,
                    })
                .toList();
          }
        } catch (e) {
          _log.warning('getFiles snapshot failed for id $id (non-fatal): $e');
        }

        // Persist JSON progress + file priorities atomically.
        await TorrentResumeStore.save(
          id,
          progress: progress,
          torrentFiles: torrentFiles,
        );

        // Persist native fast-resume bytes under BOTH the stable source key
        // and the numeric-id path. Best-effort: never throw out of pauseTorrent.
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

  static bool loadResumeData(int id, List<int> data) {
    if (!isInitialized || id < 0) return false;
    return _CapabilityGate.instance
        .loadResumeData(id, Uint8List.fromList(data));
  }

  static bool isTorrentAlive(int id) {
    if (!isInitialized || id < 0) return false;
    return _activeTorrentIds.contains(id);
  }

  static void recheckTorrent(int id) {
    if (!isInitialized) return;
    if (id >= 0) {
      _CapabilityGate.instance.forceRecheck(id);
    }
  }

  static void setFilePriorities(int id, List<int> priorities) {
    if (!isInitialized || id < 0) return;
    final fileCount = getFileCount(id);
    if (fileCount > 0 && priorities.length != fileCount) {
      _log.warning(
        'setFilePriorities length mismatch for torrent $id: expected $fileCount but got ${priorities.length}. Skipping.',
      );
      return;
    }

    // Check cached snapshot diff to avoid redundant priority calls
    final cached = _cachedPrioritiesSnapshot[id];
    if (cached != null && listEquals(cached, priorities)) {
      return;
    }

    _cachedPrioritiesSnapshot[id] = List.unmodifiable(priorities);
    _CapabilityGate.instance.setFilePriorities(id, priorities);
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
        final progress = _CapabilityGate.instance.fileProgressSupported
            ? _CapabilityGate.instance.fileProgress(id)
            : null;

        final priorities = _CapabilityGate.instance.filePrioritiesSupported
            ? _CapabilityGate.instance.filePriorities(id)
            : null;

        return List.generate(files.length, (i) {
          final f = files[i];
          int resolvedDownloadedBytes;

          if (progress != null && i < progress.length) {
            final rawBytes = (progress[i] as num?)?.toInt() ?? -1;
            if (rawBytes >= 0) {
              resolvedDownloadedBytes = rawBytes.clamp(0, f.size);
            } else {
              // ── FIX-5: -1 means libtorrent has no data yet ──
              resolvedDownloadedBytes = 0;
            }
          } else {
            resolvedDownloadedBytes = 0;
          }

          return TorrentFileItem(
            index: f.index,
            name: f.name,
            size: f.size,
            downloadedBytes: resolvedDownloadedBytes,
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

  // ---------------------------------------------------------------------------
  // Trackers, Torrent Creation & IP Filtering
  // ---------------------------------------------------------------------------
  static List<TrackerInfo> getTrackers(int torrentId) {
    if (!isInitialized || torrentId < 0) return [];
    return _CapabilityGate.instance.trackers(torrentId) ?? [];
  }

  static void addTracker(int torrentId, String trackerUrl, {int tier = 0}) {
    if (!isInitialized || torrentId < 0) return;
    final lower = trackerUrl.trim().toLowerCase();
    if (!lower.startsWith('http://') &&
        !lower.startsWith('https://') &&
        !lower.startsWith('udp://')) {
      _log.warning(
        'addTracker skipped: invalid scheme for "$trackerUrl" (must be http, https, or udp)',
      );
      return;
    }
    _CapabilityGate.instance.addTracker(torrentId, trackerUrl, tier: tier);
  }

  static void removeTracker(int torrentId, String trackerUrl) {
    if (!isInitialized || torrentId < 0) return;
    _CapabilityGate.instance.removeTracker(torrentId, trackerUrl);
  }

  static void announceNow(int torrentId) {
    if (!isInitialized || torrentId < 0) return;
    _CapabilityGate.instance.announceNow(torrentId);
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
    return _CapabilityGate.instance.createTorrent(
      sourcePath: sourcePath,
      outputPath: outputPath,
      trackers: trackers,
      comment: comment,
      pieceSize: pieceSize,
      isPrivate: isPrivate,
    );
  }

  static Future<bool> loadIpFilter(String filePath) async {
    if (!isInitialized) return false;
    return _CapabilityGate.instance.loadIpFilter(filePath);
  }

  /// Pure function evaluator for seeding policy auto-stop.
  static bool shouldStopSeeding({
    required double progress,
    required int uploadedBytes,
    required int downloadedBytes,
    required double shareRatioLimit,
    required int maxSeedingMinutes,
    DateTime? completedAt,
  }) {
    if (progress < 1.0 && downloadedBytes <= 0) return false;
    if (shareRatioLimit > 0) {
      final effectiveDownloaded = downloadedBytes > 0 ? downloadedBytes : 1;
      final ratio = uploadedBytes / effectiveDownloaded;
      if (ratio >= shareRatioLimit) return true;
    }
    if (maxSeedingMinutes > 0 && completedAt != null) {
      final minutesSeeding = DateTime.now().difference(completedAt).inMinutes;
      if (minutesSeeding >= maxSeedingMinutes) return true;
    }
    return false;
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
