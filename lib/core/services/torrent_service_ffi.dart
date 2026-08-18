import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, listEquals;
import 'package:libtorrent_flutter/libtorrent_flutter.dart'
    hide formatBytes, TrackerManager;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../interfaces/i_torrent_service.dart';
import 'download_engine.dart';
import 'power_monitor.dart';
import 'torrent_models.dart';
import 'torrent_resume_store.dart';
import 'tracker_manager.dart';

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
  bool superSeedingSupported = true;
  bool pieceDeadlineSupported = true;

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
    superSeedingSupported = true;
    pieceDeadlineSupported = true;

    final target = LibtorrentFlutter.instance;

    // FIX-H1: Wrap every dynamic call in try-catch and set flag to false on any error
    try {
      (target as dynamic).getFileProgress(-1);
    } catch (e) {
      fileProgressSupported = false;
      _log.fine('probe getFileProgress disabled: $e');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).getFilePriorities(-1);
    } catch (e) {
      filePrioritiesSupported = false;
      _log.fine('probe getFilePriorities disabled: $e');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).saveResumeData(-1);
    } catch (e) {
      resumeDataSupported = false;
      _log.fine('probe saveResumeData disabled: $e');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).forceReCheck(-1);
    } catch (e) {
      forceRecheckSupported = false;
      _log.fine('probe forceReCheck disabled: $e');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).getTrackers(-1);
    } catch (e) {
      trackersSupported = false;
      _log.fine('probe getTrackers disabled: $e');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).createTorrent(
        sourcePath: '',
        outputPath: '',
        trackers: <String>[],
      );
    } catch (e) {
      createTorrentSupported = false;
      _log.fine('probe createTorrent disabled: $e');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).loadIpFilter('');
    } catch (e) {
      ipFilterSupported = false;
      _log.fine('probe loadIpFilter disabled: $e');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).setSequentialDownload(-1, false);
    } catch (e) {
      sequentialDownloadSupported = false;
      _log.fine('probe setSequentialDownload disabled: $e');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).setSuperSeeding(-1, false);
    } catch (e) {
      superSeedingSupported = false;
      _log.fine('probe setSuperSeeding disabled: $e');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).setPieceDeadline(-1, 0, 0);
    } catch (e) {
      pieceDeadlineSupported = false;
      _log.fine('probe setPieceDeadline disabled: $e');
    }

    _log.fine(
      'Capability probe complete: fileProgress=$fileProgressSupported, '
      'filePriorities=$filePrioritiesSupported, resumeData=$resumeDataSupported, '
      'forceRecheck=$forceRecheckSupported, trackers=$trackersSupported, '
      'createTorrent=$createTorrentSupported, ipFilter=$ipFilterSupported, '
      'sequentialDownload=$sequentialDownloadSupported, superSeeding=$superSeedingSupported, '
      'pieceDeadline=$pieceDeadlineSupported',
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
      (LibtorrentFlutter.instance as dynamic)
          .setSequentialDownload(id, enabled);
    } catch (e) {
      _log.warning('setSequentialDownload failed for id $id: $e');
    }
  }

  void setSuperSeeding(int id, bool enabled) {
    if (!superSeedingSupported) return;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).setSuperSeeding(id, enabled);
    } catch (e) {
      _log.warning('setSuperSeeding failed for id $id: $e');
    }
  }

  void setPieceDeadline(int id, int pieceIndex, int deadlineMs) {
    if (!pieceDeadlineSupported) return;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic)
          .setPieceDeadline(id, pieceIndex, deadlineMs);
    } catch (e) {
      _log.warning('setPieceDeadline failed for id $id: $e');
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
  static final Lock _libtorrentLock = Lock();
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

  static bool get resumeDataSupported =>
      _CapabilityGate.instance.resumeDataSupported;

  static Future<void> forceStopTorrent(int id) async => pauseTorrent(id);

  static final Map<int, double> _latestProgress = {};
  static final Map<int, String> _torrentSources = {};
  static final Map<int, List<int>> _cachedPrioritiesSnapshot = {};
  // FIX-22: Latest full update info per torrent, used to poll engine state
  // after pausing so resume data is captured only once truly paused/flushed.
  static final Map<int, TorrentUpdateInfo> _latestStats = {};

  // FIX-H2: Throttling fields
  static DateTime? _lastEmitTime;
  static Map<int, TorrentUpdateInfo>? _pendingUpdate;
  static Timer? _throttleTimer;

  // FIX-H1: Top-level isPluginAvailable flag
  static bool isPluginAvailable = false;
  static final ValueNotifier<bool> isAvailable = ValueNotifier(false);

  static bool get isSupported => true;
  static bool get isInitialized =>
      _state == TorrentSessionState.ready && isPluginAvailable;
  static Set<int> get activeTorrentIds => Set.unmodifiable(_activeTorrentIds);
  static Map<int, TorrentUpdateInfo> get latestStats =>
      Map.unmodifiable(_latestStats);

  /// Future getter that callers can await to ensure TorrentService is ready.
  static Future<void> get ready {
    if (_state == TorrentSessionState.ready && isPluginAvailable) {
      return Future.value();
    }
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
    if (!isPluginAvailable) return false;
    await _readyOrThrow();
    final bytes = await TorrentResumeStore.loadResumeDataForSource(source);
    return bytes != null && bytes.isNotEmpty;
  }

  /// Returns the latest known progress for a torrent, or 0.0 if unknown.
  static double progressFor(int id) => _latestProgress[id] ?? 0.0;

  /// Returns the native fast-resume blob for [id], or null when unavailable.
  static Uint8List? resumeBlobFor(int id) {
    if (!isPluginAvailable ||
        _state == TorrentSessionState.uninitialized ||
        _state == TorrentSessionState.initializing) {
      return null;
    }
    try {
      return _CapabilityGate.instance.saveResumeData(id);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _readyOrThrow() async {
    if (_state == TorrentSessionState.ready && isPluginAvailable) return;
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
      try {
        await LibtorrentFlutter.init().timeout(const Duration(seconds: 10));
        isPluginAvailable = true;
        _CapabilityGate.instance.probeCapabilities();
        _configureSessionFromSettings();
        _startTrackingUpdates();
        _state = TorrentSessionState.ready;
        isAvailable.value = true;
      } on TimeoutException {
        _log.severe('libtorrent init timed out');
        _state = TorrentSessionState.uninitialized;
        isPluginAvailable = false;
        isAvailable.value = false;
        return;
      } catch (nativeErr) {
        _log.warning(
          'Native libtorrent init failed (unsupported platform or native library missing): $nativeErr',
        );
        _state = TorrentSessionState.uninitialized;
        isPluginAvailable = false;
        isAvailable.value = false;
      }
      _initCompleter?.complete();
    } catch (e) {
      _state = TorrentSessionState.uninitialized;
      isPluginAvailable = false;
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

  static const List<String> _dhtBootstrapNodes = [
    'router.bittorrent.com:6881',
    'dht.transmissionbt.com:6881',
    'router.utorrent.com:6881',
    'dht.aelitis.com:6881',
    'router.silotis.us:6881',
    'dht.libtorrent.org:25401',
  ];

  static void _injectDhtNodes() {
    try {
      final s = SettingsProvider.instance;
      if (!s.enableDht) return;
      for (final node in _dhtBootstrapNodes) {
        final parts = node.split(':');
        // ignore: avoid_dynamic_calls
        (LibtorrentFlutter.instance as dynamic)
            .addDhtNode(parts[0], int.parse(parts[1]));
      }
    } catch (e) {
      _log.fine('DHT bootstrap node injection skipped/failed: $e');
    }
  }

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
      _injectDhtNodes();

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
              _latestStats.remove(removedId); // FIX-22
              _torrentSources.remove(removedId);
              _cachedPrioritiesSnapshot.remove(removedId);
            }
            final mapped = torrents.map((key, value) {
              _latestProgress[value.id] = value.progress;
              final safeProgress = value.progress.isFinite
                  ? value.progress.clamp(0.0, 1.0)
                  : 0.0;
              final info = TorrentUpdateInfo(
                id: value.id,
                name: value.name,
                progress: value.progress,
                downloadRate: value.downloadRate,
                uploadRate: value.uploadRate,
                totalDone: value.totalDone,
                totalWanted: value.totalWanted,
                // FIX-PCTG: When totalWanted is 0 (not yet reported by engine),
                // fall back to totalDone (actual bytes received) so the percentage
                // is non-zero during early download phase.
                totalWantedDone: value.totalWanted > 0
                    ? (safeProgress * value.totalWanted).toInt()
                    : value.totalDone,
                hasMetadata: value.hasMetadata,
                stateLabel: value.state.label,
                numSeeds: value.numSeeds,
                numPeers: value.numPeers,
                piecesHave: _estimatePiecesHave(value),
                piecesTotal: _estimatePiecesTotal(value),
                downloadPayloadRate: value.downloadRate,
                uploadPayloadRate: value.uploadRate,
                totalPayloadDownload: value.totalDone,
                totalPayloadUpload: value.totalUploaded,
                currentTracker: '',
                nextAnnounceSeconds: 0,
                distributedCopies: 0.0,
                fileProgress: const [],
                filePriorities: const [],
              );
              _latestStats[value.id] = info; // FIX-22
              return MapEntry(key, info);
            });
            // PERF-1: Throttle to 2s when app is backgrounded or screen is off
            _pendingUpdate = mapped;
            final now = DateTime.now();
            final interval =
                PowerMonitor.screenOff || !DownloadEngine.appInForeground
                    ? const Duration(seconds: 2)
                    : const Duration(milliseconds: 500);
            if (_lastEmitTime == null ||
                now.difference(_lastEmitTime!) >= interval) {
              _lastEmitTime = now;
              _throttleTimer?.cancel();
              _throttleTimer = null;
              if (!controller!.isClosed) controller.add(mapped);
            } else {
              _throttleTimer ??= Timer(
                interval,
                () {
                  if (_pendingUpdate != null &&
                      controller != null &&
                      !controller.isClosed) {
                    _lastEmitTime = DateTime.now();
                    controller.add(_pendingUpdate!);
                  }
                  _throttleTimer = null;
                },
              );
            }
          } catch (e) {
            _log.warning('Error processing torrent update: $e');
          }
        },
        cancelOnError: false,
        onError: (e) {
          _log.warning('Torrent updates stream error: $e');
        },
        onDone: () {
          _throttleTimer?.cancel();
          _throttleTimer = null;
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

  static int _estimatePiecesTotal(Object torrentInfo) {
    try {
      final dynamic raw = torrentInfo;
      // ignore: avoid_dynamic_calls
      final numPieces = raw.numPieces;
      if (numPieces is int && numPieces > 0) return numPieces;
    } catch (_) {}
    const defaultPieceSize = 256 * 1024;
    try {
      final dynamic raw = torrentInfo;
      // ignore: avoid_dynamic_calls
      final totalWanted = (raw.totalWanted as num?)?.toInt() ?? 0;
      if (totalWanted > 0) {
        return (totalWanted / defaultPieceSize).ceil();
      }
    } catch (_) {}
    return 0;
  }

  static int _estimatePiecesHave(Object torrentInfo) {
    try {
      final dynamic raw = torrentInfo;
      // ignore: avoid_dynamic_calls
      final piecesDone = raw.piecesDone;
      if (piecesDone is int && piecesDone > 0) return piecesDone;
    } catch (_) {}
    final total = _estimatePiecesTotal(torrentInfo);
    try {
      final dynamic raw = torrentInfo;
      // ignore: avoid_dynamic_calls
      final progress = (raw.progress as num?)?.toDouble() ?? 0.0;
      if (total > 0 && progress > 0) {
        return (progress * total).round();
      }
    } catch (_) {}
    return 0;
  }

  /// Attempts to save native fast-resume data for [torrentId].
  static Uint8List? fetchResumeBytes(int torrentId) =>
      _CapabilityGate.instance.saveResumeData(torrentId);

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
          await TorrentResumeStore.saveAndWait(
            torrentId: torrentId,
            sourceUrl: source,
            fetchResumeData: () => data,
          );
        }
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
        (id) => _CapabilityGate.instance.saveResumeData(id),
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
        unawaited(
            _tryLoadFastResumeForSource(id, magnetUri)); // FIX-02: kept async
      }
      return id;
    } catch (e) {
      _log.warning('addMagnet failed: $e');
      return -1;
    }
  }

  /// Adds a magnet link and waits up to [timeout] for metadata, emitting periodic status messages with retry capability.
  static Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
  }) async {
    _injectDhtNodes();
    int attempt = 0;

    while (attempt <= maxRetries) {
      attempt++;
      final id = addMagnet(magnetUri, savePath);
      if (id < 0) return -1;

      final stopwatch = Stopwatch()..start();
      final completer = Completer<int>();
      Timer? messageTimer;
      StreamSubscription? sub;

      messageTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        final elapsedSec = stopwatch.elapsed.inSeconds;
        final msg = 'Fetching metadata... (${elapsedSec}s elapsed)';
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
          'Magnet metadata fetch timed out (attempt $attempt/${maxRetries + 1}) for $magnetUri',
        );

        if (attempt <= maxRetries) {
          onStatusUpdate?.call(
            'Retrying metadata fetch with additional default trackers (Attempt ${attempt + 1})...',
          );
          for (final tracker in TrackerManager.defaultTrackers) {
            addTracker(id, tracker);
          }
          await Future.delayed(retryDelay);
          continue;
        }

        removeTorrent(id, deleteFiles: true);
        onStatusUpdate
            ?.call('Metadata fetch failed. Try adding trackers manually.');
        throw TimeoutException(
            'Magnet metadata fetch timed out after $maxRetries retries',
            timeout);
      }
    }
    return -1;
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
        unawaited(
            _tryLoadFastResumeForSource(id, source)); // FIX-02: kept async
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
        final loaded = _CapabilityGate.instance.loadResumeData(id, resumeBytes);
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

  static void removeTorrent(
    int id, {
    bool deleteFiles = false,
    // FIX-TORR-RESTART-3: Default to false to preserve fast-resume blobs.
    // Previously removeTorrent always wiped TorrentResumeStore, so any
    // internal error/retry path that called removeTorrent destroyed the
    // resume data and forced a full piece-recheck on next launch ("start
    // over"). Only pass deleteResumeData: true when the user explicitly
    // deletes the task (or on a definitive retry that requires a clean slate).
    bool deleteResumeData = false,
  }) {
    if (!isInitialized) return;
    if (id >= 0) {
      try {
        LibtorrentFlutter.instance.removeTorrent(id, deleteFiles: deleteFiles);
        if (deleteResumeData) {
          unawaited(TorrentResumeStore.delete(id));
          final source = _torrentSources.remove(id);
          if (source != null) {
            unawaited(TorrentResumeStore.deleteResumeDataForSource(source));
          }
        } else {
          // Just remove from the in-memory source map; the blob stays on disk.
          _torrentSources.remove(id);
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
    if (!isPluginAvailable || !isInitialized || !isTorrentAlive(id)) return;
    if (id >= 0) {
      await _libtorrentLock.synchronized(() async {
        try {
          LibtorrentFlutter.instance.pauseTorrent(id);
          // FIX-H3: Replace polling loop with Completer / stream listener with 2s timeout
          try {
            await torrentUpdates.firstWhere((updateMap) {
              final stats = updateMap[id];
              return stats == null ||
                  stats.stateLabel.toLowerCase().contains('paused') ||
                  stats.stateLabel.toLowerCase().contains('stopped');
            }).timeout(const Duration(seconds: 2));
          } catch (_) {}

          // FIX T-9: Snapshot files AFTER pause-poll, not before
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
                        'downloadedBytes': f.safeDownloadedBytes,
                      })
                  .toList();
            }
          } catch (e) {
            _log.warning('getFiles snapshot failed for id $id (non-fatal): $e');
          }

          // Persist native fast-resume bytes under the stable source key.
          // Best-effort: never throw out of pauseTorrent.
          try {
            final source = _torrentSources[id];
            if (source != null) {
              await TorrentResumeStore.saveAndWait(
                torrentId: id,
                sourceUrl: source,
                fetchResumeData: () =>
                    _CapabilityGate.instance.saveResumeData(id),
                files: torrentFiles,
              );
            }
          } catch (e) {
            _log.warning('saveResumeData failed for id $id: $e');
          }
        } catch (e) {
          _log.warning('pauseTorrent failed for id $id: $e');
        }
      });
    }
  }

  static void resumeTorrent(int id) {
    if (!isInitialized || !isTorrentAlive(id)) return;
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
    if (!_activeTorrentIds.contains(id)) return false;
    try {
      // ignore: avoid_dynamic_calls
      final status =
          (LibtorrentFlutter.instance as dynamic).getTorrentStatus(id);
      if (status != null) return true;
      // getTorrentStatus may return null for a legitimately paused/stopped
      // handle in libtorrent 1.9.2. A paused torrent is NOT dead — treat it
      // as alive so the pause flow isn't treated as a handle loss (which
      // previously triggered a spurious retry and re-queue).
      final stats = _latestStats[id];
      if (stats != null) {
        final label = stats.stateLabel.toLowerCase();
        if (label.contains('paused') || label.contains('stopped')) {
          return true;
        }
      }
      return false;
    } catch (_) {
      // Same as above: if the last known state is paused/stopped, keep the
      // handle registered and report alive.
      final stats = _latestStats[id];
      if (stats != null) {
        final label = stats.stateLabel.toLowerCase();
        if (label.contains('paused') || label.contains('stopped')) {
          return true;
        }
      }
      _activeTorrentIds.remove(id);
      _latestProgress.remove(id);
      _latestStats.remove(id);
      _torrentSources.remove(id);
      _cachedPrioritiesSnapshot.remove(id);
      return false;
    }
  }

  static void recheckTorrent(int id) {
    if (!isInitialized) return;
    if (id >= 0) {
      _CapabilityGate.instance.forceRecheck(id);
    }
  }

  static final Map<int, ({List<TorrentFileItem> files, DateTime fetched})>
      _filesCache = {};

  static void setFilePriorities(int id, List<int> priorities) {
    if (!isInitialized || id < 0) return;
    _filesCache.remove(id);
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
    if (!isInitialized || !isTorrentAlive(id)) return [];
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
              // -1 means libtorrent has no data yet — keep sentinel, do NOT collapse to 0
              resolvedDownloadedBytes = -1;
            }
          } else {
            // Per-file progress unsupported/unavailable for this torrent — keep sentinel
            resolvedDownloadedBytes = -1;
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

  static List<TorrentFileItem> getFilesCached(int id) {
    final cached = _filesCache[id];
    if (cached != null &&
        DateTime.now().difference(cached.fetched).inSeconds < 5) {
      return cached.files;
    }
    final fresh = getFiles(id);
    _filesCache[id] = (files: fresh, fetched: DateTime.now());
    return fresh;
  }

  static Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates {
    if (_state == TorrentSessionState.uninitialized ||
        _state == TorrentSessionState.initializing) {
      return Stream.fromFuture(ready).asyncExpand((_) {
        _startTrackingUpdates();
        return _updateController?.stream ?? const Stream.empty();
      });
    }
    _startTrackingUpdates();
    return _updateController?.stream ?? const Stream.empty();
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
    final file = File(filePath);
    if (!await file.exists()) return false;
    return _CapabilityGate.instance.loadIpFilter(filePath);
  }

  static Future<bool> downloadAndApplyBlocklist(String url) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final tempPath = p.join(tempDir.path, 'blocklist.p2p');
      final dio = Dio();
      await dio.download(url, tempPath);
      return loadIpFilter(tempPath);
    } catch (e) {
      _log.warning('downloadAndApplyBlocklist failed: $e');
      return false;
    }
  }

  static void enableSequentialDownload(int torrentId, bool enabled) {
    if (!isInitialized || torrentId < 0) return;
    _CapabilityGate.instance.setSequentialDownload(torrentId, enabled);
  }

  static void setPieceDeadline(int torrentId, int pieceIndex, int deadlineMs) {
    if (!isInitialized || torrentId < 0) return;
    _CapabilityGate.instance
        .setPieceDeadline(torrentId, pieceIndex, deadlineMs);
  }

  static void enableSuperSeeding(int torrentId, bool enabled) {
    if (!isInitialized || torrentId < 0) return;
    _CapabilityGate.instance.setSuperSeeding(torrentId, enabled);
  }

  static Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  ) async {
    if (!isInitialized || torrentId < 0) return [];
    try {
      final nativeFiles = LibtorrentFlutter.instance.getFiles(torrentId);
      final progress = <TorrentFileProgress>[];

      for (var i = 0; i < nativeFiles.length; i++) {
        final native = nativeFiles[i];
        final filePath = p.join(savePath, native.name);
        final file = File(filePath);

        int diskBytes = 0;
        bool exists = false;
        if (await file.exists()) {
          exists = true;
          diskBytes = await file.length();
          if (diskBytes > 0 && diskBytes >= native.size) {
            final raf = await file.open(mode: FileMode.read);
            final probe = await raf.read(math.min(4096, diskBytes));
            final hasContent = probe.any((b) => b != 0);
            await raf.close();
            if (!hasContent) diskBytes = 0;
          }
        }

        progress.add(TorrentFileProgress(
          index: i,
          name: native.name,
          size: native.size,
          downloadedBytes: diskBytes,
          progress:
              native.size > 0 ? (diskBytes / native.size).clamp(0.0, 1.0) : 1.0,
          exists: exists,
          isComplete: diskBytes >= native.size,
        ));
      }
      return progress;
    } catch (e) {
      _log.warning('getAccurateFileProgress failed for torrent $torrentId: $e');
      return [];
    }
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

  static const List<String> _fallbackDhtNodes = [
    'router.bittorrent.com:6881',
    'dht.transmissionbt.com:6881',
    'router.utorrent.com:6881',
    'dht.aelitis.com:6881',
    'router.silotis.us:6881',
    'dht.libtorrent.org:25401',
    'bootstrap.bittorrent.com:6881',
    'dht.anacrolix.link:42069',
    'router.bitcomet.com:6881',
  ];

  static void refreshDhtBootstrapNodes() {
    try {
      for (final node in _fallbackDhtNodes) {
        final parts = node.split(':');
        // ignore: avoid_dynamic_calls
        (LibtorrentFlutter.instance as dynamic)
            .addDhtNode(parts[0], int.parse(parts[1]));
      }
    } catch (e) {
      _log.fine('refreshDhtBootstrapNodes failed: $e');
    }
  }

  static Future<void> saveDhtState() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final path = p.join(dir.path, 'dht.state');
      final target = LibtorrentFlutter.instance as dynamic;
      // ignore: avoid_dynamic_calls
      final bytes = await target.saveDhtState() as Uint8List?;
      if (bytes != null && bytes.isNotEmpty) {
        final tmp = File('$path.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(path);
      }
    } catch (e) {
      _log.warning('saveDhtState failed: $e');
    }
  }

  static Future<void> loadDhtState() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final path = p.join(dir.path, 'dht.state');
      final file = File(path);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final target = LibtorrentFlutter.instance as dynamic;
        // ignore: avoid_dynamic_calls
        await target.loadDhtState(bytes);
      }
    } catch (e) {
      _log.warning('loadDhtState failed: $e');
    }
  }

  static Future<bool> reattachTorrent(String sourceUrl, String savePath) async {
    try {
      if (sourceUrl.startsWith('magnet:')) {
        final id = addMagnet(sourceUrl, savePath);
        return id >= 0;
      } else {
        final id = addTorrentFile(sourceUrl, savePath);
        return id >= 0;
      }
    } catch (e) {
      _log.warning('reattachTorrent failed for $sourceUrl: $e');
      return false;
    }
  }

  static final Map<int, Set<String>> _webSeeds = {};

  static void addWebSeed(int torrentId, String url) {
    if (url.trim().isEmpty) return;
    _webSeeds.putIfAbsent(torrentId, () => {}).add(url.trim());
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).addWebSeed(torrentId, url.trim());
    } catch (_) {}
  }

  static void removeWebSeed(int torrentId, String url) {
    _webSeeds[torrentId]?.remove(url.trim());
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).removeWebSeed(torrentId, url.trim());
    } catch (_) {}
  }

  static List<String> getWebSeeds(int torrentId) {
    return _webSeeds[torrentId]?.toList() ?? const [];
  }

  static Future<void> setProxy({
    required String host,
    required int port,
    required ProxyType type,
    String? username,
    String? password,
  }) async {
    try {
      // ignore: avoid_dynamic_calls
      await (LibtorrentFlutter.instance as dynamic).setProxy(
        host: host,
        port: port,
        type: type.index,
        username: username,
        password: password,
      );
    } catch (_) {}
  }

  static Future<void> setSslCertificate({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  }) async {
    try {
      // ignore: avoid_dynamic_calls
      await (LibtorrentFlutter.instance as dynamic).setSslCertificate(
        certPath: certPath,
        privateKeyPath: privateKeyPath,
        dhParamsPath: dhParamsPath,
      );
    } catch (_) {}
  }

  static void reconfigureSession() => _configureSessionFromSettings();

  static bool get seedingEnabled => true;

  static void boostMagnetDiscovery(int torrentId) {}

  static void autoEnableSequentialForVideo(int torrentId) {
    if (!isInitialized || torrentId < 0) return;
    try {
      final nativeFiles = LibtorrentFlutter.instance.getFiles(torrentId);
      final hasVideo = nativeFiles.any((f) =>
          f.size > 50 * 1024 * 1024 &&
          (f.name.endsWith('.mp4') ||
              f.name.endsWith('.mkv') ||
              f.name.endsWith('.avi') ||
              f.name.endsWith('.webm') ||
              f.name.endsWith('.mov') ||
              f.name.endsWith('.ts')));
      if (hasVideo) {
        enableSequentialDownload(torrentId, true);
      }
    } catch (_) {}
  }

  static Future<void> autoSaveResumeData() async {
    if (!isPluginAvailable || _activeTorrentIds.isEmpty) return;
    for (final id in _activeTorrentIds) {
      try {
        final blob = _CapabilityGate.instance.saveResumeData(id);
        if (blob != null && blob.isNotEmpty && TorrentResumeStore.validateResumeData(blob)) {
          final source = _torrentSources[id];
          if (source != null) {
            await TorrentResumeStore.saveAndWait(
              torrentId: id,
              sourceUrl: source,
              fetchResumeData: () => blob,
            );
          }
        }
      } catch (e) {
        _log.fine('Auto-save resume data skipped for $id: $e');
      }
    }
  }
}

