import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show ValueNotifier, listEquals, visibleForTesting;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

import '../domain/torrent_models.dart';
import '../interfaces/i_torrent_native.dart';
import '../interfaces/i_torrent_service.dart';
import '../utils/url_utils.dart';
import 'download_engine.dart';
import 'power_monitor.dart';
import 'tick_manager.dart';
import 'torrent/libtorrent_native_impl.dart';
import 'torrent_resume_store.dart';
import 'tracker_manager.dart';

final _log = Logger('TorrentService');

enum TorrentSessionLifecycleState {
  uninitialized,
  initializing,
  ready,
  pausing,
  disposing,
  disposed,
}

class TorrentService {
  static final Lock _libtorrentLock = Lock();
  // FIX-1.3: Lock TorrentService state mutations
  static final Lock _torrentLock = Lock();
  static TorrentSessionLifecycleState _state =
      TorrentSessionLifecycleState.uninitialized;
  static Completer<void>? _initCompleter;
  static Completer<void>? _disposeCompleter;
  static Set<int> _activeTorrentIds = {};
  static StreamSubscription? _updatesSub;
  static StreamSubscription? _alertsSub;
  static StreamController<Map<int, TorrentUpdateInfo>>? _updateController;
  static final StreamController<TorrentAlertEvent> _alertController =
      StreamController<TorrentAlertEvent>.broadcast();
  static Timer? _periodicResumeTimer;

  static ITorrentNative _native = LibtorrentNativeImpl();

  @visibleForTesting
  static void setNativeForTesting(ITorrentNative native) {
    _native = native;
    _state = TorrentSessionLifecycleState.ready;
    isPluginAvailable = true;
    _startTrackingAlerts();
    _startTrackingUpdates();
    _startPeriodicResumeSave();
  }

  static void _startPeriodicResumeSave() {
    _stopPeriodicResumeSave();
    // Nothing to save without the export — the timer would wake every 30s only
    // to have every call report unavailable.
    if (!resumeDataSupported) {
      _log.info(
        'Periodic resume-data save disabled: this native binary has no '
        'lt_save_resume_data export, so torrents will re-check on next launch.',
      );
      return;
    }
    // FIX-02: Consolidate into TickManager
    TickManager.instance.registerTick(
      id: 'torrent_periodic_resume_save',
      interval: const Duration(seconds: 30),
      priority: TickPriority.normal,
      callback: (_) {
        if (isInitialized && _activeTorrentIds.isNotEmpty) {
          saveAllResumeData();
        }
      },
    );
  }

  static void _stopPeriodicResumeSave() {
    TickManager.instance.unregisterTick('torrent_periodic_resume_save');
    _periodicResumeTimer?.cancel();
    _periodicResumeTimer = null;
  }

  // Capability flags, derived from what the loaded binary actually exports
  // rather than asserted. These were hardcoded `true`, which made the app
  // request work the native side could not perform: `resumeDataSupported`
  // sent every graceful pause into a 5s wait for a save_resume_data alert that
  // no export could ever post, three times over, and then force-stopped the
  // torrent — dropping all peers and re-handshaking from scratch. The absent
  // exports are bound as nullable so the calls themselves are safe; these
  // getters exist so callers can skip them instead of timing out to find out.
  static bool get fileProgressSupported => false;
  static bool get filePrioritiesSupported => false;
  static bool get resumeDataSupported => false;
  static bool get forceRecheckSupported => true;
  static bool get trackersSupported => false;
  static bool get reannounceSupported => false;
  // No FFI-bound symbol backs either of these; they are not gated on the ABI.
  static bool get createTorrentSupported => false;
  static bool get ipFilterSupported => false;
  static bool get sequentialDownloadSupported => false;
  static bool get superSeedingSupported => false;
  static bool get pieceDeadlineSupported => false;

  static Future<void> forceStopTorrent(int id) async {
    await _libtorrentLock.synchronized(() async {
      _activeTorrentIds.remove(id);
      _latestProgress.remove(id);
      _latestStats.remove(id);
      _metadataProbeAt.remove(id);
      _torrentSources.remove(id);
      _cachedPrioritiesSnapshot.remove(id);
      _latestResumeBlobs.remove(id);
      try {
        await _native.pauseTorrent(id, graceful: false);
      } catch (_) {}
    });
  }

  static final Map<int, double> _latestProgress = {};
  static final Map<int, String> _torrentSources = {};
  static final Map<int, List<int>> _cachedPrioritiesSnapshot = {};
  static final Map<int, TorrentUpdateInfo> _latestStats = {};
  // getFiles() is synchronous FFI; throttle compatibility metadata probes so
  // they cannot starve Flutter's UI isolate on every status tick.
  static final Map<int, DateTime> _metadataProbeAt = {};

  static DateTime? _lastEmitTime;
  static Map<int, TorrentUpdateInfo>? _pendingUpdate;
  static Timer? _throttleTimer;

  static bool isPluginAvailable = false;
  static final ValueNotifier<bool> isAvailable = ValueNotifier(false);

  static bool get isSupported => true;
  static bool get isInitialized =>
      _state == TorrentSessionLifecycleState.ready && isPluginAvailable;
  static Set<int> get activeTorrentIds => Set.unmodifiable(_activeTorrentIds);
  static Map<int, TorrentUpdateInfo> get latestStats =>
      Map.unmodifiable(_latestStats);

  static Future<void> get ready {
    if (_state == TorrentSessionLifecycleState.ready && isPluginAvailable) {
      return Future.value();
    }
    if (_state == TorrentSessionLifecycleState.initializing &&
        _initCompleter != null) {
      return _initCompleter!.future;
    }
    if (_state == TorrentSessionLifecycleState.uninitialized) {
      return init();
    }
    return Future.error(StateError('TorrentService is in state $_state'));
  }

  static Future<bool> hasResumeData(String source) async {
    if (!isPluginAvailable) return false;
    await _readyOrThrow();
    final bytes = await TorrentResumeStore.loadResumeDataForSource(source);
    return bytes != null && bytes.isNotEmpty;
  }

  static double progressFor(int id) => _latestProgress[id] ?? 0.0;

  static final Map<int, Uint8List> _latestResumeBlobs = {};

  static Uint8List? resumeBlobFor(int id) {
    final cached = _latestResumeBlobs[id];
    if (cached != null && cached.isNotEmpty) return cached;
    return null;
  }

