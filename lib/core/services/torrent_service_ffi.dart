import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show ValueNotifier, listEquals, visibleForTesting;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

import '../interfaces/i_torrent_native.dart';
import '../interfaces/i_torrent_service.dart';
import 'download_engine.dart';
import 'power_monitor.dart';
import 'torrent/libtorrent_native_impl.dart';
import 'torrent_models.dart';
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

  static ITorrentNative _native = LibtorrentNativeImpl();

  @visibleForTesting
  static void setNativeForTesting(ITorrentNative native) {
    _native = native;
    _state = TorrentSessionLifecycleState.ready;
    isPluginAvailable = true;
    _startTrackingAlerts();
    _startTrackingUpdates();
  }

  static bool get fileProgressSupported => true;
  static bool get filePrioritiesSupported => true;
  static bool get resumeDataSupported => true;
  static bool get forceRecheckSupported => true;
  static bool get trackersSupported => true;
  static bool get createTorrentSupported => true;
  static bool get ipFilterSupported => true;
  static bool get sequentialDownloadSupported => true;
  static bool get superSeedingSupported => true;
  static bool get pieceDeadlineSupported => true;

  static Future<void> forceStopTorrent(int id) async {
    _activeTorrentIds.remove(id);
    _latestProgress.remove(id);
    _latestStats.remove(id);
    _torrentSources.remove(id);
    _cachedPrioritiesSnapshot.remove(id);
    try {
      await _native.pauseTorrent(id, graceful: false);
    } catch (_) {}
  }

  static final Map<int, double> _latestProgress = {};
  static final Map<int, String> _torrentSources = {};
  static final Map<int, List<int>> _cachedPrioritiesSnapshot = {};
  static final Map<int, TorrentUpdateInfo> _latestStats = {};

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

  static Uint8List? resumeBlobFor(int id) {
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
        _configureSessionFromSettings();
        _startTrackingUpdates();
        _startTrackingAlerts();
        _state = TorrentSessionLifecycleState.ready;
        isAvailable.value = true;
      } on TimeoutException {
        _log.severe('libtorrent init timed out');
        _state = TorrentSessionLifecycleState.uninitialized;
        isPluginAvailable = false;
        isAvailable.value = false;
        return;
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

  static bool get sequentialDownloadEnabled => _sequentialDownload;
  static double get shareRatioLimit => _shareRatioLimit;
  static int get maxSeedingTimeMinutes => _maxSeedingTimeMinutes;

  static void configureSession([TorrentSessionSettings? settings]) {
    try {
      final s = settings ?? const TorrentSessionSettings();
      final config = NativeBtConfig(
        disableDht: !s.enableDht,
        disableUpnp: !s.enableUpnp,
        forceEncrypt: s.forceEncrypt,
        connectionsLimit: s.torrentConnectionsLimit,
        downloadRateLimit: s.downloadRateLimitKbps,
        uploadRateLimit: s.uploadRateLimitKbps,
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

  static Completer<void>? _trackingCompleter;

  static void _startTrackingAlerts() {
    _alertsSub?.cancel();
    _alertsSub = _native.alertStream.listen((event) {
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
    if (_trackingCompleter != null) return;
    _trackingCompleter = Completer<void>();
    StreamController<Map<int, TorrentUpdateInfo>>? controller;
    StreamSubscription? sub;
    try {
      controller = StreamController<Map<int, TorrentUpdateInfo>>.broadcast();
      sub = _native.statusStream.listen(
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
              _latestStats.remove(removedId);
              _torrentSources.remove(removedId);
              _cachedPrioritiesSnapshot.remove(removedId);
            }
            final mapped = torrents.map((key, value) {
              _latestProgress[value.id] = value.progress;

              final info = TorrentUpdateInfo(
                id: value.id,
                name: value.name,
                progress: value.progress,
                downloadRate: value.downloadRate,
                uploadRate: value.uploadRate,
                totalDone: value.totalDone,
                totalWanted: value.totalWanted,
                totalWantedDone: value.totalWantedDone,
                hasMetadata: value.hasMetadata,
                stateLabel: value.stateLabel,
                numSeeds: value.numSeeds,
                numPeers: value.numPeers,
                piecesHave: value.piecesDone,
                piecesTotal: value.numPieces,
                downloadPayloadRate: value.downloadRate,
                uploadPayloadRate: value.uploadRate,
                totalPayloadDownload: value.totalDone,
                totalPayloadUpload: value.totalUploaded,
                currentTracker: '',
                nextAnnounceSeconds: 0,
                distributedCopies: 0.0,
                fileProgress: value.fileProgress,
                filePriorities: value.filePriorities,
              );
              _latestStats[value.id] = info;
              return MapEntry(key, info);
            });

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
      _trackingCompleter?.complete();
    } catch (e) {
      sub?.cancel();
      controller?.close();
      if (_trackingCompleter != null && !_trackingCompleter!.isCompleted) {
        _trackingCompleter!.completeError(e);
      }
      _trackingCompleter = null;
    }
  }

  static Uint8List? fetchResumeBytes(int torrentId) => null;

  static Future<void> saveResumeData(int torrentId) async {
    if (_state == TorrentSessionLifecycleState.uninitialized ||
        _state == TorrentSessionLifecycleState.initializing) {
      return;
    }
    try {
      final data = await _native.saveResumeData(torrentId);
      if (data != null && data.isNotEmpty) {
        final source = _torrentSources[torrentId];
        if (source != null) {
          final uint8Data = Uint8List.fromList(data);
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
    await _updatesSub?.cancel();
    _updatesSub = null;
    await _alertsSub?.cancel();
    _alertsSub = null;
    await _updateController?.close();
    _updateController = null;
    _activeTorrentIds.clear();
    _torrentSources.clear();
    _latestProgress.clear();
    _cachedPrioritiesSnapshot.clear();

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

  static int addMagnet(String magnetUri, String savePath) {
    if (!isInitialized) return -1;
    _startTrackingUpdates();
    try {
      final id = _native.addMagnet(magnetUri, savePath);
      if (id >= 0) {
        _activeTorrentIds.add(id);
        _torrentSources[id] = magnetUri;
        unawaited(_tryLoadFastResumeForSource(id, magnetUri));
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
  }) async {
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
          timeout,
        );
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
      final id = _native.addTorrentFile(filePath, savePath);
      if (id >= 0) {
        _activeTorrentIds.add(id);
        _torrentSources[id] = source;
        unawaited(_tryLoadFastResumeForSource(id, source));
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
        final loaded = _native.loadResumeData(id, resumeBytes);
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
    bool deleteResumeData = false,
  }) {
    if (!isInitialized) return;
    if (id >= 0) {
      try {
        _native.removeTorrent(id, deleteFiles: deleteFiles);
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
          await _native.pauseTorrent(id, graceful: true);

          try {
            await torrentUpdates.firstWhere((updateMap) {
              final stats = updateMap[id];
              if (stats == null) return false;
              final label = stats.stateLabel.toLowerCase();
              return label.contains('paused') || label.contains('stopped');
            }).timeout(const Duration(seconds: 2));
          } on TimeoutException {
            _log.warning(
              'Pause verification timed out (2s) for id $id. Native pause was issued; keeping state paused.',
            );
          } catch (e) {
            _log.fine('Pause verification check caught: $e');
          }

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
        _native.resumeTorrent(id);
      } catch (e) {
        _log.warning('resumeTorrent failed for id $id: $e');
      }
    }
  }

  static bool loadResumeData(int id, List<int> data) {
    if (!isInitialized || id < 0) return false;
    return _native.loadResumeData(id, data);
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
              resolvedDownloadedBytes = rawBytes.clamp(0, f.size);
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

  static Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  ) async {
    if (!isInitialized || torrentId < 0) return [];
    try {
      final nativeFiles = _native.getFiles(torrentId);
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

  static void boostMagnetDiscovery(int torrentId) {}

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
  bool get sequentialDownloadEnabled =>
      TorrentService.sequentialDownloadEnabled;
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
  int addMagnet(String magnetUri, String savePath) =>
      TorrentService.addMagnet(magnetUri, savePath);
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
  void removeTorrent(int id,
          {bool deleteFiles = false, bool deleteResumeData = false}) =>
      TorrentService.removeTorrent(id,
          deleteFiles: deleteFiles, deleteResumeData: deleteResumeData);
  @override
  Future<void> pauseTorrent(int id) => TorrentService.pauseTorrent(id);
  @override
  Future<void> forceStopTorrent(int id) => TorrentService.forceStopTorrent(id);
  @override
  void resumeTorrent(int id) => TorrentService.resumeTorrent(id);
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
  Map<String, dynamic>? getTorrentSnapshot(int id) => null;
  @override
  String get nativeVersion => '1.9.2';
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