class TorrentServiceImpl implements ITorrentService {
  @override
  bool get isSupported => TorrentService.isSupported;
  @override
  bool get isInitialized => TorrentService.isInitialized;
  @override
  Future<void> get ready => TorrentService.ready;
  @override
  ValueNotifier<bool> get isAvailable => TorrentService.isAvailable;
  @override
  Set<int> get activeTorrentIds => TorrentService.activeTorrentIds;
  @override
  double progressFor(int id) => TorrentService.progressFor(id);
  @override
  Uint8List? fetchResumeBytes(int id) => TorrentService.fetchResumeBytes(id);
  @override
  Uint8List? resumeBlobFor(int id) => TorrentService.resumeBlobFor(id);
  @override
  bool get fileProgressSupported => TorrentService.fileProgressSupported;
  @override
  bool get filePrioritiesSupported => TorrentService.filePrioritiesSupported;
  @override
  bool get resumeDataSupported => TorrentService.resumeDataSupported;
  @override
  bool get forceRecheckSupported => true;
  @override
  bool get trackersSupported => true;
  @override
  bool get createTorrentSupported => true;
  @override
  bool get ipFilterSupported => true;
  @override
  bool get sequentialDownloadSupported => true;
  @override
  bool get superSeedingSupported => true;
  @override
  bool get pieceDeadlineSupported => true;
  @override
  bool get sequentialDownloadEnabled => TorrentService.sequentialDownloadEnabled;
  @override
  double get shareRatioLimit => TorrentService.shareRatioLimit;
  @override
  int get maxSeedingTimeMinutes => TorrentService.maxSeedingTimeMinutes;