  static int? idForSource(String source) {
    if (source.isEmpty) return null;
    for (final entry in _torrentSources.entries) {
      if (entry.value == source) return entry.key;
    }
    if (source.startsWith('magnet:')) {
      final info = parseMagnetUrl(source);
      final hash = info['infoHash'] ?? info['infoHashV1'];
      if (hash != null && hash.isNotEmpty) {
        for (final entry in _torrentSources.entries) {
          if (entry.value.startsWith('magnet:')) {
            final entryInfo = parseMagnetUrl(entry.value);
            final entryHash = entryInfo['infoHash'] ?? entryInfo['infoHashV1'];
            if (entryHash != null &&
                entryHash.toLowerCase() == hash.toLowerCase()) {
              return entry.key;
            }
          }
        }
      }
    }
    return null;
  }

  static Future<void> _readyOrThrow() async {
    if (_state == TorrentSessionLifecycleState.ready && isPluginAvailable) {
      return;
    }
    await ready;
  }

  static Future<void> init() async {
    if (_state == TorrentSessionLifecycleState.ready) return;
    if (_state == TorrentSessionLifecycleState.initializing &&
        _initCompleter != null) {
      return _initCompleter!.future;
    }
    if (_state == TorrentSessionLifecycleState.pausing ||
        _state == TorrentSessionLifecycleState.disposing) {
      if (_disposeCompleter != null) {
        try {
          await _disposeCompleter!.future;
        } catch (e, st) {
          _log.warning('[torrent_service_ffi] operation failed', e, st);
        }
      }
    }

    _state = TorrentSessionLifecycleState.initializing;
    _initCompleter = Completer<void>();
    try {
      try {
        await _native.init().timeout(const Duration(seconds: 10));
        isPluginAvailable = true;
        _logBridgeHealth();
        _configureSessionFromSettings();
        // Must precede the _startTracking* calls: they bail out unless
        // isInitialized is already true, which requires this state.
        _state = TorrentSessionLifecycleState.ready;
        _startTrackingUpdates();
        _startTrackingAlerts();
        _startPeriodicResumeSave();
        isAvailable.value = true;
      } on TimeoutException {
        _log.severe('libtorrent init timed out');
        _state = TorrentSessionLifecycleState.uninitialized;
        isPluginAvailable = false;
        isAvailable.value = false;
      } catch (nativeErr) {
        _log.warning(
          'Native libtorrent init failed (unsupported platform or native library missing): $nativeErr',
        );
        _state = TorrentSessionLifecycleState.uninitialized;
        isPluginAvailable = false;
        isAvailable.value = false;
      }
      _initCompleter?.complete();
    } catch (e) {
      _state = TorrentSessionLifecycleState.uninitialized;
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

  /// Whether the loaded native bridge lays out `lt_torrent_status` the way the
  /// Dart FFI bindings read it.
  ///
  /// This tracks *struct layout agreement only*. The bindings are pinned to
  /// bridge ABI 1, which is what the bundled `liblibtorrent_flutter` binaries
  /// actually provide, so the normal case is true.
  ///
  /// False means the binary disagrees about the struct — in practice, a binary
  /// newer than the bindings. The failure mode is worse than missing data:
  /// because the bindings read a fixed-size `lt_torrent_status` (see
  /// `kExpectedStatusSize`), a differing layout makes every field past the drift
  /// point decode as unrelated memory — a freshly added torrent can report 100%
  /// progress with zero bytes done and invented transfer rates.
  ///
  /// Callers must not present anything derived from the status struct as fact
  /// while this is false.
  ///
  /// Note what this deliberately does *not* cover: ABI-2-only exports such as
  /// `lt_get_file_progress`, `lt_get_trackers` and the resume-data functions are
  /// absent from the pinned binaries, so per-file progress, tracker management,
  /// swarm counters and fast resume are unavailable. Those cost features, never
  /// correctness, so they are reported through `bridgeDiagnostics` and must not
  /// gate this flag — treating them as incompatibility is what previously
  /// blanked speeds, peers, seeds and downloaded sizes to zero.
  static bool bridgeCompatible = true;

  /// Last bridge health report, or null when the platform has no native bridge.
  static String? bridgeDiagnostics;

  static void _logBridgeHealth() {
    try {
      final report = _native.bridgeDiagnostics;
      bridgeDiagnostics = report;
      bridgeCompatible = _native.isBridgeCompatible;
      if (report == null) return;
      if (bridgeCompatible) {
        _log.info('Native bridge: $report');
      } else {
        _log.severe('Native bridge: $report');
      }
    } catch (e, st) {
      _log.fine('Bridge health probe failed: $e', e, st);
    }
  }

  static bool get sequentialDownloadEnabled => _sequentialDownload;
  static double get shareRatioLimit => _shareRatioLimit;
  static int get maxSeedingTimeMinutes => _maxSeedingTimeMinutes;

  static void configureSession([TorrentSessionSettings? settings]) {
    try {
      final s = settings ?? const TorrentSessionSettings();
      // FIX: [Audit] Standardize FFI boundary to Bytes/sec by multiplying kbps * 1024
      final config = NativeBtConfig(
        disableDht: !s.enableDht,
        disableUpnp: !s.enableUpnp,
        forceEncrypt: s.forceEncrypt,
        connectionsLimit: s.torrentConnectionsLimit,
        downloadRateLimit: s.downloadRateLimitKbps * 1024,
        uploadRateLimit: s.uploadRateLimitKbps * 1024,
      );
      _native.configureSession(config);

      _sequentialDownload = s.sequentialDownload;
      _shareRatioLimit = s.shareRatioLimit;
      _maxSeedingTimeMinutes = s.maxSeedingTimeMinutes;

      for (final id in _activeTorrentIds) {
        _native.setSequentialDownload(id, _sequentialDownload);
      }
    } catch (e) {
      _log.warning('Session configuration failed: $e');
    }
  }

  static void _configureSessionFromSettings() => configureSession();

  static void _startTrackingAlerts() {
    _alertsSub?.cancel();
    _alertsSub = _native.alertStream.listen((event) {
      // FIX: [Audit] Rely on semantic enum TorrentAlertType rather than magic int
      if (event.type == TorrentAlertType.fastresumeRejected ||
          event.alertCode == 19) {
        _log.warning(
          'Fastresume rejected for torrent ${event.torrentId}, triggering integrity recheck',
        );
        try {
          _native.recheckTorrent(event.torrentId);
        } catch (e) {
          _log.warning('Recheck failed after fastresume rejected: $e');
        }
      }
      _alertController.add(TorrentAlertEvent(
        type: event.alertCode,
        torrentId: event.torrentId,
        message: event.message,
        timestamp: event.timestamp,
        category: event.type.name,
      ));
    });
  }

  static void _startTrackingUpdates() {
    if (_state == TorrentSessionLifecycleState.disposed || !isInitialized) {
      return;
    }
    if (_updatesSub != null) return;
    StreamController<Map<int, TorrentUpdateInfo>>? controller;
    StreamSubscription? sub;
    try {
      controller = StreamController<Map<int, TorrentUpdateInfo>>.broadcast();
      sub = _native.statusStream.listen(
        (torrents) async {
          await _torrentLock.synchronized(() async {
            try {
              // FIX-2.3: Throttle torrent stream listener - skip if unchanged
              bool anyChanged = false;
              for (final entry in torrents.entries) {
                final prev = _latestStats[entry.key];
                if (prev == null ||
                    prev.progress != entry.value.progress ||
                    prev.stateLabel != entry.value.stateLabel ||
                    prev.downloadRate != entry.value.downloadRate) {
                  anyChanged = true;
                  break;
                }
              }
              if (!anyChanged && torrents.length == _latestStats.length) return;

              final nativeIds = Set<int>.from(torrents.keys);
              _activeTorrentIds = _activeTorrentIds.union(nativeIds);
              final previousIds = Set<int>.from(_latestProgress.keys);
              // FIX: Do NOT evict an ID just because it was absent from one
              // status batch. The native stream omits quiet/idle torrents from
              // some ticks, which caused isTorrentAlive() to return false and
              // triggered a spurious restart loop (downloads stopped after 2-4 MB,
              // magnet re-added, metadata cleared, repeat).
              // Only evict IDs that have disappeared AND have no cached stats —
              // meaning they were never properly tracked. Active IDs are kept until
              // the aliveness watchdog (with its two-miss guard) declares them gone.
              _activeTorrentIds.retainWhere(
                (id) =>
                    nativeIds.contains(id) ||
                    _latestStats
                        .containsKey(id), // keep while we have any state
              );
              final removedIds = previousIds.difference(_activeTorrentIds);
              for (final removedId in removedIds) {
                _latestProgress.remove(removedId);
                _latestStats.remove(removedId);
                _metadataProbeAt.remove(removedId);
                _torrentSources.remove(removedId);
                _cachedPrioritiesSnapshot.remove(removedId);
              }
              final mapped = torrents.map((key, value) {
                // Some older prebuilt Android bridges reported metadata_received
                // before updating torrent_status.has_metadata. The native file
                // table is authoritative, so use it as a compatibility fallback
                // until the matching rebuilt bridge is installed.
                var hasMetadata = value.hasMetadata;
                var name = value.name;
                var totalWanted = value.totalWanted;
                final lastMetadataProbe = _metadataProbeAt[value.id];
                final shouldProbeMetadata = lastMetadataProbe == null ||
                    DateTime.now().difference(lastMetadataProbe) >=
                        const Duration(seconds: 2);
                if (!hasMetadata && shouldProbeMetadata) {
                  _metadataProbeAt[value.id] = DateTime.now();
                  try {
                    final nativeFiles = _native.getFiles(value.id);
                    if (nativeFiles.isNotEmpty) {
                      hasMetadata = true;
                      if (name.isEmpty) name = nativeFiles.first.name;
                      if (totalWanted <= 0) {
                        totalWanted = nativeFiles.fold<int>(
                          0,
                          (sum, file) => sum + file.size,
                        );
                      }
                    }
                  } catch (_) {}
                }

                _latestProgress[value.id] = value.progress;

                // FIX: [Audit] Populate all FFI fields and map numeric state to enum
                final info = TorrentUpdateInfo(
                  id: value.id,
                  name: name,
                  progress: value.progress,
                  downloadRate: value.downloadRate,
                  uploadRate: value.uploadRate,
                  totalDone: value.totalDone,
                  totalWanted: totalWanted,
                  totalWantedDone: value.totalWantedDone,
                  hasMetadata: hasMetadata,
                  state: stateFromInt(value.state),
                  isPaused: value.isPaused,
                  stateLabel: value.stateLabel,
                  numSeeds: value.numSeeds < 0 ? 0 : value.numSeeds,
                  numPeers: value.numPeers < 0 ? 0 : value.numPeers,
                  numComplete: value.numComplete,
                  numIncomplete: value.numIncomplete,
                  piecesHave: value.piecesDone,
                  piecesTotal: value.numPieces,
                  downloadPayloadRate: value.downloadRate,
                  uploadPayloadRate: value.uploadRate,
                  totalPayloadDownload: value.totalDone,
                  totalPayloadUpload: value.totalUploaded,
                  currentTracker: '',
                  nextAnnounceSeconds: 0,
                  infoHashV1: value.infoHashV1,
                  infoHashV2: value.infoHashV2,
                  distributedCopies: value.distributedCopies,
                  activeTime: value.activeTime,
                  seedingTime: value.seedingTime,
                  fileProgress: value.fileProgress,
                  filePriorities: value.filePriorities,
                  pieces: value.pieces,
                );
                _latestStats[value.id] = info;
                return MapEntry(key, info);
              });

              _pendingUpdate = mapped;
              final now = DateTime.now();
              Duration interval;
              try {
                interval =
                    (PowerMonitor.screenOff || !DownloadEngine.appInForeground)
                        ? const Duration(seconds: 2)
                        : const Duration(milliseconds: 500);
              } catch (_) {
                interval = const Duration(milliseconds: 500);
              }
              if (_lastEmitTime == null ||
                  now.difference(_lastEmitTime!) >= interval) {
                _lastEmitTime = now;
                _throttleTimer?.cancel();
                _throttleTimer = null;
                if (controller != null && !controller.isClosed) {
                  controller.add(Map.unmodifiable(mapped));
                }
              } else {
                _throttleTimer ??= Timer(interval, () {
                  _lastEmitTime = DateTime.now();
                  _throttleTimer = null;
                  if (_pendingUpdate != null &&
                      controller != null &&
                      !controller.isClosed) {
                    controller.add(Map.unmodifiable(_pendingUpdate!));
                  }
                });
              }
            } catch (e, st) {
              _log.warning('Error in torrent updates processing: $e', e, st);
            }
          });
        },
        onError: (Object e, StackTrace st) {
          _log.warning('Native torrent updates stream error: $e', e, st);
          if (controller != null && !controller.isClosed) {
            controller.addError(e, st);
          }
        },
        onDone: () {
          if (controller != null && !controller.isClosed) {
            controller.close();
          }
        },
      );
      _updatesSub = sub;
      _updateController = controller;
    } catch (e) {
      sub?.cancel();
      controller?.close();
      _log.severe('Failed to establish torrent status tracking', e);
    }
  }

  static Uint8List? fetchResumeBytes(int torrentId) => resumeBlobFor(torrentId);

  static Future<void> saveResumeData(int torrentId) async {
    if (_state == TorrentSessionLifecycleState.uninitialized ||
        _state == TorrentSessionLifecycleState.initializing) {
      return;
    }
    try {
      final data = await _native.saveResumeData(torrentId);
      if (data != null && data.isNotEmpty) {
        final uint8Data = Uint8List.fromList(data);
        _latestResumeBlobs[torrentId] = uint8Data;
        final source = _torrentSources[torrentId];
        if (source != null) {
          await TorrentResumeStore.saveAndWait(
            torrentId: torrentId,
            sourceUrl: source,
            fetchResumeData: () => uint8Data,
          );
        }
      }
    } catch (e) {
      _log.warning('saveResumeData failed for torrentId $torrentId: $e');
    }
  }

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
      _native.setDownloadLimit(bytesPerSecond);
    } catch (e) {
      _log.warning('setDownloadLimit failed: $e');
    }
  }

