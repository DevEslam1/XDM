import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, listEquals;
import 'package:flutter/services.dart' show MissingPluginException;

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
  /// v2.0.0+: resumeDataSupported is always true — saveResumeData ships in all
  /// releases from 1.9.3 onward. Probing with id=-1 on the new disk I/O backend
  /// can trigger native-side warnings, so we only probe methods that could
  /// genuinely be absent on older plugin versions.
  void probeCapabilities() {
    fileProgressSupported = true;
    filePrioritiesSupported = true;
    // v2.0.0+: saveResumeData is always available — no probe needed.
    resumeDataSupported = true;
    forceRecheckSupported = true;
    trackersSupported = true;
    createTorrentSupported = true;
    ipFilterSupported = true;
    sequentialDownloadSupported = true;
    superSeedingSupported = true;
    pieceDeadlineSupported = true;

    final target = LibtorrentFlutter.instance;

    // Probe per-file methods — these were absent in very old plugin versions.
    // Use MissingPluginException guard so real errors (e.g. bad native state)
    // still propagate and are not silently swallowed.
    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).getFileProgress(-1);
    } on MissingPluginException {
      fileProgressSupported = false;
      _log.fine('probe getFileProgress: MissingPluginException — disabled');
    } on NoSuchMethodError {
      fileProgressSupported = false;
      _log.fine('probe getFileProgress: NoSuchMethodError — disabled');
    } catch (e) {
      // Non-MissingPlugin errors (e.g. invalid id argument) mean the method
      // EXISTS but rejected the sentinel id — capability is still present.
      _log.fine('probe getFileProgress: present (rejected sentinel id: $e)');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).getFilePriorities(-1);
    } on MissingPluginException {
      filePrioritiesSupported = false;
      _log.fine('probe getFilePriorities: MissingPluginException — disabled');
    } on NoSuchMethodError {
      filePrioritiesSupported = false;
      _log.fine('probe getFilePriorities: NoSuchMethodError — disabled');
    } catch (e) {
      _log.fine('probe getFilePriorities: present (rejected sentinel id: $e)');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).forceReCheck(-1);
    } on MissingPluginException {
      forceRecheckSupported = false;
      _log.fine('probe forceReCheck: MissingPluginException — disabled');
    } on NoSuchMethodError {
      forceRecheckSupported = false;
      _log.fine('probe forceReCheck: NoSuchMethodError — disabled');
    } catch (e) {
      _log.fine('probe forceReCheck: present (rejected sentinel id: $e)');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).getTrackers(-1);
    } on MissingPluginException {
      trackersSupported = false;
      _log.fine('probe getTrackers: MissingPluginException — disabled');
    } on NoSuchMethodError {
      trackersSupported = false;
      _log.fine('probe getTrackers: NoSuchMethodError — disabled');
    } catch (e) {
      _log.fine('probe getTrackers: present (rejected sentinel id: $e)');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).createTorrent(
        sourcePath: '',
        outputPath: '',
        trackers: <String>[],
      );
    } on MissingPluginException {
      createTorrentSupported = false;
      _log.fine('probe createTorrent: MissingPluginException — disabled');
    } on NoSuchMethodError {
      createTorrentSupported = false;
      _log.fine('probe createTorrent: NoSuchMethodError — disabled');
    } catch (e) {
      _log.fine('probe createTorrent: present (rejected empty args: $e)');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).loadIpFilter('');
    } on MissingPluginException {
      ipFilterSupported = false;
      _log.fine('probe loadIpFilter: MissingPluginException — disabled');
    } on NoSuchMethodError {
      ipFilterSupported = false;
      _log.fine('probe loadIpFilter: NoSuchMethodError — disabled');
    } catch (e) {
      _log.fine('probe loadIpFilter: present (rejected empty path: $e)');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).setSequentialDownload(-1, false);
    } on MissingPluginException {
      sequentialDownloadSupported = false;
      _log.fine('probe setSequentialDownload: MissingPluginException — disabled');
    } on NoSuchMethodError {
      sequentialDownloadSupported = false;
      _log.fine('probe setSequentialDownload: NoSuchMethodError — disabled');
    } catch (e) {
      _log.fine('probe setSequentialDownload: present (rejected sentinel id: $e)');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).setSuperSeeding(-1, false);
    } on MissingPluginException {
      superSeedingSupported = false;
      _log.fine('probe setSuperSeeding: MissingPluginException — disabled');
    } on NoSuchMethodError {
      superSeedingSupported = false;
      _log.fine('probe setSuperSeeding: NoSuchMethodError — disabled');
    } catch (e) {
      _log.fine('probe setSuperSeeding: present (rejected sentinel id: $e)');
    }

    try {
      // ignore: avoid_dynamic_calls
      (target as dynamic).setPieceDeadline(-1, 0, 0);
    } on MissingPluginException {
      pieceDeadlineSupported = false;
      _log.fine('probe setPieceDeadline: MissingPluginException — disabled');
    } on NoSuchMethodError {
      pieceDeadlineSupported = false;
      _log.fine('probe setPieceDeadline: NoSuchMethodError — disabled');
    } catch (e) {
      _log.fine('probe setPieceDeadline: present (rejected sentinel id: $e)');
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
    if (!fileProgressSupported || !TorrentService.isTorrentAlive(id)) return null;
    try {
      // ignore: avoid_dynamic_calls
      return (LibtorrentFlutter.instance as dynamic).getFileProgress(id)
          as List<dynamic>?;
    } catch (_) {
      return null;
    }
  }

  List<dynamic>? filePriorities(int id) {
    if (!filePrioritiesSupported || !TorrentService.isTorrentAlive(id)) return null;
    try {
      // ignore: avoid_dynamic_calls
      return (LibtorrentFlutter.instance as dynamic).getFilePriorities(id)
          as List<dynamic>?;
    } catch (_) {
      return null;
    }
  }

  void setFilePriorities(int id, List<int> priorities) {
    if (!filePrioritiesSupported || !TorrentService.isTorrentAlive(id)) return;
    try {
      LibtorrentFlutter.instance.setFilePriorities(id, priorities);
    } catch (e) {
      _log.warning('setFilePriorities failed for id $id: $e');
    }
  }

  void forceRecheck(int id) {
    if (!forceRecheckSupported || !TorrentService.isTorrentAlive(id)) return;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).forceReCheck(id);
    } catch (_) {}
  }

  Uint8List? saveResumeData(int id) {
    if (!resumeDataSupported || !TorrentService.isTorrentAlive(id)) return null;
    try {
      // ignore: avoid_dynamic_calls
      return (LibtorrentFlutter.instance as dynamic).saveResumeData(id)
          as Uint8List?;
    } catch (_) {
      return null;
    }
  }

  bool loadResumeData(int id, Uint8List data) {
    if (!resumeDataSupported || !TorrentService.isTorrentAlive(id)) return false;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).loadResumeData(id, data);
      return true;
    } catch (_) {
      return false;
    }
  }

  List<TrackerInfo>? trackers(int id) {
    if (!trackersSupported || !TorrentService.isTorrentAlive(id)) return null;
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
    if (!trackersSupported || !TorrentService.isTorrentAlive(id)) return false;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).addTracker(id, trackerUrl, tier);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool removeTracker(int id, String trackerUrl) {
    if (!trackersSupported || !TorrentService.isTorrentAlive(id)) return false;
    try {
      // ignore: avoid_dynamic_calls
      (LibtorrentFlutter.instance as dynamic).removeTracker(id, trackerUrl);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool announceNow(int id) {
    if (!trackersSupported || !TorrentService.isTorrentAlive(id)) return false;
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
  /// FIX v2.0.0: Exposes the source-URL map (torrentHandleId → magnetUri/filePath)
  /// so callers can resolve a native handle ID by URL when infoHash is unavailable.
  static Map<int, String> get activeTorrentSources =>
      Map.unmodifiable(_torrentSources);
  static Map<int, TorrentUpdateInfo> get latestStats =>
      Map.unmodifiable(_latestStats);


  static final Map<int, List<TorrentFileItem>> _cachedFiles = {};
  static final Map<int, List<TrackerInfo>> _cachedTrackers = {};

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
    if (_state == TorrentSessionState.pausing ||
        _state == TorrentSessionState.disposing ||
        _state == TorrentSessionState.disposed) {
      // FIX: Return benignly instead of throwing StateError.
      // Callers like pauseTorrent, getTorrentSnapshot, getFiles, hasResumeData
      // are invoked during teardown (pause/delete/exitApp) and must not crash.
      return Future.value();
    }
    return Future.value();
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
      // v2.0.0 removed addDhtNode — DHT bootstrap nodes are now configured
      // through getDefaultConfig().copyWith(). Silently ignore.
      _log.finest('DHT node injection skipped (v2.0.0+): $e');
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

  // --- Safe Type Conversion Helpers ---
  static int _toInt(dynamic v, [int defaultVal = 0]) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? defaultVal;
    return defaultVal;
  }

  static double _toDouble(dynamic v, [double defaultVal = 0.0]) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? defaultVal;
    return defaultVal;
  }

  static bool _toBool(dynamic v, [bool defaultVal = false]) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.toLowerCase() == 'true' || v == '1';
    return defaultVal;
  }

  static dynamic _readField(dynamic obj, String k) {
    try {
      switch (k) {
        case 'id': return (obj as dynamic).id;
        case 'name': return (obj as dynamic).name;
        case 'path': return (obj as dynamic).path;
        case 'torrent_name':
        case 'torrentName': return (obj as dynamic).torrentName;
        case 'file_name':
        case 'fileName': return (obj as dynamic).fileName;
        case 'downloadRate':
        case 'download_rate': return (obj as dynamic).downloadRate;
        case 'uploadRate':
        case 'upload_rate': return (obj as dynamic).uploadRate;
        case 'totalDone':
        case 'total_done': return (obj as dynamic).totalDone;
        case 'totalWanted':
        case 'total_wanted':
        case 'wanted_size':
        case 'wantedSize': return (obj as dynamic).totalWanted;
        case 'totalWantedDone':
        case 'total_wanted_done': return (obj as dynamic).totalWantedDone;
        case 'totalUploaded':
        case 'total_uploaded': return (obj as dynamic).totalUploaded;
        case 'numSeeds':
        case 'num_seeds': return (obj as dynamic).numSeeds;
        case 'seeds': return (obj as dynamic).seeds;
        case 'numPeers':
        case 'num_peers': return (obj as dynamic).numPeers;
        case 'peers': return (obj as dynamic).peers;
        case 'size': return (obj as dynamic).size;
        case 'file_size': return (obj as dynamic).file_size;
        case 'length': return (obj as dynamic).length;
        case 'downloadedBytes':
        case 'downloaded_bytes': return (obj as dynamic).downloadedBytes;
        case 'downloaded': return (obj as dynamic).downloaded;
        case 'priority': return (obj as dynamic).priority;
        case 'selected': return (obj as dynamic).selected;
        case 'index': return (obj as dynamic).index;
        case 'progress': return (obj as dynamic).progress;
        case 'distributedCopies':
        case 'distributed_copies': return (obj as dynamic).distributedCopies;
        case 'state':
          final st = (obj as dynamic).state;
          try {
            // ignore: avoid_dynamic_calls
            return st?.label?.toString() ?? st?.toString();
          } catch (_) {
            return st?.toString();
          }
        case 'stateLabel':
        case 'state_label': return (obj as dynamic).stateLabel;
        case 'hasMetadata':
        case 'has_metadata': return (obj as dynamic).hasMetadata;
        case 'isPaused':
        case 'is_paused': return (obj as dynamic).isPaused;
        case 'isFinished':
        case 'is_finished': return (obj as dynamic).isFinished;
        default:
          try {
            // ignore: avoid_dynamic_calls
            return (obj as dynamic).toJson()[k];
          } catch (_) {
            return null;
          }
      }
    } catch (_) {
      return null;
    }
  }

  static int _safeInt(dynamic obj, String key1, [String? key2, String? key3, int defaultVal = 0]) {
    if (obj == null) return defaultVal;
    dynamic v;
    if (obj is Map) {
      v = obj[key1];
      if (v == null && key2 != null) v = obj[key2];
      if (v == null && key3 != null) v = obj[key3];
    } else {
      v = _readField(obj, key1) ?? (key2 != null ? _readField(obj, key2) : null) ?? (key3 != null ? _readField(obj, key3) : null);
    }
    return _toInt(v, defaultVal);
  }

  static double _safeDouble(dynamic obj, String key1, [String? key2, double defaultVal = 0.0]) {
    if (obj == null) return defaultVal;
    dynamic v;
    if (obj is Map) {
      v = obj[key1];
      if (v == null && key2 != null) v = obj[key2];
    } else {
      v = _readField(obj, key1) ?? (key2 != null ? _readField(obj, key2) : null);
    }
    return _toDouble(v, defaultVal);
  }

  static bool _safeBool(dynamic obj, String key1, [String? key2, bool defaultVal = false]) {
    if (obj == null) return defaultVal;
    dynamic v;
    if (obj is Map) {
      v = obj[key1];
      if (v == null && key2 != null) v = obj[key2];
    } else {
      v = _readField(obj, key1) ?? (key2 != null ? _readField(obj, key2) : null);
    }
    return _toBool(v, defaultVal);
  }

  static String _safeString(dynamic obj, String key1, [String? key2, String defaultVal = '']) {
    if (obj == null) return defaultVal;
    dynamic v;
    if (obj is Map) {
      v = obj[key1];
      if (v == null && key2 != null) v = obj[key2];
    } else {
      v = _readField(obj, key1) ?? (key2 != null ? _readField(obj, key2) : null);
    }
    if (v != null && v.toString().isNotEmpty) return v.toString();
    return defaultVal;
  }

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
          if (torrents.isNotEmpty) {
            final Object firstValue = torrents.values.first;
            if (firstValue is Map) {
              _log.finest('[DMX-DEBUG] torrentUpdates keys: ${firstValue.keys.toList()}');
            } else {
              _log.finest('[DMX-DEBUG] torrentUpdates value type: ${firstValue.runtimeType}');
            }
          }
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
              final rawId = _safeInt(value, 'id', 'torrent_id', null, key);
              final progress = _safeDouble(value, 'progress', 'progress_ratio', 0.0);
              _latestProgress[rawId] = progress;
              final safeProgress = progress.isFinite
                  ? progress.clamp(0.0, 1.0)
                  : 0.0;

              final totalDone = _safeInt(value, 'totalDone', 'total_done', 'downloaded');
              final totalWanted = _safeInt(value, 'totalWanted', 'total_wanted', 'size');
              final totalWantedDone = _safeInt(value, 'totalWantedDone', 'total_wanted_done', 'downloaded');
              final totalUploaded = _safeInt(value, 'totalUploaded', 'total_uploaded', 'uploaded');
              final downloadRate = _safeInt(value, 'downloadRate', 'download_rate');
              final uploadRate = _safeInt(value, 'uploadRate', 'upload_rate');
              final numSeeds = _safeInt(value, 'numSeeds', 'seeds', 'num_seeds').clamp(0, 999999);
              final numPeers = _safeInt(value, 'numPeers', 'peers', 'num_peers').clamp(0, 999999);
              final rawHasMetadata = _safeBool(value, 'hasMetadata', 'has_metadata');
              final isPaused = _safeBool(value, 'isPaused', 'is_paused');
              final name = _safeString(value, 'name', 'torrent_name', 'Torrent');
              final stateLabel = isPaused ? 'Paused' : _safeString(value, 'stateLabel', 'state', 'unknown');

              var cached = _cachedFiles[rawId];
              if (rawHasMetadata &&
                  (cached == null ||
                      cached.isEmpty ||
                      cached.every((f) => f.size <= 0))) {
                try {
                  cached = getFiles(rawId);
                } catch (_) {}
              }
              final int cachedFilesSum =
                  cached?.fold<int>(0, (s, f) => s + f.size) ?? 0;
              final hasRealFiles = cachedFilesSum > 0;
              final hasMetadata = rawHasMetadata || hasRealFiles;

              final effectiveTotalWanted = totalWanted > 0
                  ? totalWanted
                  : (cachedFilesSum > 0 ? cachedFilesSum : 0);
              final effectiveTotalWantedDone = totalWantedDone;

              final info = TorrentUpdateInfo(
                id: rawId,
                name: name,
                progress: progress,
                downloadRate: downloadRate,
                uploadRate: uploadRate,
                totalDone: totalDone,
                totalWanted: effectiveTotalWanted,
                totalWantedDone: effectiveTotalWantedDone,
                hasMetadata: hasMetadata,
                stateLabel: stateLabel,
                numSeeds: numSeeds,
                numPeers: numPeers,
                piecesHave: _estimatePiecesHave(value),
                piecesTotal: _estimatePiecesTotal(value),
                downloadPayloadRate: downloadRate,
                uploadPayloadRate: uploadRate,
                totalPayloadDownload: totalDone,
                totalPayloadUpload: totalUploaded,
                infoHash: '',
                currentTracker: '',
                nextAnnounceSeconds: 0,
                distributedCopies: _safeDouble(value, 'distributedCopies', 'distributed_copies', 0.0),
                fileProgress: const [],
                filePriorities: const [],
              );
              _latestStats[rawId] = info; // FIX-22
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
        // FIX v2.0.0: Pre-register in TorrentResumeStore immediately so that
        // the periodic autoSaveResumeData / saveAll paths don't emit
        // "no source registered for id N" during the metadata-fetch window.
        TorrentResumeStore.registerSource(id, magnetUri);
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
        // FIX v2.0.0: Pre-register in TorrentResumeStore (mirrors addMagnet fix).
        TorrentResumeStore.registerSource(id, source);
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
      final wasActive = _activeTorrentIds.remove(id);
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
      _latestStats.remove(id);
      _cachedFiles.remove(id);
      _cachedTrackers.remove(id);
      _cachedPrioritiesSnapshot.remove(id);

      if (wasActive) {
        try {
          LibtorrentFlutter.instance.removeTorrent(id, deleteFiles: deleteFiles);
        } catch (e) {
          _log.warning('removeTorrent failed for id $id: $e');
        }
      }
    }
  }

  static Future<void> pauseTorrent(int id) async {
    if (!isPluginAvailable || !isInitialized || !isTorrentAlive(id)) return;
    if (id >= 0) {
      await _libtorrentLock.synchronized(() async {
        if (!isTorrentAlive(id)) return;
        try {
          LibtorrentFlutter.instance.pauseTorrent(id);
          // FIX-PAUSE: Wait for the engine to confirm the paused state.
          // Extended to 4s for Android posix_disk_io flush latency (v2.0.0).
          // Fallback: if no paused/stopped state is emitted, check
          // isTorrentAlive — a released handle also counts as paused.
          try {
            await torrentUpdates.firstWhere((updateMap) {
              final stats = updateMap[id];
              return stats == null ||
                  stats.stateLabel.toLowerCase().contains('paused') ||
                  stats.stateLabel.toLowerCase().contains('stopped');
            }).timeout(const Duration(seconds: 4));
          } on TimeoutException {
            // Timeout reached — if the handle is dead, treat it as paused.
            if (!isTorrentAlive(id)) {
              _log.fine('pauseTorrent $id: timeout but handle is gone, treating as paused');
            } else {
              _log.warning('pauseTorrent $id: 4s timeout, torrent still alive — proceeding anyway');
            }
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
      return status != null;
    } on NoSuchMethodError {
      // FIX v2.0.0: getTorrentStatus is removed or changed in the new plugin version.
      // If the ID is still in _activeTorrentIds, assume it is alive
      // because we explicitly remove it when it is stopped/deleted.
      return true;
    } catch (_) {
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
    if (!isInitialized || !isTorrentAlive(id)) {
      return _cachedFiles[id] ?? const [];
    }
    if (id >= 0) {
      try {
        final files = LibtorrentFlutter.instance.getFiles(id);
        final progress = _CapabilityGate.instance.fileProgressSupported
            ? _CapabilityGate.instance.fileProgress(id)
            : null;

        final priorities = _CapabilityGate.instance.filePrioritiesSupported
            ? _CapabilityGate.instance.filePriorities(id)
            : null;

        final result = List.generate(files.length, (i) {
          final dynamic f = files[i];
          final index = _safeInt(f, 'index', 'file_index', null, i);
          final name = _safeString(f, 'name', 'path', 'file_$i');
          final size = _safeInt(f, 'size', 'file_size', 'length', 0);
          final priority = (priorities != null && i < priorities.length)
              ? _toInt(priorities[i], 4)
              : _safeInt(f, 'priority', null, null, 4);
          final selected = (priorities != null && i < priorities.length)
              ? _toInt(priorities[i], 1) > 0
              : _safeBool(f, 'selected', null, true);

          int resolvedDownloadedBytes;
          if (progress != null && i < progress.length) {
            final rawBytes = _toInt(progress[i], -1);
            if (rawBytes >= 0) {
              resolvedDownloadedBytes = rawBytes.clamp(0, size);
            } else {
              // -1 means libtorrent has no data yet — keep sentinel, do NOT collapse to 0
              resolvedDownloadedBytes = -1;
            }
          } else {
            final directBytes = (f is Map)
                ? (f['downloaded_bytes'] ?? f['downloadedBytes'] ?? f['downloaded'])
                : null;
            if (directBytes != null) {
              final parsed = _toInt(directBytes, -1);
              resolvedDownloadedBytes = parsed >= 0 ? parsed.clamp(0, size) : -1;
            } else {
              resolvedDownloadedBytes = -1;
            }
          }

          return TorrentFileItem(
            index: index,
            name: name,
            size: size,
            downloadedBytes: resolvedDownloadedBytes,
            priority: priority,
            selected: selected,
          );
        });
        if (result.isNotEmpty) {
          _cachedFiles[id] = result;
        }
        return result;
      } catch (e, st) {
        _log.fine('getFiles failed for id $id, returning cache', e, st);
        return _cachedFiles[id] ?? const [];
      }
    }
    return _cachedFiles[id] ?? const [];
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
    if (_updatesSub == null) {
      _startTrackingUpdates();
      return _updateController?.stream ?? const Stream.empty();
    }
    if (_updateController?.isClosed == true) {
      _updateController = null;
      _updatesSub?.cancel();
      _updatesSub = null;
      _libtorrentLock.synchronized(() async {
        _startTrackingUpdates();
        return _updateController?.stream ?? const Stream.empty();
      });
    }
    _startTrackingUpdates();
    return _updateController?.stream ?? const Stream.empty();
  }

  /// Returns a point-in-time snapshot map of stats, files, trackers, and webSeeds for [id].
  static Map<String, dynamic>? getTorrentSnapshot(int id) {
    final stats = _latestStats[id];
    final progress = _latestProgress[id];
    if (stats == null && progress == null) return null;

    final numPeers = stats?.numPeers ?? 0;
    final numSeeds = stats?.numSeeds ?? 0;
    final numLeechers = (numPeers - numSeeds) > 0 ? (numPeers - numSeeds) : 0;

    return {
      'progress': progressFor(id),
      'downloadedBytes': stats?.totalDone ?? 0,
      'uploadedBytes': stats?.totalPayloadUpload ?? 0,
      'downloadRate': stats?.downloadRate ?? 0,
      'uploadRate': stats?.uploadRate ?? 0,
      'numPeers': numPeers,
      'numSeeds': numSeeds,
      'numLeechers': numLeechers,
      'totalWanted': stats?.totalWanted ?? 0,
      'totalWantedDone': stats?.totalWantedDone ?? stats?.totalDone ?? 0,
      'totalDone': stats?.totalDone ?? 0,
      'numPieces': stats?.piecesTotal ?? 0,
      'numFinishedPieces': stats?.piecesHave ?? 0,
      'distributedCopies': stats?.distributedCopies ?? 0.0,
      'availability': stats?.distributedCopies ?? 0.0,
      'hasMetadata': stats?.hasMetadata ?? false,
      'state': stats?.stateLabel ?? 'unknown',
      'isPaused': !isTorrentAlive(id) || _state != TorrentSessionState.ready,
      'isSeeding': stats?.stateLabel.toLowerCase().contains('seeding') ?? false,
      'isFinished': (stats?.totalWanted != null &&
              stats!.totalWanted > 0 &&
              stats.totalDone >= stats.totalWanted) ||
          (stats?.progress != null && stats!.progress >= 1.0),
      'files': getFiles(id),
      'trackers': _CapabilityGate.instance.trackersSupported
          ? getTrackers(id)
          : <TrackerInfo>[],
      'webSeeds': getWebSeeds(id),
    };
  }

  // ---------------------------------------------------------------------------
  // Trackers, Torrent Creation & IP Filtering
  // ---------------------------------------------------------------------------
  static List<TrackerInfo> getTrackers(int torrentId) {
    if (!isInitialized || torrentId < 0) {
      return _cachedTrackers[torrentId] ?? const [];
    }
    try {
      final trackers = _CapabilityGate.instance.trackers(torrentId);
      if (trackers != null && trackers.isNotEmpty) {
        _cachedTrackers[torrentId] = trackers;
        return trackers;
      }
      return _cachedTrackers[torrentId] ?? const [];
    } catch (e, st) {
      _log.fine('getTrackers failed for id $torrentId', e, st);
      return _cachedTrackers[torrentId] ?? const [];
    }
  }

  static bool addTracker(int torrentId, String trackerUrl, {int tier = 0}) {
    if (!isInitialized || torrentId < 0) return false;
    return _CapabilityGate.instance
        .addTracker(torrentId, trackerUrl, tier: tier);
  }

  static bool removeTracker(int torrentId, String trackerUrl) {
    if (!isInitialized || torrentId < 0) return false;
    return _CapabilityGate.instance.removeTracker(torrentId, trackerUrl);
  }

  static bool announceNow(int torrentId) {
    if (!isInitialized || torrentId < 0) return false;
    return _CapabilityGate.instance.announceNow(torrentId);
  }

  static Future<String?> createTorrent({
    required String sourcePath,
    required String outputPath,
    required List<String> trackers,
    String comment = '',
    int pieceSize = 0,
    bool isPrivate = false,
  }) {
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

  static void setSequentialDownload(int torrentId, bool enabled) =>
      enableSequentialDownload(torrentId, enabled);

  static void setPieceDeadline(int torrentId, int pieceIndex, int deadlineMs) {
    if (!isInitialized || torrentId < 0) return;
    _CapabilityGate.instance
        .setPieceDeadline(torrentId, pieceIndex, deadlineMs);
  }

  static void enableSuperSeeding(int torrentId, bool enabled) {
    if (!isInitialized || torrentId < 0) return;
    _CapabilityGate.instance.setSuperSeeding(torrentId, enabled);
  }

  static void setSuperSeeding(int torrentId, bool enabled) =>
      enableSuperSeeding(torrentId, enabled);

  static Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  ) async {
    if (!isInitialized || torrentId < 0) return [];
    try {
      final nativeFiles = LibtorrentFlutter.instance.getFiles(torrentId);
      final progress = <TorrentFileProgress>[];

      for (var i = 0; i < nativeFiles.length; i++) {
        final dynamic native = nativeFiles[i];
        final fileName = _safeString(native, 'name', 'path', 'file_$i');
        final rawSize = _safeInt(native, 'size', 'file_size', 'length', 0);
        final filePath = p.join(savePath, fileName);
        final file = File(filePath);

        int diskBytes = 0;
        bool exists = false;
        if (await file.exists()) {
          exists = true;
          diskBytes = await file.length();
          if (diskBytes > 0 && rawSize > 0 && diskBytes >= rawSize) {
            final raf = await file.open(mode: FileMode.read);
            final probe = await raf.read(math.min(4096, diskBytes));
            final hasContent = probe.any((b) => b != 0);
            await raf.close();
            if (!hasContent) diskBytes = 0;
          }
        }

        final safeDownloaded =
            rawSize > 0 ? diskBytes.clamp(0, rawSize) : 0;

        progress.add(TorrentFileProgress(
          index: i,
          name: fileName,
          size: rawSize,
          downloadedBytes: safeDownloaded,
          progress:
              rawSize > 0 ? (safeDownloaded / rawSize).clamp(0.0, 1.0) : 0.0,
          exists: exists,
          isComplete: rawSize > 0 && safeDownloaded >= rawSize,
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
      // v2.0.0 removed addDhtNode — silently ignore.
      _log.finest('refreshDhtBootstrapNodes skipped (v2.0.0+): $e');
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
  Map<String, dynamic>? getTorrentSnapshot(int id) =>
      TorrentService.getTorrentSnapshot(id);
  @override
  String get nativeVersion => '2.0.0';
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