  @override
  Future<bool> hasResumeData(String source) => TorrentService.hasResumeData(source);
  @override
  Future<void> init() => TorrentService.init();
  @override
  Future<void> saveResumeData(int torrentId) => TorrentService.saveResumeData(torrentId);
  @override
  Future<void> saveAllResumeData() => TorrentService.saveAllResumeData();
  @override
  Future<void> dispose() => TorrentService.dispose();

  @override
  int addMagnet(String magnetUri, String savePath) => TorrentService.addMagnet(magnetUri, savePath);
  @override
  Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
  }) =>
      TorrentService.addMagnetWithMetadataTimeout(
        magnetUri,
        savePath,
        timeout: timeout,
        onStatusUpdate: onStatusUpdate,
        maxRetries: maxRetries,
        retryDelay: retryDelay,
      );

  @override
  int addTorrentFile(String filePath, String savePath, {String? sourceKey}) =>
      TorrentService.addTorrentFile(filePath, savePath, sourceKey: sourceKey);

  @override
  void removeTorrent(int id, {bool deleteFiles = false, bool deleteResumeData = false}) =>
      TorrentService.removeTorrent(id, deleteFiles: deleteFiles, deleteResumeData: deleteResumeData);
  @override
  Future<void> pauseTorrent(int id) => TorrentService.pauseTorrent(id);
  @override
  Future<void> forceStopTorrent(int id) => TorrentService.forceStopTorrent(id);
  @override
  void resumeTorrent(int id) => TorrentService.resumeTorrent(id);
  @override
  bool loadResumeData(int id, List<int> data) => TorrentService.loadResumeData(id, data);
  @override
  bool isTorrentAlive(int id) => TorrentService.isTorrentAlive(id);
  @override
  void recheckTorrent(int id) => TorrentService.recheckTorrent(id);
  @override
  void setFilePriorities(int id, List<int> priorities) =>
      TorrentService.setFilePriorities(id, priorities);
  @override
  int getFileCount(int id) => TorrentService.getFileCount(id);
  @override
  void setUploadLimit(int bps) => TorrentService.setUploadLimit(bps);
  @override
  void setDownloadLimit(int bps) => TorrentService.setDownloadLimit(bps);
  @override
  List<TorrentFileItem> getFiles(int id) => TorrentService.getFiles(id);
  @override
  Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates => TorrentService.torrentUpdates;
  @override
  Map<int, TorrentUpdateInfo> get latestStats => TorrentService.latestStats;
  @override
  Map<String, dynamic>? getTorrentSnapshot(int id) => null;
  @override
  String get nativeVersion => '1.9.2';
  @override
  void configureSession([SettingsProvider? settings]) => TorrentService.configureSession(settings);
  @override
  void reconfigureSession() => TorrentService.reconfigureSession();
  @override
  void autoEnableSequentialForVideo(int torrentId) => TorrentService.autoEnableSequentialForVideo(torrentId);
  @override
  Future<void> autoSaveResumeData() => TorrentService.autoSaveResumeData();

  @override
  List<TrackerInfo> getTrackers(int torrentId) => TorrentService.getTrackers(torrentId);
  @override
  void addTracker(int torrentId, String trackerUrl, {int tier = 0}) =>
      TorrentService.addTracker(torrentId, trackerUrl, tier: tier);
  @override
  void removeTracker(int torrentId, String trackerUrl) =>
      TorrentService.removeTracker(torrentId, trackerUrl);
  @override
  void announceNow(int torrentId) => TorrentService.announceNow(torrentId);
  @override
  void boostMagnetDiscovery(int torrentId) {}

  @override
  Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) =>
      TorrentService.createTorrent(
        sourcePath: sourcePath,
        outputPath: outputPath,
        trackers: trackers,
        comment: comment,
        pieceSize: pieceSize,
        isPrivate: isPrivate,
      );

  @override
  Future<bool> loadIpFilter(String filePath) => TorrentService.loadIpFilter(filePath);
  @override
  Future<bool> downloadAndApplyBlocklist(String url) => TorrentService.downloadAndApplyBlocklist(url);

  @override
  void enableSequentialDownload(int torrentId, bool enabled) =>
      TorrentService.enableSequentialDownload(torrentId, enabled);
  @override
  void setSequentialDownload(int torrentId, bool enabled) =>
      TorrentService.enableSequentialDownload(torrentId, enabled);
  @override
  void prioritizeFile(int torrentId, int fileIndex, {int priority = 7}) {}
  @override
  void setPieceDeadline(int torrentId, int pieceIndex, int deadlineMs) =>
      TorrentService.setPieceDeadline(torrentId, pieceIndex, deadlineMs);
  @override
  void enableSuperSeeding(int torrentId, bool enabled) =>
      TorrentService.enableSuperSeeding(torrentId, enabled);

  @override
  Stream<TorrentAlertEvent> get alertUpdates => const Stream.empty();
  @override
  List<TorrentAlertEvent> getRecentAlerts([int? torrentId]) => const [];
  @override
  void applySettingsPack(TorrentSettingsPack pack) {}

  @override
  Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  ) =>
      TorrentService.getAccurateFileProgress(torrentId, savePath);

  @override
  Future<Map<String, dynamic>?> getPieceProgress(int torrentId) async => null;

  @override
  Future<void> setProxy({
    required String host,
    required int port,
    required ProxyType type,
    String? username,
    String? password,
  }) =>
      TorrentService.setProxy(
        host: host,
        port: port,
        type: type,
        username: username,
        password: password,
      );

  @override
  Future<void> setSslCertificate({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  }) =>
      TorrentService.setSslCertificate(
        certPath: certPath,
        privateKeyPath: privateKeyPath,
        dhParamsPath: dhParamsPath,
      );

  @override
  void addWebSeed(int torrentId, String url) => TorrentService.addWebSeed(torrentId, url);
  @override
  void removeWebSeed(int torrentId, String url) => TorrentService.removeWebSeed(torrentId, url);
  @override
  List<String> getWebSeeds(int torrentId) => TorrentService.getWebSeeds(torrentId);

  @override
  bool shouldStopSeeding({
    required double progress,
    required int uploadedBytes,
    int? totalBytes,
    int? downloadedBytes,
    Duration? seedingDuration,
    double? shareRatioLimit,
    double? customRatioLimit,
    int? maxSeedingMinutes,
    int? customMaxTimeMinutes,
    DateTime? completedAt,
  }) =>
      TorrentService.shouldStopSeeding(
        progress: progress,
        uploadedBytes: uploadedBytes,
        downloadedBytes: downloadedBytes ?? 1,
        shareRatioLimit: shareRatioLimit ?? 2.0,
        maxSeedingMinutes: maxSeedingMinutes ?? 0,
        completedAt: completedAt,
      );
}