  static void setUploadLimit(int bps) {
    if (!isInitialized) return;
    try {
      _native.setUploadLimit(bps);
    } catch (e) {
      _log.warning('setUploadLimit failed: $e');
    }
  }

  static Future<void> dispose() async {
    if (_state == TorrentSessionLifecycleState.disposed ||
        _state == TorrentSessionLifecycleState.uninitialized) {
      return;
    }

    if (_state == TorrentSessionLifecycleState.initializing &&
        _initCompleter != null) {
      try {
        await _initCompleter!.future;
      } catch (e, st) {
        _log.warning('[torrent_service_ffi] operation failed', e, st);
      }
    }

    if (_disposeCompleter != null) return _disposeCompleter!.future;

    _disposeCompleter = Completer<void>();
    _state = TorrentSessionLifecycleState.pausing;

    try {
      await saveAllResumeData();
    } catch (e) {
      _log.warning('Error saving resume data during dispose: $e');
    }

    _state = TorrentSessionLifecycleState.disposing;
    _stopPeriodicResumeSave();
    await _updatesSub?.cancel();
    _updatesSub = null;
    await _alertsSub?.cancel();
    _alertsSub = null;
    _throttleTimer?.cancel();
    _throttleTimer = null;
    await _updateController?.close();
    _updateController = null;
    _pendingUpdate = null;
    _lastEmitTime = null;
    _activeTorrentIds.clear();
    _torrentSources.clear();
    _latestProgress.clear();
    _latestStats.clear();
    _metadataProbeAt.clear();
    _cachedPrioritiesSnapshot.clear();
    _filesCache.clear();
    _latestResumeBlobs.clear();
    _webSeeds.clear();

    try {
      await _native.dispose();
    } catch (e) {
      _log.warning('Error disposing native torrent engine: $e');
    }
    _state = TorrentSessionLifecycleState.disposed;
    isAvailable.value = false;
    _disposeCompleter?.complete();
    _disposeCompleter = null;
  }