class TorrentServiceStub implements ITorrentService {
  @override
  bool get isSupported => false;
  @override
  bool get isInitialized => false;
  @override
  Future<void> get ready => Future.value();
  @override
  final ValueNotifier<bool> isAvailable = ValueNotifier(false);
  @override
  Set<int> get activeTorrentIds => const <int>{};
  @override
  double progressFor(int id) => 0.0;
  @override
  Uint8List? fetchResumeBytes(int id) => null;
  @override
  Uint8List? resumeBlobFor(int id) => null;
  @override
  bool get fileProgressSupported => false;
  @override
  bool get filePrioritiesSupported => false;
  @override
  bool get resumeDataSupported => false;
  @override
  bool get forceRecheckSupported => false;
  @override
  bool get trackersSupported => false;
  @override
  bool get createTorrentSupported => false;
  @override
  bool get ipFilterSupported => false;
  @override
  bool get sequentialDownloadSupported => false;
  @override
  bool get superSeedingSupported => false;
  @override
  bool get pieceDeadlineSupported => false;
  @override
  bool get sequentialDownloadEnabled => false;
  @override
  double get shareRatioLimit => 2.0;
  @override
  int get maxSeedingTimeMinutes => 0;

  @override
  Future<bool> hasResumeData(String source) async => false;
  @override
  Future<void> init() async {}
  @override
  Future<void> saveResumeData(int torrentId) async {}
  @override
  Future<void> saveAllResumeData() async {}
  @override
  Future<void> dispose() async {}

  @override
  int addMagnet(String magnetUri, String savePath) => -1;
  @override
  Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
  }) async =>
      -1;
  @override
  int addTorrentFile(String filePath, String savePath, {String? sourceKey}) =>
      -1;

  @override
  void removeTorrent(int id,
      {bool deleteFiles = false, bool deleteResumeData = false}) {}
  @override
  Future<void> pauseTorrent(int id) async {}
  @override
  Future<void> forceStopTorrent(int id) async {}
  @override
  void resumeTorrent(int id) {}
  @override
  bool loadResumeData(int id, List<int> data) => false;
  @override
  bool isTorrentAlive(int id) => false;
  @override
  void recheckTorrent(int id) {}
  @override
  void setFilePriorities(int id, List<int> priorities) {}
  @override
  int getFileCount(int id) => 0;
  @override
  void setUploadLimit(int bps) {}
  @override
  void setDownloadLimit(int bps) {}
  @override
  List<TorrentFileItem> getFiles(int id) => [];
  @override
  Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates =>
      const Stream.empty();
  @override
  Map<int, TorrentUpdateInfo> get latestStats => const {};
  @override
  Map<String, dynamic>? getTorrentSnapshot(int id) => null;
  @override
  String get nativeVersion => 'stub';
  @override
  void configureSession([SettingsProvider? settings]) {}
  @override
  void reconfigureSession() {}
  @override
  void autoEnableSequentialForVideo(int torrentId) {}
  @override
  Future<void> autoSaveResumeData() async {}

  @override
  List<TrackerInfo> getTrackers(int torrentId) => [];
  @override
  void addTracker(int torrentId, String trackerUrl, {int tier = 0}) {}
  @override
  void removeTracker(int torrentId, String trackerUrl) {}
  @override
  void announceNow(int torrentId) {}
  @override
  void boostMagnetDiscovery(int torrentId) {}

  @override
  Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) async =>
      null;

  @override
  Future<bool> loadIpFilter(String filePath) async => false;
  @override
  Future<bool> downloadAndApplyBlocklist(String url) async => false;

  @override
  void enableSequentialDownload(int torrentId, bool enabled) {}
  @override
  void setSequentialDownload(int torrentId, bool enabled) {}
  @override
  void prioritizeFile(int torrentId, int fileIndex, {int priority = 7}) {}
  @override
  void setPieceDeadline(int torrentId, int pieceIndex, int deadlineMs) {}
  @override
  void enableSuperSeeding(int torrentId, bool enabled) {}

  @override
  Stream<TorrentAlertEvent> get alertUpdates => const Stream.empty();
  @override
  List<TorrentAlertEvent> getRecentAlerts([int? torrentId]) => const [];
  @override
  void applySettingsPack(TorrentSettingsPack pack) {}

  @override
  Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  ) async =>
      [];

  @override
  Future<Map<String, dynamic>?> getPieceProgress(int torrentId) async => null;

  @override
  Future<void> setProxy({
    required String host,
    required int port,
    required ProxyType type,
    String? username,
    String? password,
  }) async {}

  @override
  Future<void> setSslCertificate({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  }) async {}

  @override
  void addWebSeed(int torrentId, String url) {}
  @override
  void removeWebSeed(int torrentId, String url) {}
  @override
  List<String> getWebSeeds(int torrentId) => const [];

  @override
  bool shouldStopSeeding({
    required double progress,
    required int uploadedBytes,
    int? totalBytes,
    int? downloadedBytes,
    Duration? seedingDuration,
    double? shareRatioLimit,
    double? customRatioLimit,
    int? maxSeedingMinutes,
    int? customMaxTimeMinutes,
    DateTime? completedAt,
  }) =>
      false;
}