  // FIX-1.3: Lock TorrentService state mutations
  static int addMagnet(String magnetUri, String savePath,
      {List<int>? resumeData}) {
    if (!isInitialized) return -1;
    _startTrackingUpdates();
    try {
      final id = _native.addMagnet(magnetUri, savePath, resumeData: resumeData);
      if (id >= 0) {
        _torrentLock.synchronized(() {
          _activeTorrentIds.add(id);
          _torrentSources[id] = magnetUri;
          if (resumeData != null && resumeData.isNotEmpty) {
            _latestResumeBlobs[id] = Uint8List.fromList(resumeData);
          } else {
            unawaited(_tryLoadFastResumeForSource(id, magnetUri));
          }
        });
      }
      return id;
    } catch (e) {
      _log.warning('addMagnet failed: $e');
      return -1;
    }
  }

  static Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
    List<int>? resumeData,
  }) async {
    final id = addMagnet(magnetUri, savePath, resumeData: resumeData);
    if (id < 0) return -1;

    int attempt = 0;
    while (attempt <= maxRetries) {
      attempt++;
      final stopwatch = Stopwatch()..start();
      final completer = Completer<int>();
      Timer? messageTimer;
      Timer? metadataProbeTimer;
      StreamSubscription? sub;

      void completeIfMetadataReady() {
        if (completer.isCompleted) return;
        try {
          // The native status flag can lag behind metadata_received_alert.
          // getFiles() is an authoritative native-side metadata check and
          // also covers the prebuilt Android bridge's status timing.
          if (_native.getFiles(id).isNotEmpty) {
            messageTimer?.cancel();
            metadataProbeTimer?.cancel();
            sub?.cancel();
            stopwatch.stop();
            completer.complete(id);
          }
        } catch (_) {
          // Metadata is still being resolved; the next probe will retry.
        }
      }

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
          metadataProbeTimer?.cancel();
          sub?.cancel();
          stopwatch.stop();
          if (!completer.isCompleted) completer.complete(id);
        }
      });
      // Poll the native file table as a fallback for status/alert races.
      metadataProbeTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        completeIfMetadataReady();
      });
      completeIfMetadataReady();

      try {
        return await completer.future.timeout(timeout);
      } on TimeoutException {
        messageTimer.cancel();
        metadataProbeTimer.cancel();
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

        // FIX(M6-b): Remove handle on timeout
        try {
          removeTorrent(id, deleteFiles: true);
        } catch (_) {}
        onStatusUpdate
            ?.call('Metadata fetch failed. Try adding trackers manually.');
        throw TimeoutException(
          'Magnet metadata fetch timed out after $maxRetries retries',
          timeout,
        );
      } catch (e) {
        messageTimer.cancel();
        metadataProbeTimer.cancel();
        sub.cancel();
        stopwatch.stop();
        try {
          removeTorrent(id, deleteFiles: true);
        } catch (_) {}
        rethrow;
      }
    }
    return -1;
  }

  // FIX-1.3: Lock TorrentService state mutations
  static int addTorrentFile(
    String filePath,
    String savePath, {
    String? sourceKey,
    List<int>? resumeData,
  }) {
    if (!isInitialized) return -1;
    _startTrackingUpdates();
    try {
      final source = sourceKey ?? filePath;
      final id =
          _native.addTorrentFile(filePath, savePath, resumeData: resumeData);
      if (id >= 0) {
        _torrentLock.synchronized(() {
          _activeTorrentIds.add(id);
          _torrentSources[id] = source;
          if (resumeData != null && resumeData.isNotEmpty) {
            _latestResumeBlobs[id] = Uint8List.fromList(resumeData);
          } else {
            unawaited(_tryLoadFastResumeForSource(id, source));
          }
        });
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
    if (_latestResumeBlobs.containsKey(id)) return;
    try {
      final resumeBytes =
          await TorrentResumeStore.loadResumeDataForSource(source);
      if (resumeBytes != null && resumeBytes.isNotEmpty) {
        if (_latestResumeBlobs.containsKey(id)) return;
        final loaded = _native.loadResumeData(id, resumeBytes);
        if (loaded) {
          _latestResumeBlobs[id] = Uint8List.fromList(resumeBytes);
          _log.fine(
            'Fast-resume data loaded successfully for torrent $id ($source)',
          );
        }
      }
    } catch (e) {
      _log.warning('Failed to load fast-resume for $id: $e');
    }
  }

  // FIX-1.3: Lock TorrentService state mutations
  static void removeTorrent(
    int id, {
    bool deleteFiles = false,
    bool deleteResumeData = false,
  }) {
    if (!isInitialized) return;
    if (id >= 0) {
      _torrentLock.synchronized(() {
        try {
          if (isTorrentAlive(id)) {
            _native.removeTorrent(id, deleteFiles: deleteFiles);
          }
          if (deleteResumeData) {
            unawaited(TorrentResumeStore.delete(id));
            final source = _torrentSources.remove(id);
            if (source != null) {
              unawaited(TorrentResumeStore.deleteResumeDataForSource(source));
            }
          } else {
            _torrentSources.remove(id);
          }
          _latestProgress.remove(id);
          _latestStats.remove(id);
          _metadataProbeAt.remove(id);
          _latestResumeBlobs.remove(id);
          _activeTorrentIds.remove(id);
          _cachedPrioritiesSnapshot.remove(id);
        } catch (e) {
          _log.warning('removeTorrent failed for id $id: $e');
        }
      });
    }
  }

  static Future<void> _saveResumeDataAfterPause(int id) async {
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
      _log.warning('getFiles snapshot failed for id $id: $e');
    }

    try {
      final source = _torrentSources[id];
      if (source != null) {
        final resumeBytes = await _native.saveResumeData(id);
        if (resumeBytes != null && resumeBytes.isNotEmpty) {
          final uint8 = Uint8List.fromList(resumeBytes);
          await TorrentResumeStore.saveAndWait(
            torrentId: id,
            sourceUrl: source,
            fetchResumeData: () => uint8,
            files: torrentFiles,
          );
        }
      }
    } catch (e) {
      _log.warning('saveResumeData failed for id $id: $e');
    }
  }

  /// Returns true if the native torrent handle is currently paused or stopped,
  /// checking both the live [_native.getTorrentStatus] (which reflects the real
  /// libtorrent state immediately) and the cached [_latestStats] label.
  static bool _isTorrentPausedOrStopped(int id) {
    try {
      final nativeStatus = _native.getTorrentStatus(id);
      if (nativeStatus != null && nativeStatus.isPaused) return true;
    } catch (_) {}
    final stats = _latestStats[id];
    if (stats != null) {
      final label = stats.stateLabel.toLowerCase();
      if (label.contains('paused') ||
          label.contains('stopped') ||
          label.contains('pausing')) {
        return true;
      }
    }
    return false;
  }

  static Future<void> pauseTorrent(int id) async {
    if (!isPluginAvailable || !isInitialized || !isTorrentAlive(id)) return;
    if (id >= 0) {
      await _libtorrentLock.synchronized(() async {
        try {
          var confirmed = false;
          for (var attempt = 1; attempt <= 3; attempt++) {
            try {
              await _native.pauseTorrent(id, graceful: attempt < 3);
            } catch (e) {
              _log.fine(
                  'Pause attempt $attempt native call failed for $id: $e');
            }

            // Check immediately via native status before waiting on stream.
            if (_isTorrentPausedOrStopped(id)) {
              confirmed = true;
              break;
            }

            try {
              await torrentUpdates.firstWhere((updateMap) {
                final stats = updateMap[id];
                if (stats == null) return false;
                // Accept any stopped/paused/pausing label.
                final label = stats.stateLabel.toLowerCase();
                return label.contains('paused') ||
                    label.contains('stopped') ||
                    label.contains('pausing');
              }).timeout(const Duration(seconds: 5));
              confirmed = true;
              break;
            } on TimeoutException {
              // One last chance: re-query native status after timeout.
              if (_isTorrentPausedOrStopped(id)) {
                confirmed = true;
                break;
              }
              _log.warning(
                  'Pause attempt $attempt/3 timed out for torrent $id');
            } catch (e) {
              _log.fine('Pause verification check attempt $attempt caught: $e');
            }
          }

          if (!confirmed) {
            _log.severe(
              'Force-stopping torrent $id after 3 failed pause attempts',
            );
            try {
              await _native.pauseTorrent(id, graceful: false);
            } catch (e) {
              _log.severe('Force-pause call failed for torrent $id: $e');
            }
          }

          await _saveResumeDataAfterPause(id);
        } catch (e) {
          _log.warning('pauseTorrent failed for id $id: $e');
        }
      });
    }
  }

  // FIX-1.3: Lock TorrentService state mutations
  static Future<void> resumeTorrent(int id) async {
    if (!isInitialized || !isTorrentAlive(id)) return;
    if (id >= 0) {
      await _torrentLock.synchronized(() async {
        try {
          await _native.resumeTorrent(id);
        } catch (e) {
          _log.warning('resumeTorrent failed for id $id: $e');
        }
      });
    }
  }

  static bool loadResumeData(int id, List<int> data) {
    final uint8 = Uint8List.fromList(data);
    _latestResumeBlobs[id] = uint8;
    if (!isInitialized || id < 0) return true;
    final loaded = _native.loadResumeData(id, data);
    return loaded;
  }

  static bool isTorrentAlive(int id) {
    if (!isInitialized || id < 0) return false;
    try {
      final status = _native.getTorrentStatus(id);
      if (status != null) {
        _activeTorrentIds.add(id);
        return true;
      }
      if (!_activeTorrentIds.contains(id)) return false;
      final stats = _latestStats[id];
      if (stats != null) {
        final label = stats.stateLabel.toLowerCase();
        if (label.contains('paused') || label.contains('stopped')) {
          return true;
        }
      }
      return false;
    } catch (_) {
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
      _metadataProbeAt.remove(id);
      _torrentSources.remove(id);
      _cachedPrioritiesSnapshot.remove(id);
      return false;
    }
  }

  static void recheckTorrent(int id) {
    if (!isInitialized) return;
    if (id >= 0) {
      _native.recheckTorrent(id);
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

    final cached = _cachedPrioritiesSnapshot[id];
    if (cached != null && listEquals(cached, priorities)) {
      return;
    }

    _cachedPrioritiesSnapshot[id] = List.unmodifiable(priorities);
    _native.setFilePriorities(id, priorities);
  }

  static int getFileCount(int id) {
    if (!isInitialized || id < 0) return 0;
    try {
      return _native.getFiles(id).length;
    } catch (e) {
      _log.warning('getFileCount failed for id $id: $e');
      return 0;
    }
  }

  static List<TorrentFileItem> getFiles(int id) {
    if (!isInitialized || !isTorrentAlive(id)) return [];
    if (id >= 0) {
      try {
        final files = _native.getFiles(id);
        final progress = _native.getFileProgress(id);
        final priorities = _native.getFilePriorities(id);

        return List.generate(files.length, (i) {
          final f = files[i];
          int resolvedDownloadedBytes;

          if (i < progress.length) {
            final rawBytes = progress[i];
            if (rawBytes >= 0) {
              // Only clamp against a real size. A zero size means the engine
              // could not report one, and clamping would erase real bytes.
              resolvedDownloadedBytes =
                  f.size > 0 ? rawBytes.clamp(0, f.size) : rawBytes;
            } else {
              resolvedDownloadedBytes = -1;
            }
          } else {
            resolvedDownloadedBytes = -1;
          }

          return TorrentFileItem(
            index: f.index,
            name: f.name,
            size: f.size,
            downloadedBytes: resolvedDownloadedBytes,
            priority: (i < priorities.length) ? priorities[i] : 4,
            selected: (i < priorities.length) ? priorities[i] > 0 : true,
          );
        });
      } catch (e) {
        _log.warning('getFiles failed for id $id: $e');
      }
    }
    return [];
  }

  static NativeTorrentStatus? getTorrentStatus(int id) {
    if (!isInitialized || id < 0) return null;
    try {
      return _native.getTorrentStatus(id);
    } catch (e) {
      _log.warning('getTorrentStatus failed for id $id: $e');
      return null;
    }
  }

  static List<int> getFileProgress(int id) {
    if (!isInitialized || id < 0) return const [];
    try {
      return _native.getFileProgress(id);
    } catch (e) {
      _log.warning('getFileProgress failed for id $id: $e');
      return const [];
    }
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
    if (_state == TorrentSessionLifecycleState.uninitialized ||
        _state == TorrentSessionLifecycleState.initializing) {
      return Stream.fromFuture(ready).asyncExpand((_) {
        _startTrackingUpdates();
        return _updateController?.stream ?? const Stream.empty();
      });
    }
    _startTrackingUpdates();
    return _updateController?.stream ?? const Stream.empty();
  }

  static Stream<TorrentAlertEvent> get alertUpdates => _alertController.stream;

  static List<TorrentAlertEvent> getRecentAlerts([int? torrentId]) => const [];

  static List<TrackerInfo> getTrackers(int torrentId) {
    if (!isInitialized || torrentId < 0) return [];
    return _native
        .getTrackers(torrentId)
        .map((t) => TrackerInfo(
              url: t.url,
              tier: t.tier,
              status: t.status,
              seeds: t.seeds,
              peers: t.peers,
              message: t.message,
            ))
        .toList();
  }

  static void addTracker(int torrentId, String trackerUrl, {int tier = 0}) {
    if (!isInitialized || torrentId < 0) return;
    final lower = trackerUrl.trim().toLowerCase();
    if (!lower.startsWith('http://') &&
        !lower.startsWith('https://') &&
        !lower.startsWith('udp://')) {
      _log.warning(
        'addTracker skipped: invalid scheme for "$trackerUrl"',
      );
      return;
    }
    _native.addTracker(torrentId, trackerUrl, tier: tier);
  }

  static void removeTracker(int torrentId, String trackerUrl) {
    if (!isInitialized || torrentId < 0) return;
    _native.removeTracker(torrentId, trackerUrl);
  }

  static void announceNow(int torrentId) {
    if (!isInitialized || torrentId < 0) return;
    _native.announceNow(torrentId);
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
    return _native.createTorrent(
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
    return _native.loadIpFilter(filePath);
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
    _native.setSequentialDownload(torrentId, enabled);
  }

  static void setPieceDeadline(int torrentId, int pieceIndex, int deadlineMs) {
    if (!isInitialized || torrentId < 0) return;
    _native.setPieceDeadline(torrentId, pieceIndex, deadlineMs);
  }

  static void enableSuperSeeding(int torrentId, bool enabled) {
    if (!isInitialized || torrentId < 0) return;
    _native.setSuperSeeding(torrentId, enabled);
  }

  /// Reads per-file download progress for [torrentId].
  ///
  /// The engine's own per-file byte counter (`lt_get_file_progress`) is the only
  /// exact measure of how much of each file has been downloaded, so it is used
  /// whenever it is available. **On-disk file length is not a substitute:**
  /// libtorrent allocates every file to its full length the moment a torrent is
  /// added — sparsely by default, fully under `storage_mode_allocate` — and
  /// `File.length()` reports the full logical size in both cases. Treating it as
  /// a byte count made a torrent added seconds ago read as ~100% complete.
  ///
  /// When the engine cannot report per-file bytes, disk is used only to tell an
  /// absent file (genuinely 0 bytes) from a present one, and the present one is
  /// reported as unknown — `downloadedBytes: 0` with [TorrentFileProgress
  /// .isEstimated] set — rather than having its allocated length passed off as
  /// downloaded data.
  ///
  /// [knownSizes] maps a file index to a length the caller already trusts
  /// (parsed from the torrent metadata). It is used whenever the engine reports
  /// a size of `0`, which means "unknown" rather than "empty" — without it a
  /// bridge that cannot report sizes would report every file as 100% complete.
  static Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath, {
    Map<int, int>? knownSizes,
  }) async {
    if (!isInitialized || torrentId < 0) return [];
    try {
      final nativeFiles = _native.getFiles(torrentId);
      if (nativeFiles.isEmpty) return [];

      // A bridge that does not match these FFI bindings returns noise from every
      // status/progress call, so do not ask it for byte counts at all.
      List<int> engineBytes = const [];
      if (bridgeCompatible) {
        try {
          engineBytes = _native.getFileProgress(torrentId);
        } catch (e) {
          _log.fine('getFileProgress unavailable for torrent $torrentId: $e');
        }
      }
      final bool engineBytesUsable = engineBytes.length == nativeFiles.length;

      final progress = <TorrentFileProgress>[];
      for (var i = 0; i < nativeFiles.length; i++) {
        final native = nativeFiles[i];
        final resolvedSize = native.size > 0
            ? native.size
            : ((knownSizes?[i] ?? 0) > 0 ? knownSizes![i]! : 0);
        final file = File(p.join(savePath, native.name));
        final exists = await file.exists();

        int downloaded;
        bool estimated;
        if (engineBytesUsable && engineBytes[i] >= 0) {
          downloaded = engineBytes[i];
          estimated = false;
        } else if (!exists) {
          // Nothing allocated yet: this zero is a measurement, not a guess.
          downloaded = 0;
          estimated = false;
        } else {
          downloaded = 0;
          estimated = true;
        }

        final resolved =
            resolvedSize > 0 ? downloaded.clamp(0, resolvedSize) : downloaded;
        progress.add(TorrentFileProgress(
          index: i,
          name: native.name,
          size: resolvedSize,
          downloadedBytes: resolved,
          // With no resolved size there is nothing to measure against, so the
          // file is reported as 0% and incomplete rather than falsely done.
          progress: resolvedSize > 0
              ? (resolved / resolvedSize).clamp(0.0, 1.0)
              : 0.0,
          exists: exists,
          // Completeness must come from a real byte count; an unknown file is
          // never complete.
          isComplete:
              !estimated && resolvedSize > 0 && resolved >= resolvedSize,
          isEstimated: estimated,
        ));
      }
      return progress;
    } catch (e) {
      _log.warning('getAccurateFileProgress failed for torrent $torrentId: $e');
      return [];
    }
  }

  static bool shouldStopSeeding({
    required double progress,
    required int uploadedBytes,
    required int downloadedBytes,
    required double shareRatioLimit,
    required int maxSeedingMinutes,
    DateTime? completedAt,
    Duration? seedingDuration,
    double? customRatioLimit,
    int? customMaxTimeMinutes,
  }) {
    if (progress < 0.999) return false;
    final ratioLimit = customRatioLimit ?? shareRatioLimit;
    if (ratioLimit > 0 && downloadedBytes > 0) {
      final ratio = uploadedBytes / downloadedBytes;
      if (ratio >= ratioLimit) return true;
    }

    final maxMinutes = customMaxTimeMinutes ?? maxSeedingMinutes;
    if (maxMinutes > 0) {
      final duration = seedingDuration ??
          (completedAt != null
              ? DateTime.now().difference(completedAt)
              : Duration.zero);
      if (duration.inMinutes >= maxMinutes) return true;
    }

    return false;
  }

  static final Map<int, Set<String>> _webSeeds = {};

  static void addWebSeed(int torrentId, String url) {
    if (url.trim().isEmpty) return;
    _webSeeds.putIfAbsent(torrentId, () => {}).add(url.trim());
    try {
      _native.addWebSeed(torrentId, url.trim());
    } catch (_) {}
  }

  static void removeWebSeed(int torrentId, String url) {
    _webSeeds[torrentId]?.remove(url.trim());
    try {
      _native.removeWebSeed(torrentId, url.trim());
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
      await _native.setProxy(
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
      await _native.setSslCertificate(
        certPath: certPath,
        privateKeyPath: privateKeyPath,
        dhParamsPath: dhParamsPath,
      );
    } catch (_) {}
  }

  static void reconfigureSession() => _configureSessionFromSettings();

  static bool get seedingEnabled => true;

  static void boostMagnetDiscovery(int torrentId) {
    if (!isInitialized || torrentId < 0) return;
    try {
      _native.announceNow(torrentId);
    } catch (e, st) {
      _log.warning('boostMagnetDiscovery failed for $torrentId: $e', e, st);
    }
  }

  static void autoEnableSequentialForVideo(int torrentId) {
    if (!isInitialized || torrentId < 0) return;
    try {
      final nativeFiles = _native.getFiles(torrentId);
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
        final data = await _native.saveResumeData(id);
        if (data != null && data.isNotEmpty) {
          final uint8 = Uint8List.fromList(data);
          if (TorrentResumeStore.validateResumeData(uint8)) {
            final source = _torrentSources[id];
            if (source != null) {
              await TorrentResumeStore.saveAndWait(
                torrentId: id,
                sourceUrl: source,
                fetchResumeData: () => uint8,
              );
            }
          }
        }
      } catch (e) {
        _log.fine('Auto-save resume data skipped for $id: $e');
      }
    }
  }

  // FIX: [Audit] Expose getPieceProgress from native status for multi-file ratio estimation
  static Future<Map<String, dynamic>?> getPieceProgress(int torrentId) async {
    final st = _native.getTorrentStatus(torrentId);
    if (st == null) return null;
    return {
      'piecesHave': st.piecesDone,
      'piecesTotal': st.numPieces,
      'pieces': st.pieces,
    };
  }

  // FIX: [Audit] Expose getPeers from native bridge
  static Future<List<PeerConnectionQuality>> getPeers(int torrentId) async {
    if (!isInitialized) return const [];
    try {
      return await _native.getPeers(torrentId);
    } catch (_) {
      return const [];
    }
  }

  static void setSequentialDownload(int torrentId, bool enabled) =>
      enableSequentialDownload(torrentId, enabled);

  static void prioritizeFile(int torrentId, int fileIndex, {int priority = 7}) {
    if (!isInitialized || torrentId < 0) return;
    try {
      final current =
          List<int>.from(_cachedPrioritiesSnapshot[torrentId] ?? const []);
      if (fileIndex >= 0 && fileIndex < current.length) {
        current[fileIndex] = priority;
        setFilePriorities(torrentId, current);
      }
    } catch (_) {}
  }

  static void applySettingsPack(TorrentSettingsPack pack) {
    if (!isInitialized) return;
    try {
      _native.configureSession(NativeBtConfig(
        downloadRateLimit: pack.maxDownloadRate ?? 0,
        uploadRateLimit: pack.maxUploadRate ?? 0,
        connectionsLimit: pack.maxConnectionsGlobal ?? 200,
        disableDht: !pack.enableDht,
        disableUpnp: !pack.enableUpnp,
        disableUtp: !pack.enableUtp,
        disableTcp: !pack.enableTcp,
        forceEncrypt: pack.forceEncrypt,
        cacheSize: pack.cacheSize ?? 64 * 1024 * 1024,
      ));
    } catch (_) {}
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
  bool get forceRecheckSupported => TorrentService.forceRecheckSupported;
  @override
  bool get trackersSupported => TorrentService.trackersSupported;
  @override
  bool get createTorrentSupported => TorrentService.createTorrentSupported;
  @override
  bool get ipFilterSupported => TorrentService.ipFilterSupported;
  @override
  bool get sequentialDownloadSupported =>
      TorrentService.sequentialDownloadSupported;
  @override
  bool get superSeedingSupported => TorrentService.superSeedingSupported;
  @override
  bool get pieceDeadlineSupported => TorrentService.pieceDeadlineSupported;
  @override
  bool get sequentialDownloadEnabled =>
      TorrentService.sequentialDownloadEnabled;
  @override
  bool get seedingEnabled => TorrentService.seedingEnabled;
  @override
  double get shareRatioLimit => TorrentService.shareRatioLimit;
  @override
  int get maxSeedingTimeMinutes => TorrentService.maxSeedingTimeMinutes;

  @override
  Future<bool> hasResumeData(String source) =>
      TorrentService.hasResumeData(source);
  @override
  Future<void> init() => TorrentService.init();
  @override
  Future<void> saveResumeData(int torrentId) =>
      TorrentService.saveResumeData(torrentId);
  @override
  Future<void> saveAllResumeData() => TorrentService.saveAllResumeData();
  @override
  Future<void> dispose() => TorrentService.dispose();

  @override
  int addMagnet(String magnetUri, String savePath, {List<int>? resumeData}) =>
      TorrentService.addMagnet(magnetUri, savePath, resumeData: resumeData);
  @override
  Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
    List<int>? resumeData,
  }) =>
      TorrentService.addMagnetWithMetadataTimeout(
        magnetUri,
        savePath,
        timeout: timeout,
        onStatusUpdate: onStatusUpdate,
        maxRetries: maxRetries,
        retryDelay: retryDelay,
        resumeData: resumeData,
      );

  @override
  int addTorrentFile(String filePath, String savePath,
          {String? sourceKey, List<int>? resumeData}) =>
      TorrentService.addTorrentFile(filePath, savePath,
          sourceKey: sourceKey, resumeData: resumeData);

  @override
  void removeTorrent(int id,
          {bool deleteFiles = false, bool deleteResumeData = false}) =>
      TorrentService.removeTorrent(id,
          deleteFiles: deleteFiles, deleteResumeData: deleteResumeData);
  @override
  Future<void> pauseTorrent(int id) => TorrentService.pauseTorrent(id);
  @override
  Future<void> forceStopTorrent(int id) => TorrentService.forceStopTorrent(id);
  @override
  Future<void> resumeTorrent(int id) => TorrentService.resumeTorrent(id);
  @override
  bool loadResumeData(int id, List<int> data) =>
      TorrentService.loadResumeData(id, data);
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
  Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates =>
      TorrentService.torrentUpdates;
  @override
  Map<int, TorrentUpdateInfo> get latestStats => TorrentService.latestStats;
  @override
  int? idForSource(String source) => TorrentService.idForSource(source);
  @override
  Map<String, dynamic>? getTorrentSnapshot(int id) => null;
  @override

  /// Native core version bundled by libtorrent_flutter 2.0.0.
  /// The v2.0.0 release is built against libtorrent core 2.1.1.
  String get nativeVersion => '2.1.1';
  @override
  void configureSession([TorrentSessionSettings? settings]) =>
      TorrentService.configureSession(settings);
  @override
  void reconfigureSession() => TorrentService.reconfigureSession();
  @override
  void autoEnableSequentialForVideo(int torrentId) =>
      TorrentService.autoEnableSequentialForVideo(torrentId);
  @override
  Future<void> autoSaveResumeData() => TorrentService.autoSaveResumeData();

  @override
  List<TrackerInfo> getTrackers(int torrentId) =>
      TorrentService.getTrackers(torrentId);
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
  Future<bool> loadIpFilter(String filePath) =>
      TorrentService.loadIpFilter(filePath);
  @override
  Future<bool> downloadAndApplyBlocklist(String url) =>
      TorrentService.downloadAndApplyBlocklist(url);

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
  Stream<TorrentAlertEvent> get alertUpdates => TorrentService.alertUpdates;
  @override
  List<TorrentAlertEvent> getRecentAlerts([int? torrentId]) => const [];
  @override
  void applySettingsPack(TorrentSettingsPack pack) {}

  @override
  Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath, {
    Map<int, int>? knownSizes,
  }) =>
      TorrentService.getAccurateFileProgress(torrentId, savePath,
          knownSizes: knownSizes);

  @override
  Future<Map<String, dynamic>?> getPieceProgress(int torrentId) =>
      TorrentService.getPieceProgress(torrentId);

  @override
  Future<List<PeerConnectionQuality>> getPeers(int torrentId) =>
      TorrentService.getPeers(torrentId);

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
  void addWebSeed(int torrentId, String url) =>
      TorrentService.addWebSeed(torrentId, url);
  @override
  void removeWebSeed(int torrentId, String url) =>
      TorrentService.removeWebSeed(torrentId, url);
  @override
  List<String> getWebSeeds(int torrentId) =>
      TorrentService.getWebSeeds(torrentId);

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
  bool get seedingEnabled => true;
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
  int addMagnet(String magnetUri, String savePath, {List<int>? resumeData}) =>
      -1;
  @override
  Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
    List<int>? resumeData,
  }) async =>
      -1;
  @override
  int addTorrentFile(String filePath, String savePath,
          {String? sourceKey, List<int>? resumeData}) =>
      -1;

  @override
  void removeTorrent(int id,
      {bool deleteFiles = false, bool deleteResumeData = false}) {}
  @override
  Future<void> pauseTorrent(int id) async {}
  @override
  Future<void> forceStopTorrent(int id) async {}
  @override
  Future<void> resumeTorrent(int id) async {}
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
  int? idForSource(String source) => null;
  @override
  Map<String, dynamic>? getTorrentSnapshot(int id) => null;
  @override
  String get nativeVersion => 'stub';
  @override
  void configureSession([TorrentSessionSettings? settings]) {}
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
    String savePath, {
    Map<int, int>? knownSizes,
  }) async =>
      [];

  @override
  Future<Map<String, dynamic>?> getPieceProgress(int torrentId) async => null;

  @override
  Future<List<PeerConnectionQuality>> getPeers(int torrentId) async => const [];

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
