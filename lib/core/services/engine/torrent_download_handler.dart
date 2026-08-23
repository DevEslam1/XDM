import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../di/injection.dart';
import '../../domain/torrent_file_progress_estimator.dart';
import '../../interfaces/i_connectivity.dart';
import '../../interfaces/i_torrent_service.dart';
import '../download_engine.dart';
import '../logging_service.dart';
import '../power_monitor.dart';
import '../torrent_resume_store.dart';
import '../torrent_service.dart';
import 'torrent_file_normalizer.dart';
import 'torrent_watchdog_manager.dart';

final _log = LoggingService.logger('TorrentDownloadHandler');

@immutable
class TorrentFileSnapshot {
  final List<Map<String, dynamic>> files;
  final int hash;

  // FIX(C5): Defensive-copy at construction to maintain immutability and contract
  TorrentFileSnapshot(List<Map<String, dynamic>> source)
      : files = List.unmodifiable(
          source.map((f) => Map<String, dynamic>.of(f)),
        ),
        hash = computeHash(source);

  static int computeHash(List<Map<String, dynamic>>? files) {
    if (files == null || files.isEmpty) return 0;
    var h = files.length;
    for (final f in files) {
      h ^= Object.hash(
        f['name'],
        f['length'],
        f['downloadedBytes'],
        f['selected'],
        f['priority'],
        f['isComplete'],
      );
    }
    return h;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TorrentFileSnapshot &&
          hash == other.hash &&
          !TorrentDownloadHandler._torrentFileListsDiffer(files, other.files);

  @override
  int get hashCode => hash;
}

class TorrentSubscriptionRegistry {
  TorrentSubscriptionRegistry._();
  static final TorrentSubscriptionRegistry instance =
      TorrentSubscriptionRegistry._();
  final Map<int, _TorrentSubEntry> _registry = {};

  // FIX(M1, H1): Single ownership of subscriptions and notify previous handler
  void register(
      int torrentId, TorrentDownloadHandler handler, StreamSubscription sub) {
    final existing = _registry.remove(torrentId);
    if (existing != null) {
      try {
        existing.subscription.cancel();
      } catch (e, st) {
        _log.fine('Failed to cancel existing subscription: $e', e, st);
      }
      if (!identical(existing.handler, handler)) {
        try {
          existing.handler.removeActiveTorrent(torrentId);
        } catch (e, st) {
          _log.fine('Failed to notify old handler on re-registration: $e', e, st);
        }
      }
    }
    _registry[torrentId] = _TorrentSubEntry(
      handler: handler,
      subscription: sub,
    );
  }

  StreamSubscription? getSubscription(int torrentId) {
    final entry = _registry[torrentId];
    return entry?.subscription;
  }

  void unregister(int torrentId, TorrentDownloadHandler handler) {
    final entry = _registry[torrentId];
    if (entry != null && identical(entry.handler, handler)) {
      _registry.remove(torrentId);
    }
  }

  void unregisterAll(TorrentDownloadHandler handler) {
    _registry.removeWhere((id, entry) {
      if (identical(entry.handler, handler)) {
        try {
          entry.subscription.cancel();
        } catch (_) {}
        return true;
      }
      return false;
    });
  }

  Map<int, StreamSubscription> subsForHandler(TorrentDownloadHandler handler) {
    final map = <int, StreamSubscription>{};
    for (final entry in _registry.entries) {
      if (identical(entry.value.handler, handler)) {
        map[entry.key] = entry.value.subscription;
      }
    }
    return map;
  }

  Future<void> disposeAsync(int torrentId) async {
    final entry = _registry.remove(torrentId);
    if (entry == null) return;
    try {
      await entry.subscription.cancel();
    } catch (e, st) {
      _log.fine('Failed to cancel disposed subscription: $e', e, st);
    }
    try {
      await entry.handler
          .haltTorrent(torrentId)
          .timeout(const Duration(seconds: 4));
    } catch (e, st) {
      _log.warning('Failed to halt torrent $torrentId on dispose', e, st);
    }
  }

  void dispose(int torrentId) {
    final entry = _registry.remove(torrentId);
    if (entry == null) return;
    try {
      entry.subscription.cancel();
    } catch (e, st) {
      _log.fine('Failed to cancel disposed subscription: $e', e, st);
    }
    unawaited(entry.handler
        .haltTorrent(torrentId)
        .timeout(const Duration(seconds: 4))
        .catchError((e, st) {
      _log.warning('Failed to halt torrent $torrentId on dispose', e, st);
    }));
  }

  @visibleForTesting
  void clear() {
    for (final entry in _registry.values) {
      try {
        entry.subscription.cancel();
      } catch (e, st) {
        _log.fine('Failed to cancel registry subscription: $e', e, st);
      }
    }
    _registry.clear();
  }

  @visibleForTesting
  int get activeCountForTesting => _registry.length;

  @visibleForTesting
  Map<int, StreamSubscription> get subsMapForTesting {
    return _registry.map((k, v) => MapEntry(k, v.subscription));
  }
}

class _TorrentSubEntry {
  final TorrentDownloadHandler handler;
  final StreamSubscription subscription;
  _TorrentSubEntry({required this.handler, required this.subscription});
}

// FIX(C1, C4): Per-torrent runtime object preventing shared state corruption and hanging completers
class TorrentRuntime {
  TorrentWatchdogManager? watchdogManager;
  Timer? get stallWatchdog => watchdogManager?.stallTimer;
  Timer? get alivenessWatchdog => watchdogManager?.alivenessTimer;
  DateTime lastProgressTick = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime lastAccurateSync = DateTime.fromMillisecondsSinceEpoch(0);
  List<Map<String, dynamic>>? cachedAccurateFiles;
  String lastStateLabel = '';
  Completer<void>? completionGuard;
  Completer<void>? pauseCompleter;
  int lastPiecesHave = -1;
  int lastSnapshotHash = 0;
  bool corruptSizeLogged = false;

  /// Last byte count the engine reported outside a checking phase. While
  /// libtorrent is checking files, `progress`/`totalWantedDone` describe
  /// verification, not download, so this value is reported instead of letting
  /// a verification percentage surface as download progress.
  int lastConfirmedDownloadedBytes = 0;

  /// Bytes the resume store claimed at add-time, used to detect a native
  /// binary that silently dropped the add-time resume blob.
  int resumeExpectedBytes = 0;

  /// Set once the add-time-resume recovery recheck has been issued, so it
  /// never fires more than once per handle.
  bool resumeRecheckIssued = false;

  /// Set once the stale-native-bridge warning has been logged for this handle,
  /// so an incompatible binary does not flood the log on every status tick.
  bool bridgeMismatchLogged = false;

  bool _closed = false;
  bool get isClosed => _closed;

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      watchdogManager?.stop();
    } catch (_) {}
    cachedAccurateFiles = null;
    lastStateLabel = '';
    final err = StateError('Torrent runtime closed');
    if (completionGuard != null && !completionGuard!.isCompleted) {
      completionGuard!.future.catchError((_) {});
      completionGuard!.completeError(err);
    }
    if (pauseCompleter != null && !pauseCompleter!.isCompleted) {
      pauseCompleter!.future.catchError((_) {});
      pauseCompleter!.completeError(err);
    }
  }
}

class TorrentDownloadHandler {
  final ITorrentService _torrentService;
  final Set<int> _activeTorrentIds = {};
  final Map<int, TorrentRuntime> _runtime = {};

  TorrentRuntime _getRuntime(int id) =>
      _runtime.putIfAbsent(id, TorrentRuntime.new);

  @visibleForTesting
  Map<int, StreamSubscription> get activeSubsForTesting =>
      TorrentSubscriptionRegistry.instance.subsForHandler(this);
  @visibleForTesting
  static Map<int, StreamSubscription> get globalActiveSubsForTesting =>
      TorrentSubscriptionRegistry.instance.subsMapForTesting;
  @visibleForTesting
  Timer? get stallWatchdogForTesting =>
      _runtime.values.map((r) => r.stallWatchdog).whereType<Timer>().firstOrNull;
  @visibleForTesting
  Timer? get alivenessWatchdogForTesting =>
      _runtime.values.map((r) => r.alivenessWatchdog).whereType<Timer>().firstOrNull;
  @visibleForTesting
  Completer<void>? get completionGuardForTesting =>
      _runtime.values.map((r) => r.completionGuard).whereType<Completer<void>>().firstOrNull;
  @visibleForTesting
  Completer<void>? get pauseCompleterForTesting =>
      _runtime.values.map((r) => r.pauseCompleter).whereType<Completer<void>>().firstOrNull;

  @visibleForTesting
  TorrentRuntime? getRuntimeForTesting(int id) => _runtime[id];

  @visibleForTesting
  TorrentRuntime? runtimeFor(int id) => _runtime[id];

  @visibleForTesting
  DateTime get lastProgressTick =>
      (_runtime.values.firstOrNull ?? _defaultRuntime).lastProgressTick;
  @visibleForTesting
  set lastProgressTick(DateTime v) =>
      (_runtime.values.firstOrNull ?? _defaultRuntime).lastProgressTick = v;

  @visibleForTesting
  DateTime get lastAccurateSync =>
      (_runtime.values.firstOrNull ?? _defaultRuntime).lastAccurateSync;
  @visibleForTesting
  set lastAccurateSync(DateTime v) =>
      (_runtime.values.firstOrNull ?? _defaultRuntime).lastAccurateSync = v;

  @visibleForTesting
  List<Map<String, dynamic>>? get cachedAccurateFiles =>
      (_runtime.values.firstOrNull ?? _defaultRuntime).cachedAccurateFiles;
  @visibleForTesting
  set cachedAccurateFiles(List<Map<String, dynamic>>? v) =>
      (_runtime.values.firstOrNull ?? _defaultRuntime).cachedAccurateFiles = v;

  @visibleForTesting
  String get lastStateLabel =>
      (_runtime.values.firstOrNull ?? _defaultRuntime).lastStateLabel;
  @visibleForTesting
  set lastStateLabel(String v) =>
      (_runtime.values.firstOrNull ?? _defaultRuntime).lastStateLabel = v;

  TorrentRuntime get _defaultRuntime =>
      _runtime.putIfAbsent(-1, TorrentRuntime.new);

  static const int _bencodeDictPrefix = 0x64; // 'd'

  void _safeRemoveTorrent(int id) {
    if (id < 0) return;
    try {
      if (_torrentService.isTorrentAlive(id)) {
        _torrentService.removeTorrent(id, deleteFiles: false);
      }
    } catch (e, st) {
      _log.fine('Failed to remove torrent $id: $e', e, st);
    }
  }

  TorrentDownloadHandler({ITorrentService? torrentService})
      : _torrentService = torrentService ??
            (getIt.isRegistered<ITorrentService>()
                ? getIt<ITorrentService>()
                : TorrentServiceImpl());

  @visibleForTesting
  static PauseReason inferPauseReasonForTesting([PauseReason? reason]) =>
      _inferPauseReason(reason);

  // FIX(A1): Resolve connectivity via IConnectivity interface (Dependency Inversion)
  static PauseReason _inferPauseReason([PauseReason? reason]) {
    if (reason != null) return reason;
    try {
      if (getIt.isRegistered<IConnectivity>()) {
        final connectivity = getIt<IConnectivity>();
        if (!connectivity.hasConnection) {
          return PauseReason.networkLost;
        }
      }
    } catch (e, st) {
      _log.fine('IConnectivity check in pause inference failed: $e', e, st);
    }
    try {
      if (PowerMonitor.batterySaverMode == BatterySaverMode.aggressive ||
          PowerMonitor.batterySaverMode == BatterySaverMode.moderate) {
        return PauseReason.batterySaver;
      }
      if (PowerMonitor.screenOff) {
        return PauseReason.background;
      }
    } catch (e, st) {
      _log.fine('PowerMonitor check in pause inference failed: $e', e, st);
    }
    return PauseReason.userRequested;
  }

  Set<int> get activeTorrentIds => Set.unmodifiable(_activeTorrentIds);

  // FIX(C1, C4): removeActiveTorrent cleans up and closes the specified torrent's runtime
  void removeActiveTorrent(int id) {
    final rt = _runtime.remove(id);
    rt?.close();
    final def = _runtime.remove(-1);
    def?.close();
    _activeTorrentIds.remove(id);
    TorrentSubscriptionRegistry.instance.unregister(id, this);
  }

  // FIX(C1, C4, M1): dispose cleans up all runtimes and unregisters from registry
  void dispose() {
    for (final rt in _runtime.values) {
      rt.close();
    }
    _defaultRuntime.close();
    _runtime.clear();
    _activeTorrentIds.clear();
    TorrentSubscriptionRegistry.instance.unregisterAll(this);
  }

  // FIX(C3, C4): Single shared deadline and reliable fallback cleanup
  Future<void> haltTorrent(int id,
      {Duration budget = const Duration(seconds: 4)}) async {
    TorrentSubscriptionRegistry.instance.unregister(id, this);
    final rt = _runtime.remove(id);
    rt?.close();

    if (!_torrentService.isTorrentAlive(id)) {
      _activeTorrentIds.remove(id);
      return;
    }

    // A torrent without metadata cannot reliably transition to "paused" via the
    // graceful path (libtorrent stays in downloading_metadata). Skip straight to
    // forceStopTorrent to avoid burning the entire budget on guaranteed timeouts.
    final hasMetadata =
        _torrentService.latestStats[id]?.hasMetadata ?? false;
    if (!hasMetadata) {
      _log.fine(
          'haltTorrent $id: no metadata — skipping graceful pause, forcing stop.');
      try {
        await _torrentService.forceStopTorrent(id);
      } catch (e, st) {
        _log.warning('forceStopTorrent (no-metadata) failed for $id', e, st);
        _safeRemoveTorrent(id);
      }
      _activeTorrentIds.remove(id);
      return;
    }

    final deadline = DateTime.now().add(budget);
    var pauseAttempts = 0;
    while (DateTime.now().isBefore(deadline) && pauseAttempts < 3) {
      try {
        await _torrentService.pauseTorrent(id);
      } catch (e, st) {
        _log.warning('haltTorrent pause failed for $id', e, st);
      }
      pauseAttempts++;
      final attemptDeadline =
          DateTime.now().add(const Duration(milliseconds: 600));
      final checkDeadline =
          attemptDeadline.isBefore(deadline) ? attemptDeadline : deadline;
      if (await _isTransmissionStopped(id, deadline: checkDeadline)) {
        _log.info('haltTorrent confirmed pause for $id');
        _activeTorrentIds.remove(id);
        return;
      }
      if (deadline.difference(DateTime.now()) >
          const Duration(milliseconds: 100)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    _log.warning('haltTorrent failed graceful pause for $id within budget — forcing stop');
    try {
      await _torrentService.forceStopTorrent(id);
    } catch (e, st) {
      _log.severe('forceStopTorrent failed for $id', e, st);
      _safeRemoveTorrent(id);
    }
    _activeTorrentIds.remove(id);
  }

  // FIX(C6, H2): Cap resume-save at hard 8-second budget; fall back to degraded snapshot if native resume unsupported
  Future<void> _saveResumeDataBeforePause(int id, String sourceUrl) async {
    // If the torrent has no metadata yet, libtorrent has nothing to serialize.
    // Skip the native save entirely to avoid spurious timeouts and CRITICAL logs.
    final cachedBlob = _torrentService.resumeBlobFor(id);
    final hasMetadata =
        (_torrentService.latestStats[id]?.hasMetadata ?? false) ||
        (cachedBlob != null && cachedBlob.isNotEmpty) ||
        (_torrentService.getFiles(id).isNotEmpty);
    if (!hasMetadata && (cachedBlob == null || cachedBlob.isEmpty)) {
      _log.fine(
          'Skipping saveResumeData for torrent $id — no metadata yet, nothing to save.');
      return;
    }
    if (cachedBlob != null && cachedBlob.isNotEmpty) {
      _log.fine(
          'saveResumeData for $id: reusing cached blob (${cachedBlob.length} bytes).');
      try {
        await TorrentResumeStore.saveAndWait(
          torrentId: id,
          sourceUrl: sourceUrl,
          fetchResumeData: () async => cachedBlob,
        ).timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            _log.warning(
                'saveAndWait with cached blob timed out for torrent $id');
            return false;
          },
        );
      } catch (e, st) {
        _log.warning(
            'saveAndWait with cached blob failed for torrent $id: $e', e, st);
      }
      return;
    }

    final deadline = DateTime.now().add(const Duration(seconds: 8));
    var savedSuccessfully = false;

    Duration remainingBudget() {
      final rem = deadline.difference(DateTime.now());
      return rem.isNegative ? Duration.zero : rem;
    }

    if (_torrentService.resumeDataSupported) {
      for (var attempt = 0; attempt < 3; attempt++) {
        final budget = remainingBudget();
        if (budget <= Duration.zero) break;

        final timeout = budget < const Duration(seconds: 2)
            ? budget
            : const Duration(seconds: 2);

        try {
          await _torrentService.saveResumeData(id).timeout(
                timeout,
                onTimeout: () => _log.warning(
                    'saveResumeData timed out for torrent $id (attempt ${attempt + 1})'),
              );
          final blob = _torrentService.resumeBlobFor(id);
          if (blob != null && blob.isNotEmpty) {
            savedSuccessfully = true;
            break;
          }
        } catch (e, st) {
          _log.warning(
              'saveResumeData error for torrent $id (attempt ${attempt + 1}): $e',
              e,
              st);
        }

        if (attempt < 2 && remainingBudget() > const Duration(milliseconds: 500)) {
          await Future.delayed(Duration(milliseconds: 500 * (1 << attempt)));
        }
      }
    }

    if (!savedSuccessfully && remainingBudget() > Duration.zero) {
      bool degradedSuccess = false;
      try {
        final files = _torrentService.getFiles(id);
        // A file list whose every length is 0 carries no usable metadata (the
        // engine could not report sizes). Persisting it would overwrite the
        // real lengths already in the resume store, so omit it entirely.
        final hasUsableLengths = files.any((f) => f.size > 0);
        final torrentFiles = files.isNotEmpty && hasUsableLengths
            ? files
                .map((f) => {
                      'name': f.name,
                      'length': f.size,
                      'lengthKnown': f.size > 0,
                      'priority': f.priority,
                      'selected': f.selected,
                      'downloadedBytes': f.safeDownloadedBytes,
                    })
                .toList()
            : null;

        List<bool>? pieceBitfield;
        try {
          final pieceProgress = await _torrentService.getPieceProgress(id);
          if (pieceProgress != null && pieceProgress.isNotEmpty) {
            final rawPieces = pieceProgress['pieces'];
            if (rawPieces is List) {
              pieceBitfield = rawPieces
                  .map((p) => p == true || p == 1 || (p is num && p >= 1.0))
                  .toList();
            }
          }
        } catch (e) {
          _log.fine(
              'Could not extract piece progress for fallback snapshot: $e');
        }

        final fallbackBudget = remainingBudget();
        if (fallbackBudget > Duration.zero) {
          degradedSuccess = await TorrentResumeStore.saveAndWait(
            torrentId: id,
            sourceUrl: sourceUrl,
            fetchResumeData: () async {
              final blob = _torrentService.resumeBlobFor(id);
              if (blob != null && blob.isNotEmpty) return blob;
              return null;
            },
            files: torrentFiles,
            pieceBitfield: pieceBitfield,
            degradedFallback: true,
          ).timeout(
            fallbackBudget,
            onTimeout: () {
              _log.warning('Fallback saveAndWait timed out for torrent $id');
              return false;
            },
          );
        }
      } catch (e2, st2) {
        _log.warning('Fallback resume save also failed for $id: $e2', e2, st2);
      }

      if (degradedSuccess) {
        _log.warning(
          'Primary saveResumeData failed for torrent $id; degraded snapshot saved successfully.',
        );
      } else {
        _log.severe(
          'CRITICAL: saveResumeData failed for torrent $id after retries. '
          'Torrent may restart from scratch on next launch.',
        );
      }
    }
  }

  // FIX(C3): Only paused/stopped/pausing and !isTorrentAlive count as stopped
  Future<bool> _isTransmissionStopped(int id, {DateTime? deadline}) async {
    final effectiveDeadline =
        deadline ?? DateTime.now().add(const Duration(seconds: 2));
    var delayMs = 100;
    while (DateTime.now().isBefore(effectiveDeadline)) {
      if (!_torrentService.isTorrentAlive(id)) return true;
      final stats = _torrentService.latestStats[id];
      if (stats != null) {
        final label = stats.stateLabel.toLowerCase();
        if (label.contains('paused') ||
            label.contains('stopped') ||
            label.contains('pausing')) {
          return true;
        }
      }
      await Future.delayed(Duration(milliseconds: delayMs));
      delayMs = (delayMs * 2).clamp(100, 400);
    }
    return false;
  }

  @visibleForTesting
  static Duration computeAdaptiveSyncInterval(int fileCount,
      {bool inBackground = false}) {
    if (inBackground) {
      if (fileCount > 5000) return const Duration(minutes: 5);
      if (fileCount > 1000) return const Duration(minutes: 3);
      return const Duration(seconds: 90);
    }
    if (fileCount > 10000) return const Duration(seconds: 120);
    if (fileCount > 5000) return const Duration(seconds: 45);
    if (fileCount > 1000) return const Duration(seconds: 30);
    if (fileCount > 100) return const Duration(seconds: 15);
    return const Duration(seconds: 5);
  }

  @visibleForTesting
  static bool shouldSkipPerFileSync(int fileCount,
      {bool inBackground = false}) {
    if (inBackground && fileCount > 5000) return true;
    return false;
  }

  static bool _torrentFileListsDiffer(
    List<Map<String, dynamic>>? a,
    List<Map<String, dynamic>>? b,
  ) {
    if (a == null && b == null) return false;
    if (a == null || b == null) return true;
    if (a.length != b.length) return true;
    for (int i = 0; i < a.length; i++) {
      final am = a[i];
      final bm = b[i];
      if (am['name'] != bm['name'] ||
          am['length'] != bm['length'] ||
          am['downloadedBytes'] != bm['downloadedBytes'] ||
          am['selected'] != bm['selected'] ||
          am['priority'] != bm['priority'] ||
          am['isComplete'] != bm['isComplete']) {
        return true;
      }
    }
    return false;
  }

  static Map<String, dynamic> normalizeTorrentFile(Map<String, dynamic> f) =>
      TorrentFileNormalizer.normalizeTorrentFile(f);

  static bool isTorrentFileSelected(Map<String, dynamic> f) =>
      TorrentFileNormalizer.isTorrentFileSelected(f);

  static ({int total, int done, int bytes, int downloaded})
      normalizeTorrentFiles(List<Map<String, dynamic>>? files) {
    final result = TorrentFileNormalizer.normalizeTorrentFileList(files);
    return (
      total: result.total,
      done: result.done,
      bytes: result.bytes,
      downloaded: result.downloaded,
    );
  }

  // FIX(A3): Pure domain delegation
  static void updateFilesWithNativeProgress(
    List<Map<String, dynamic>> files,
    double progress,
    int totalDownloadedBytes,
  ) {
    TorrentFileProgressEstimator.updateFilesWithNativeProgress(
      files,
      progress,
      totalDownloadedBytes,
      sequential: false,
    );
  }

  static void distributeEstimatedBytesSequential(
      List<Map<String, dynamic>> files, int totalDownloadedBytes) {
    TorrentFileProgressEstimator.distributeEstimatedBytesSequential(
      files,
      totalDownloadedBytes,
    );
  }

  static void distributeEstimatedBytes(
      List<Map<String, dynamic>> files, int totalDownloadedBytes) {
    TorrentFileProgressEstimator.distributeEstimatedBytes(
      files,
      totalDownloadedBytes,
    );
  }

  // FIX(M2): Unified DownloadProgress builder
  DownloadProgress _torrentProgress({
    required CycleState cycleState,
    required String statusMessage,
    required ({int total, int done, int bytes, int downloaded}) summary,
    List<Map<String, dynamic>>? files,
    int? torrentId,
    int knownFileSize = 0,
    double speed = 0.0,
    int? eta,
    PauseReason? pauseReason,
    bool supportsResume = true,
  }) {
    return DownloadProgress(
      downloadedBytes: summary.downloaded,
      fileSize: summary.bytes > 0 ? summary.bytes : knownFileSize,
      speed: speed,
      eta: eta,
      supportsResume: supportsResume,
      torrentFiles: files,
      statusMessage: statusMessage,
      cycleState: cycleState,
      pauseReason: pauseReason,
      torrentId: torrentId,
      totalFiles: summary.total > 0 ? summary.total : null,
      completedFiles: summary.total > 0 ? summary.done : null,
      totalFileBytes: summary.bytes > 0 ? summary.bytes : null,
      downloadedFileBytes: summary.bytes > 0 ? summary.downloaded : null,
    );
  }

  Future<void> handleTorrentDownload({
    required String taskId,
    required String url,
    required String currentLocalFilePath,
    required int knownFileSize,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    required Dio Function(String url) clientBuilder,
    required void Function(Dio client) clientReleaser,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool isRetry = false,
    PauseReason? pauseReason,
  }) async {
    final initFiles = getTorrentFiles?.call();
    final initSummary = normalizeTorrentFiles(initFiles);
    final saveDir = File(currentLocalFilePath).parent.path;

    onProgress(_torrentProgress(
      cycleState: isRetry
          ? CycleState.retrying
          : (initSummary.downloaded > 0
              ? CycleState.resuming
              : CycleState.starting),
      statusMessage: isRetry
          ? 'Retrying torrent…'
          : (initSummary.downloaded > 0
              ? 'Resuming torrent…'
              : 'Starting torrent…'),
      summary: initSummary,
      files: initFiles,
      torrentId: torrentId,
      knownFileSize: knownFileSize,
    ));

    int id = torrentId ?? -1;
    bool hasLoadedResume = false;

    // FIX(C4): Use _torrentService instead of TorrentService
    if (id >= 0 && !_torrentService.isTorrentAlive(id)) {
      _log.warning('Stale torrent handle $id detected; re-adding.');
      try {
        TorrentSubscriptionRegistry.instance.dispose(id);
      } catch (e) {
        _log.fine('Failed to dispose subscription registry for stale $id: $e');
      }
      _safeRemoveTorrent(id);
      try {
        TorrentResumeStore.unregisterTorrent(id);
      } catch (e) {
        _log.fine('Failed to unregister source for stale $id: $e');
      }
      _activeTorrentIds.remove(id);
      final rt = _runtime.remove(id);
      rt?.close();
      id = -1;
    }

    if (id == -1) {
      try {
        final dir = Directory(saveDir);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }

        Uint8List? preloadedResume;
        List<Map<String, dynamic>>? preloadedFiles;
        try {
          // FIX(C4): Use _torrentService.hasResumeData
          if (await _torrentService.hasResumeData(url)) {
            preloadedResume =
                await TorrentResumeStore.loadResumeDataForSource(url);
            if (preloadedResume != null) {
              preloadedFiles = await TorrentResumeStore.loadFilesForSource(url);
            }
          }
        } catch (e, st) {
          _log.fine('Preload resume data failed: $e', e, st);
        }

        if (url.startsWith('magnet:')) {
          onProgress(_torrentProgress(
            cycleState: CycleState.fetchingMetadata,
            statusMessage: 'Fetching metadata…',
            summary: initSummary,
            files: initFiles,
            torrentId: torrentId,
            knownFileSize: knownFileSize,
          ));
          try {
            if (cancelToken.isCancelled) {
              throw DioException(
                requestOptions: RequestOptions(path: url),
                type: DioExceptionType.cancel,
                message: 'Download cancelled before start',
              );
            }

            // FIX(C1, C2, C4): Injected service call and cancelToken race with safe cleanup
            // Pass resume data at add-time (the only path libtorrent actually
            // supports — see lt_add_magnet_resume) instead of relying solely
            // on the post-add loadResumeData() fallback below, which
            // libtorrent has no API to make work reliably.
            final metadataFuture = _torrentService.addMagnetWithMetadataTimeout(
              url,
              saveDir,
              resumeData: preloadedResume?.toList(),
              onStatusUpdate: (message) {
                onProgress(_torrentProgress(
                  cycleState: CycleState.fetchingMetadata,
                  statusMessage: message,
                  summary: initSummary,
                  files: initFiles,
                  torrentId: torrentId,
                  knownFileSize: knownFileSize,
                ));
              },
            );

            var metadataResolved = false;
            final cancelWaitCompleter = Completer<int>();
            final cancelSub = cancelToken.whenCancel.then((_) {
              if (metadataResolved) return; // main loop tears down via cancelToken
              final existingId = _torrentService.idForSource(url);
              if (existingId != null) _safeRemoveTorrent(existingId);
              if (!cancelWaitCompleter.isCompleted) {
                cancelWaitCompleter.completeError(DioException(
                  requestOptions: RequestOptions(path: url),
                  type: DioExceptionType.cancel,
                  message: 'Magnet metadata fetch cancelled',
                ));
              }
            });

            // Covers the reverse race: metadata resolves AFTER cancel already won.
            unawaited(metadataFuture.then((int tid) {
              if (cancelToken.isCancelled) _safeRemoveTorrent(tid);
            }).catchError((Object e) {
              _log.fine('Metadata resolution post-error swallowed: $e');
            }));

            try {
              id = await Future.any([metadataFuture, cancelWaitCompleter.future]);
              metadataResolved = true;
            } finally {
              cancelSub.ignore();
            }
          } catch (e, st) {
            _log.fine('Metadata fetch probe failed: $e', e, st);
            // FIX(C1, C2-c): Clean up added handle on error/cancel/timeout
            if (id >= 0 && _torrentService.isTorrentAlive(id)) {
              _safeRemoveTorrent(id);
            }
            onProgress(_torrentProgress(
              cycleState: CycleState.failed,
              statusMessage: e is TimeoutException
                  ? 'Failed: Metadata fetch timeout'
                  : (e is DioException && e.type == DioExceptionType.cancel
                      ? 'Cancelled'
                      : 'Failed: Torrent initialization error'),
              summary: initSummary,
              files: initFiles,
              torrentId: torrentId,
              knownFileSize: knownFileSize,
            ));
            rethrow;
          }
        } else {
          // Resume data is handed to libtorrent at add-time via
          // lt_add_torrent_file_resume. This is the only path libtorrent
          // supports: it lets the engine trust the stored piece bitfield and
          // skip re-hashing the whole file from disk.
          final addTimeResume = preloadedResume?.toList();
          String filePath = url;
          if (url.startsWith('file://')) {
            filePath = Uri.parse(url).toFilePath();
            id = _torrentService.addTorrentFile(filePath, saveDir,
                sourceKey: url, resumeData: addTimeResume);
          } else if (url.startsWith('http://') || url.startsWith('https://')) {
            final tempTorrentPath = p.join(
              Directory.systemTemp.path,
              'temp_${taskId}_${DateTime.now().microsecondsSinceEpoch}.torrent',
            );
            final tempTorrentFile = File(tempTorrentPath);
            final torrentDio = clientBuilder(url);
            try {
              // FIX(C2-a): Pass cancelToken and options into HTTP download
              await torrentDio.download(
                url,
                tempTorrentPath,
                cancelToken: cancelToken,
                options: Options(receiveTimeout: const Duration(seconds: 30)),
              );
              // FIX(C2-b): Validate payload is bencoded torrent before handing to libtorrent
              if (!await tempTorrentFile.exists()) {
                throw TorrentSourceException(
                  'Downloaded torrent file does not exist',
                  url: url,
                );
              }
              final bytes = await tempTorrentFile.readAsBytes();
              if (bytes.length < 10 ||
                  bytes.length > 10 * 1024 * 1024 ||
                  bytes[0] != _bencodeDictPrefix) {
                throw TorrentSourceException(
                  'Downloaded payload is not a valid bencoded .torrent file (size: ${bytes.length} bytes)',
                  url: url,
                );
              }
              filePath = tempTorrentPath;
              // FIX(C4): Use _torrentService.addTorrentFile
              id = _torrentService.addTorrentFile(filePath, saveDir,
                  sourceKey: url, resumeData: addTimeResume);
            } finally {
              clientReleaser(torrentDio);
              try {
                if (await tempTorrentFile.exists()) {
                  await tempTorrentFile.delete();
                }
              } catch (e, st) {
                _log.warning('Temp torrent file deletion failed: $e', e, st);
              }
            }
          } else if (File(url).existsSync()) {
            id = _torrentService.addTorrentFile(url, saveDir,
                sourceKey: url, resumeData: addTimeResume);
          } else {
            throw TorrentSourceException(
              'Unsupported or inaccessible URL scheme for torrent: $url',
              url: url,
            );
          }
        }

        final rt = _getRuntime(id);
        if (id >= 0 && preloadedResume != null) {
          hasLoadedResume = true;
          if (preloadedFiles != null && preloadedFiles.isNotEmpty) {
            rt.cachedAccurateFiles = preloadedFiles;
          }
          final activeFiles = preloadedFiles ?? initFiles;
          final activeSummary = normalizeTorrentFiles(activeFiles);
          final resumeSummary = (
            total: activeSummary.total > 0 ? activeSummary.total : initSummary.total,
            done: activeSummary.total > 0 ? activeSummary.done : initSummary.done,
            bytes: activeSummary.bytes > 0 ? activeSummary.bytes : initSummary.bytes,
            downloaded: activeSummary.downloaded > 0
                ? activeSummary.downloaded
                : initSummary.downloaded,
          );
          // Resume data was handed to the engine at add-time for both magnet
          // (lt_add_magnet_resume) and file (lt_add_torrent_file_resume)
          // sources — the only paths libtorrent supports. A post-add
          // loadResumeData() is a guaranteed no-op, and the recheckTorrent()
          // that used to follow it re-hashed every piece on disk, which is
          // what made resume appear to hang for minutes on large torrents.
          //
          // Seed the last-confirmed byte count from the resume store so the
          // brief checking phase reports the previously known progress instead
          // of the engine's verification percentage.
          rt.lastConfirmedDownloadedBytes = resumeSummary.downloaded;
          rt.resumeExpectedBytes = resumeSummary.downloaded;
          onProgress(_torrentProgress(
            cycleState: CycleState.verifying,
            statusMessage: 'Verifying resume data…',
            summary: resumeSummary,
            files: activeFiles,
            torrentId: id,
            knownFileSize: knownFileSize,
          ));
        }
      } catch (e, st) {
        if (e is! DioException || e.type != DioExceptionType.cancel) {
          _log.severe('Torrent source initialization failed: $e', e, st);
          if (id >= 0) _safeRemoveTorrent(id);
          onProgress(_torrentProgress(
            cycleState: CycleState.failed,
            statusMessage: 'Failed: Torrent initialization error',
            summary: initSummary,
            files: initFiles,
            torrentId: torrentId,
            knownFileSize: knownFileSize,
          ));
        }
        rethrow;
      }
    }

    if (id < 0) {
      onProgress(_torrentProgress(
        cycleState: CycleState.failed,
        statusMessage: 'Failed: Torrent engine rejected the torrent',
        summary: initSummary,
        files: initFiles,
        torrentId: torrentId,
        knownFileSize: knownFileSize,
      ));
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.unknown,
        error: 'Torrent engine rejected the torrent.',
      );
    }

    // FIX(C2): Guard post-add section so exceptions clean up live engine state
    try {
      TorrentResumeStore.registerSource(id, url);
      _activeTorrentIds.add(id);
      final rt = _getRuntime(id);
      bool torrentCompleted = false;
      bool pauseInitiated = false;

      List<Map<String, dynamic>>? postMetadataFiles = initFiles;
      final bool hasNoRealFiles = initFiles == null ||
          initFiles.isEmpty ||
          initFiles.every((f) => ((f['length'] as num?)?.toInt() ?? 0) <= 0);
      if (id >= 0 && hasNoRealFiles) {
        try {
          final nativeFiles = _torrentService.getFiles(id);
          if (nativeFiles.isNotEmpty) {
            postMetadataFiles = nativeFiles.map((f) {
              final dl = f.safeDownloadedBytes < 0 ? 0 : f.safeDownloadedBytes;
              return <String, dynamic>{
                'name': f.name,
                'length': f.size,
                'downloadedBytes': dl,
                'selected': f.selected,
                'priority': f.priority,
                'progress': f.size > 0 ? (dl / f.size).clamp(0.0, 1.0) : 0.0,
                'isComplete': f.size > 0 && dl >= f.size,
                'progressEstimated': false,
              };
            }).toList();
            rt.cachedAccurateFiles = postMetadataFiles;
          }
        } catch (e, st) {
          _log.fine('Post-metadata file fetch failed: $e', e, st);
        }
      } else if (id >= 0 &&
          postMetadataFiles != null &&
          postMetadataFiles.isNotEmpty) {
        rt.cachedAccurateFiles = postMetadataFiles;
        try {
          final nativeFiles = _torrentService.getFiles(id);
          if (nativeFiles.length == postMetadataFiles.length) {
            final priorities = postMetadataFiles.map((f) {
              final selected = (f['selected'] as bool?) != false;
              if (!selected) return 0;
              return (f['priority'] as int?) ?? 4;
            }).toList();
            _torrentService.setFilePriorities(id, priorities);
          }
        } catch (e, st) {
          _log.fine('Setting initial file priorities failed: $e', e, st);
        }
      }

      final postMetadataSummary = normalizeTorrentFiles(postMetadataFiles);
      if (id != torrentId || hasLoadedResume) {
        onProgress(_torrentProgress(
          cycleState: isRetry
              ? CycleState.retrying
              : ((postMetadataSummary.downloaded > 0 || hasLoadedResume)
                  ? CycleState.resuming
                  : CycleState.starting),
          statusMessage: isRetry
              ? 'Retrying torrent…'
              : ((postMetadataSummary.downloaded > 0 || hasLoadedResume)
                  ? 'Resuming torrent…'
                  : 'Starting torrent…'),
          summary: (
            total: postMetadataSummary.total > 0
                ? postMetadataSummary.total
                : initSummary.total,
            done: postMetadataSummary.total > 0
                ? postMetadataSummary.done
                : initSummary.done,
            bytes: postMetadataSummary.bytes > 0
                ? postMetadataSummary.bytes
                : (initSummary.bytes > 0 ? initSummary.bytes : knownFileSize),
            downloaded: postMetadataSummary.downloaded > 0
                ? postMetadataSummary.downloaded
                : initSummary.downloaded,
          ),
          files: postMetadataFiles,
          torrentId: id,
          knownFileSize: knownFileSize,
        ));
      }

      final pauseGuard = Completer<void>();
      rt.pauseCompleter = pauseGuard;
      bool pauseHandled = false;

      cancelToken.whenCancel.then((cancelReason) async {
        if (pauseHandled || torrentCompleted || pauseGuard.isCompleted) {
          if (!pauseGuard.isCompleted) pauseGuard.complete();
          return;
        }
        pauseHandled = true;
        pauseInitiated = true;
        try {
          _log.info(
              'Pause/cancel requested for torrent $id — executing pause actions');
          rt.watchdogManager?.stop();
          rt.watchdogManager = null;
          await _saveResumeDataBeforePause(id, url);
          TorrentSubscriptionRegistry.instance.unregister(id, this);
          await haltTorrent(id);
          await Future.delayed(const Duration(milliseconds: 50));

          List<Map<String, dynamic>>? pauseFiles = getTorrentFiles?.call();
          String normKey(String name) => name.toLowerCase().replaceAll('\\', '/');
          final previousSelectedMap = <String, bool>{
            if (pauseFiles != null)
              for (final f in pauseFiles)
                if (f['name'] != null)
                  normKey(f['name'] as String): (f['selected'] as bool?) ?? true
          };
          final previousPriorityMap = <String, int>{
            if (pauseFiles != null)
              for (final f in pauseFiles)
                if (f['name'] != null && f['priority'] is int)
                  normKey(f['name'] as String): f['priority'] as int
          };
          final previousLengthMap = <String, int>{
            if (pauseFiles != null)
              for (final f in pauseFiles)
                if (f['name'] != null &&
                    ((f['length'] as num?)?.toInt() ?? 0) > 0)
                  normKey(f['name'] as String): (f['length'] as num).toInt()
          };
          final previousLengthByIndex = <int, int>{
            if (pauseFiles != null)
              for (var i = 0; i < pauseFiles.length; i++)
                if (((pauseFiles[i]['length'] as num?)?.toInt() ?? 0) > 0)
                  i: (pauseFiles[i]['length'] as num).toInt()
          };
          // Byte counts already recorded for each file. A fresh reading that the
          // engine cannot supply must fall back to these rather than reset the
          // row to zero — this list is what gets persisted for the paused task.
          final previousDownloadedMap = <String, int>{
            if (pauseFiles != null)
              for (final f in pauseFiles)
                if (f['name'] != null &&
                    ((f['downloadedBytes'] as num?)?.toInt() ?? 0) > 0)
                  normKey(f['name'] as String):
                      (f['downloadedBytes'] as num).toInt()
          };
          try {
            final accurateFiles = await _torrentService.getAccurateFileProgress(
              id,
              saveDir,
              knownSizes: previousLengthByIndex,
            );
            if (accurateFiles.isNotEmpty) {
              pauseFiles = [
                for (var i = 0; i < accurateFiles.length; i++)
                  () {
                    final af = accurateFiles[i];
                    // Never let an unreported size erase a length we already
                    // know from the torrent metadata.
                    final len = TorrentFileNormalizer.resolveFileLength(
                      af.size,
                      previousLength: previousLengthMap[normKey(af.name)] ??
                          previousLengthByIndex[i],
                    );
                    final dl =
                        len > 0 ? af.downloadedBytes.clamp(0, len) : af.downloadedBytes;
                    // An unmeasurable reading is not "nothing downloaded": keep
                    // the count this file already had so pausing cannot erase it.
                    final resolvedDl = af.isEstimated
                        ? (previousDownloadedMap[normKey(af.name)] ?? dl)
                        : dl;
                    final clampedDl =
                        len > 0 ? resolvedDl.clamp(0, len) : resolvedDl;
                    return <String, dynamic>{
                      'name': af.name,
                      'length': len,
                      'downloadedBytes': clampedDl,
                      'selected':
                          previousSelectedMap[normKey(af.name)] ?? true,
                      'priority': previousPriorityMap[normKey(af.name)] ?? 4,
                      'progress':
                          len > 0 ? (clampedDl / len).clamp(0.0, 1.0) : 0.0,
                      'isComplete':
                          !af.isEstimated && len > 0 && clampedDl >= len,
                      'progressEstimated': af.isEstimated,
                    };
                  }()
              ];
            }
          } catch (e, st) {
            _log.warning(
              'Accurate file progress fetch on pause failed for torrent $id: $e',
              e,
              st,
            );
          }
          final pauseSummary = normalizeTorrentFiles(pauseFiles);
          PauseReason? effectivePauseReason = pauseReason;
          if (effectivePauseReason == null) {
            try {
              final engine = getIt.isRegistered<DownloadEngine>()
                  ? getIt<DownloadEngine>()
                  : DownloadEngine();
              final hasSpace =
                  await engine.hasEnoughDiskSpace(saveDir, 100 * 1024 * 1024);
              if (!hasSpace) {
                effectivePauseReason = PauseReason.diskFull;
              }
            } catch (e, st) {
              _log.fine('Disk space check before pause failed: $e', e, st);
            }
          }
          final String? cancelReasonStr = cancelReason.error?.toString() ??
              cancelReason.message ??
              cancelToken.cancelError?.error?.toString() ??
              cancelToken.cancelError?.message;
          final parsedPauseReason = cancelReasonStr?.contains(':') == true
              ? (PauseReason.fromName(cancelReasonStr!.split(':')[1]) ??
                  PauseReason.userRequested)
              : (cancelReasonStr != null && cancelReasonStr.isNotEmpty
                  ? (PauseReason.fromName(cancelReasonStr) ??
                      _inferPauseReason(effectivePauseReason))
                  : _inferPauseReason(effectivePauseReason));
          onProgress(_torrentProgress(
            cycleState: CycleState.paused,
            statusMessage: 'Paused',
            pauseReason: parsedPauseReason,
            summary: pauseSummary,
            files: pauseFiles,
            torrentId: id,
            knownFileSize: knownFileSize,
          ));
          if (!pauseGuard.isCompleted) {
            pauseGuard.complete();
          }
        } finally {
          if (!pauseGuard.isCompleted) {
            pauseGuard.complete();
          }
        }
      });

      try {
        if (cancelToken.isCancelled) {
          if (!pauseHandled) {
            pauseHandled = true;
            pauseInitiated = true;
            // Only attempt graceful pause when the torrent has metadata.
            // Without metadata libtorrent can't transition to "paused" quickly,
            // and the unawaited call would run 3×5 s timeout loops in the
            // background. haltTorrent (called from whenCancel) already handles
            // the no-metadata case via forceStopTorrent.
            final hasMetaForPause =
                _torrentService.latestStats[id]?.hasMetadata ?? false;
            if (hasMetaForPause) {
              unawaited(_torrentService.pauseTorrent(id).catchError((Object e) {
                _log.warning('Immediate pause failed for torrent $id: $e');
              }));
            }
          }
          throw DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
            message: 'Download paused',
          );
        }
        if (!cancelToken.isCancelled) {
          try {
            _torrentService.resumeTorrent(id);
          } catch (e, st) {
            _log.warning('resumeTorrent failed: $e', e, st);
          }
          if (url.startsWith('magnet:')) {
            try {
              _torrentService.boostMagnetDiscovery(id);
            } catch (e, st) {
              _log.warning('boostMagnetDiscovery failed: $e', e, st);
            }
          }
        }
        await _listenForCompletion(
          id,
          url,
          currentLocalFilePath,
          cancelToken,
          onProgress,
          getTorrentFiles: getTorrentFiles,
          knownFileSize: knownFileSize,
        );
        torrentCompleted = true;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          if (!pauseGuard.isCompleted) {
            await pauseGuard.future.timeout(
              const Duration(seconds: 5),
              onTimeout: () {
                _log.severe(
                    'CRASH-TELEMETRY: Pause handler timed out (5s) for torrent $id; forcing stop.');
                _torrentService
                    .forceStopTorrent(id)
                    .catchError((Object err, StackTrace st) {
                  _log.severe(
                      'forceStopTorrent on timeout failed for $id', err, st);
                });
                return null;
              },
            );
          }
        }
        rethrow;
      } finally {
        if (torrentCompleted && !pauseGuard.isCompleted) {
          pauseGuard.complete();
        }
        if (cancelToken.isCancelled || pauseInitiated) {
          try {
            await pauseGuard.future.timeout(
              const Duration(seconds: 5),
              onTimeout: () {
                _log.severe(
                    'CRASH-TELEMETRY: Finally pause timeout (5s) for torrent $id; forcing stop.');
                _torrentService
                    .forceStopTorrent(id)
                    .catchError((Object err, StackTrace st) {
                  _log.severe(
                      'forceStopTorrent on finally timeout failed for $id',
                      err,
                      st);
                });
                return null;
              },
            );
          } catch (_) {}
        }
        TorrentSubscriptionRegistry.instance.unregister(id, this);
        _activeTorrentIds.remove(id);
        final removedRt = _runtime.remove(id);
        removedRt?.close();
      }
    } catch (e, st) {
      if (e is! DioException || e.type != DioExceptionType.cancel) {
        _log.severe('Post-add setup or download failed for torrent $id: $e', e, st);
        _safeRemoveTorrent(id);
        try {
          TorrentResumeStore.unregisterTorrent(id);
        } catch (_) {}
        _activeTorrentIds.remove(id);
        final rt = _runtime.remove(id);
        rt?.close();
        onProgress(_torrentProgress(
          cycleState: CycleState.failed,
          statusMessage: 'Failed: Torrent setup error',
          summary: initSummary,
          files: initFiles,
          torrentId: id,
          knownFileSize: knownFileSize,
        ));
      }
      rethrow;
    }
  }

  @visibleForTesting
  Future<void> listenForCompletionForTesting(
    int id,
    String url,
    String localFilePath,
    CancelToken cancelToken,
    ValueChangedProgress onProgress, {
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int knownFileSize = 0,
  }) {
    return _listenForCompletion(
      id,
      url,
      localFilePath,
      cancelToken,
      onProgress,
      getTorrentFiles: getTorrentFiles,
      knownFileSize: knownFileSize,
    );
  }

  List<Map<String, dynamic>> _diffUpdateFileList(
    List<Map<String, dynamic>> currentList,
    List<TorrentFileItem> nativeFiles,
  ) {
    String normKey(String name) => name.toLowerCase().replaceAll('\\', '/');
    final oldByName = <String, Map<String, dynamic>>{
      for (final item in currentList)
        if (item['name'] is String) normKey(item['name'] as String): item,
    };

    if (currentList.length != nativeFiles.length) {
      return nativeFiles.asMap().entries.map((entry) {
        final i = entry.key;
        final f = entry.value;
        final old = oldByName[normKey(f.name)] ??
            (i < currentList.length ? currentList[i] : null);
        // The engine reports 0 for a size it cannot determine; the length we
        // already parsed from the torrent metadata stays authoritative.
        final len = TorrentFileNormalizer.resolveFileLength(
          f.size,
          previousLength: (old?['length'] as num?)?.toInt(),
        );
        final bool isEstimated =
            f.downloadedBytes < 0 || (f.downloadedBytes == 0 && len > 0);
        // No engine reading (< 0) is not "nothing downloaded" — keep the bytes
        // we already knew about rather than resetting the row to zero.
        final dl = f.downloadedBytes < 0
            ? ((old?['downloadedBytes'] as num?)?.toInt() ?? 0)
            : f.safeDownloadedBytes;
        final selected = old != null
            ? ((old['selected'] as bool?) ?? f.selected)
            : f.selected;
        final priority = old != null
            ? ((old['priority'] as int?) ?? f.priority)
            : f.priority;
        return {
          'name': f.name,
          'length': len,
          'downloadedBytes': dl,
          'selected': selected,
          'priority': priority,
          'progress': len > 0 ? (dl / len).clamp(0.0, 1.0) : 0.0,
          'isComplete': len > 0 && dl >= len,
          'progressEstimated': isEstimated,
          if (len > 0 || (old?['lengthKnown'] as bool?) == true)
            'lengthKnown': true,
        };
      }).toList();
    }

    bool hasDiff = false;
    final updated = List<Map<String, dynamic>>.from(currentList);
    for (int i = 0; i < nativeFiles.length; i++) {
      final f = nativeFiles[i];
      final old = oldByName[normKey(f.name)] ??
          (i < currentList.length ? currentList[i] : null);
      final len = TorrentFileNormalizer.resolveFileLength(
        f.size,
        previousLength: (old?['length'] as num?)?.toInt(),
      );
      final dl = f.downloadedBytes < 0
          ? ((old?['downloadedBytes'] as num?)?.toInt() ?? 0)
          : f.safeDownloadedBytes;
      final isEst =
          f.downloadedBytes < 0 || (f.downloadedBytes == 0 && len > 0);
      final prog = len > 0 ? (dl / len).clamp(0.0, 1.0) : 0.0;
      final isDone = len > 0 && dl >= len;
      final selected =
          old != null ? ((old['selected'] as bool?) ?? f.selected) : f.selected;
      final priority =
          old != null ? ((old['priority'] as int?) ?? f.priority) : f.priority;

      if (old == null ||
          old['downloadedBytes'] != dl ||
          old['selected'] != selected ||
          old['priority'] != priority ||
          old['progress'] != prog ||
          old['isComplete'] != isDone ||
          old['name'] != f.name ||
          old['length'] != len) {
        hasDiff = true;
        updated[i] = {
          if (old != null) ...old,
          'name': f.name,
          'length': len,
          'downloadedBytes': dl,
          'selected': selected,
          'priority': priority,
          'progress': prog,
          'isComplete': isDone,
          'progressEstimated': isEst,
          if (len > 0) 'lengthKnown': true,
        };
      }
    }
    return hasDiff ? updated : currentList;
  }

  Future<void> _listenForCompletion(
    int id,
    String url,
    String localFilePath,
    CancelToken cancelToken,
    ValueChangedProgress onProgress, {
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int knownFileSize = 0,
  }) async {
    final rt = _getRuntime(id);
    rt.watchdogManager?.stop();
    rt.watchdogManager = null;
    if (rt.completionGuard != null && !rt.completionGuard!.isCompleted) {
      try {
        await rt.completionGuard!.future;
      } catch (e) {
        if (e is! StateError || e.message != 'Torrent runtime closed') {
          rethrow;
        }
      }
      return;
    }
    final completer = Completer<void>();
    rt.completionGuard = completer;
    StreamSubscription? sub;
    final existingSub =
        TorrentSubscriptionRegistry.instance.getSubscription(id);
    await existingSub?.cancel();
    TorrentSubscriptionRegistry.instance.unregister(id, this);
    rt.lastProgressTick = DateTime.fromMillisecondsSinceEpoch(0);
    rt.lastAccurateSync = DateTime.fromMillisecondsSinceEpoch(0);
    rt.cachedAccurateFiles = null;
    rt.lastStateLabel = '';
    rt.lastPiecesHave = -1;
    rt.lastSnapshotHash = 0;
    rt.corruptSizeLogged = false;

    try {
      final latest = _torrentService.latestStats[id];
      if (latest?.hasMetadata == true) {
        final nativeFiles = _torrentService.getFiles(id);
        if (nativeFiles.isNotEmpty) {
          // Lengths already known for this task (parsed from the .torrent) are
          // the fallback whenever the engine reports a size of 0.
          final known = getTorrentFiles?.call();
          String normKey(String name) =>
              name.toLowerCase().replaceAll('\\', '/');
          final knownByName = <String, int>{
            if (known != null)
              for (final f in known)
                if (f['name'] is String &&
                    ((f['length'] as num?)?.toInt() ?? 0) > 0)
                  normKey(f['name'] as String): (f['length'] as num).toInt()
          };
          rt.cachedAccurateFiles =
              nativeFiles.asMap().entries.map((entry) {
            final i = entry.key;
            final f = entry.value;
            final dl = f.safeDownloadedBytes < 0 ? 0 : f.safeDownloadedBytes;
            final len = TorrentFileNormalizer.resolveFileLength(
              f.size,
              previousLength: knownByName[normKey(f.name)] ??
                  (known != null && i < known.length
                      ? (known[i]['length'] as num?)?.toInt()
                      : null),
            );
            return <String, dynamic>{
              'name': f.name,
              'length': len,
              'downloadedBytes': dl,
              'selected': f.selected,
              'priority': f.priority,
              'progress': len > 0 ? (dl / len).clamp(0.0, 1.0) : 0.0,
              'isComplete': len > 0 && dl >= len,
              'progressEstimated': false,
            };
          }).toList();
        }
      }
    } catch (e, st) {
      _log.fine('Initial file list fetch failed: $e', e, st);
    }

    void emitProgress(DownloadProgress progress) {
      final files = progress.torrentFiles;
      if (files != null &&
          files.isNotEmpty &&
          (progress.totalFiles == null || progress.totalFileBytes == null)) {
        final summary = normalizeTorrentFiles(files);
        onProgress(progress.copyWith(
          totalFiles: summary.total > 0 ? summary.total : null,
          completedFiles: summary.total > 0 ? summary.done : null,
          totalFileBytes: summary.bytes > 0 ? summary.bytes : null,
          downloadedFileBytes: summary.bytes > 0 ? summary.downloaded : null,
        ));
      } else {
        onProgress(progress);
      }
    }

    final tracker = _TorrentTrackerState();
    final initialFiles = getTorrentFiles?.call();
    final initialFileCount = initialFiles?.length ?? 0;

    _setupWatchdogs(
      id: id,
      url: url,
      initialFileCount: initialFileCount,
      tracker: tracker,
      emitProgress: emitProgress,
      completer: completer,
      cancelToken: cancelToken,
    );

    sub = _subscribeToUpdates(
      id: id,
      url: url,
      localFilePath: localFilePath,
      cancelToken: cancelToken,
      emitProgress: emitProgress,
      completer: completer,
      tracker: tracker,
      getTorrentFiles: getTorrentFiles,
      knownFileSize: knownFileSize,
    );

    TorrentSubscriptionRegistry.instance.register(id, this, sub);

    cancelToken.whenCancel.then((cancelError) {
      if (!completer.isCompleted) {
        completer.completeError(DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel,
          error: cancelError,
        ));
      }
    });

    try {
      await completer.future;
    } catch (e) {
      if (e is StateError && e.message == 'Torrent runtime closed') {
        return;
      }
      rethrow;
    } finally {
      await _cleanup(id, sub);
    }
  }

  void _setupWatchdogs({
    required int id,
    required String url,
    required int initialFileCount,
    required _TorrentTrackerState tracker,
    required void Function(DownloadProgress) emitProgress,
    required Completer<void> completer,
    required CancelToken cancelToken,
  }) {
    final rt = _getRuntime(id);
    final watchdogInterval = initialFileCount < 1000
        ? const Duration(seconds: 30)
        : const Duration(seconds: 120);

    rt.watchdogManager?.stop();
    final watchdog =
        TorrentWatchdogManager(_torrentService, id, watchdogInterval);
    rt.watchdogManager = watchdog;

    int aliveMisses = 0;
    watchdog.start(
      onStallCheck: () {
        if (cancelToken.isCancelled) return;
        // FIX(A1): Use IConnectivity
        if (getIt.isRegistered<IConnectivity>()) {
          final connectivity = getIt<IConnectivity>();
          if (!connectivity.hasConnection) {
            emitProgress(DownloadProgress(
              downloadedBytes: tracker.lastTorrentDownloadedBytes,
              fileSize: tracker.currentTotalSize,
              speed: 0,
              eta: null,
              torrentFiles: TorrentService.bridgeCompatible
                  ? rt.cachedAccurateFiles
                  : null,
              cycleState: CycleState.paused,
              pauseReason: PauseReason.networkLost,
              statusMessage: 'Waiting for network…',
              torrentId: id,
            ));
            return;
          }
        }
        // Every stall signal below — byte deltas, transfer rate, peer count,
        // state label — comes from the status struct. When the native bridge
        // does not match these FFI bindings all of them are noise, so the
        // 5-minute branch would fail a perfectly healthy transfer with a
        // TorrentStallException on the strength of garbage. Sit the rest of the
        // watchdog out rather than act on data that means nothing; the
        // connectivity check above is independent of the struct, so it stays.
        if (!TorrentService.bridgeCompatible) return;
        final elapsed =
            DateTime.now().difference(tracker.lastTorrentProgressTime);
        final isTerminal = rt.lastStateLabel == 'seeding' ||
            rt.lastStateLabel == 'paused' ||
            rt.lastStateLabel == 'stopped' ||
            rt.lastStateLabel == 'error';
        if (isTerminal) return;
        final isNonDownloadPhase = rt.lastStateLabel.contains('checking') ||
            rt.lastStateLabel.contains('downloading_metadata') ||
            rt.lastStateLabel.contains('allocating');
        if (isNonDownloadPhase) return;
        if (elapsed >= const Duration(minutes: 5)) {
          if (rt.lastStateLabel == 'downloading' &&
              tracker.lastTorrentPeerCount == 0) {
            emitProgress(DownloadProgress(
              downloadedBytes: tracker.lastTorrentDownloadedBytes,
              fileSize: tracker.currentTotalSize,
              speed: 0,
              eta: null,
              torrentFiles: rt.cachedAccurateFiles,
              cycleState: CycleState.stalled,
              statusMessage: 'Stalled (no peers)',
              torrentId: id,
            ));
          }
          if (rt.completionGuard != null && !rt.completionGuard!.isCompleted) {
            rt.completionGuard!.completeError(const TorrentStallException(
              'Torrent download stalled for > 5 minutes with no updates',
            ));
            return;
          }
        } else if (elapsed >= const Duration(seconds: 60) &&
            tracker.lastTorrentSpeed == 0) {
          emitProgress(DownloadProgress(
            downloadedBytes: tracker.lastTorrentDownloadedBytes,
            fileSize: tracker.currentTotalSize,
            speed: 0,
            eta: null,
            torrentFiles: rt.cachedAccurateFiles,
            cycleState: CycleState.stalled,
            statusMessage: 'Looking for peers…',
            torrentId: id,
          ));
        }
        if (elapsed >= const Duration(minutes: 10)) {
          _log.warning('Torrent $id stalled for 10min — forcing reannounce');
          try {
            // FIX(C4): Injected service
            _torrentService.announceNow(id);
            emitProgress(DownloadProgress(
              downloadedBytes: tracker.lastTorrentDownloadedBytes,
              fileSize: tracker.currentTotalSize,
              speed: 0,
              eta: null,
              torrentFiles: rt.cachedAccurateFiles,
              cycleState: CycleState.retrying,
              statusMessage: 'Retrying connection…',
              torrentId: id,
            ));
          } catch (e, st) {
            _log.warning('Force reannounce failed for $id', e, st);
          }
        }
      },
      onAlivenessLost: () {
        if (cancelToken.isCancelled) return;
        aliveMisses++;
        if (aliveMisses < 2) return;
        watchdog.stop();
        // NOTE: `sub` cannot be used here — see _setupWatchdogs' `sub`
        // parameter, which is always null at call time (this method is
        // invoked before `sub` is assigned in _listenForCompletion). Look
        // the live subscription up via the registry instead, which is
        // guaranteed current since register() runs after `sub` is assigned.
        TorrentSubscriptionRegistry.instance.getSubscription(id)?.cancel();
        _activeTorrentIds.remove(id);
        TorrentSubscriptionRegistry.instance.unregister(id, this);
        if (!completer.isCompleted) {
          completer.completeError(DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.unknown,
            error: 'Torrent handle lost (aliveness poll).',
          ));
        }
      },
      isPausedByUser: () => cancelToken.isCancelled,
    );
  }

  StreamSubscription _subscribeToUpdates({
    required int id,
    required String url,
    required String localFilePath,
    required CancelToken cancelToken,
    required void Function(DownloadProgress) emitProgress,
    required Completer<void> completer,
    required _TorrentTrackerState tracker,
    required List<Map<String, dynamic>>? Function()? getTorrentFiles,
    required int knownFileSize,
  }) {
    int streamMisses = 0;
    return _torrentService.torrentUpdates.listen((torrents) async {
      try {
        if (cancelToken.isCancelled) return;
        final torrent = torrents[id];
        if (torrent == null) {
          streamMisses++;
          if (!_torrentService.isTorrentAlive(id)) {
            if (!completer.isCompleted) {
              completer.completeError(DioException(
                requestOptions: RequestOptions(path: url),
                type: DioExceptionType.unknown,
                error: 'Torrent handle lost.',
              ));
            }
            unawaited(_cleanup(id, null));
            return;
          }
          if (streamMisses < 5) return;
          return;
        }
        streamMisses = 0;

        await _handleUpdate(
          id: id,
          url: url,
          torrent: torrent,
          localFilePath: localFilePath,
          cancelToken: cancelToken,
          emitProgress: emitProgress,
          completer: completer,
          tracker: tracker,
          getTorrentFiles: getTorrentFiles,
          knownFileSize: knownFileSize,
        );
      } catch (e, st) {
        _log.severe('Unexpected error processing torrent update for $id', e, st);
      }
    }, onError: (Object e, StackTrace st) {
      _log.severe('Torrent updates stream error for $id: $e', e, st);
      if (!completer.isCompleted && !_torrentService.isTorrentAlive(id)) {
        completer.completeError(DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.unknown,
          error: 'Torrent stream terminated: $e',
        ));
      }
    });
  }

  Future<void> _handleUpdate({
    required int id,
    required String url,
    required TorrentUpdateInfo torrent,
    required String localFilePath,
    required CancelToken cancelToken,
    required void Function(DownloadProgress) emitProgress,
    required Completer<void> completer,
    required _TorrentTrackerState tracker,
    required List<Map<String, dynamic>>? Function()? getTorrentFiles,
    required int knownFileSize,
  }) async {
    final rt = _getRuntime(id);
    final stateLabel = torrent.stateLabel.toLowerCase();
    final isStateChange = stateLabel != rt.lastStateLabel;
    final isTerminal = torrent.isPaused ||
        torrent.state == TorrentState.seeding ||
        torrent.state == TorrentState.error;
    final now = DateTime.now();

    if (!isTerminal &&
        rt.lastProgressTick.millisecondsSinceEpoch > 0 &&
        now.difference(rt.lastProgressTick) > const Duration(minutes: 5) &&
        tracker.lastTorrentSpeed == 0) {
      _log.warning(
        'Torrent $id stalled for >5min without progress tick — triggering fallback announceNow recovery',
      );
      try {
        _torrentService.announceNow(id);
      } catch (e, st) {
        _log.warning('Fallback stall recovery announceNow failed for $id', e, st);
      }
    }

    if (!isTerminal &&
        !isStateChange &&
        now.difference(rt.lastProgressTick) < const Duration(milliseconds: 500)) {
      return;
    }
    final previousState = rt.lastStateLabel;
    rt.lastProgressTick = now;
    rt.lastStateLabel = stateLabel;
    if (isStateChange) {
      tracker.lastTorrentProgressTime = now;
    }

    List<Map<String, dynamic>>? resolvedFiles =
        getTorrentFiles?.call() ?? rt.cachedAccurateFiles;

    final piecesDelta = torrent.piecesHave != rt.lastPiecesHave;
    final bool cachedHasZeroLengths = rt.cachedAccurateFiles == null ||
        rt.cachedAccurateFiles!.isEmpty ||
        rt.cachedAccurateFiles!.every(
            (f) => ((f['length'] as num?)?.toInt() ?? 0) <= 0);
    if ((torrent.hasMetadata || torrent.piecesTotal > 0) &&
        (piecesDelta || cachedHasZeroLengths)) {
      rt.lastPiecesHave = torrent.piecesHave;
      try {
        final nativeFiles = _torrentService.getFiles(id);
        if (nativeFiles.isNotEmpty) {
          final currentEffectiveList =
              resolvedFiles ?? rt.cachedAccurateFiles ?? const [];
          final diffed = _diffUpdateFileList(
            currentEffectiveList,
            nativeFiles,
          );
          if (currentEffectiveList.isNotEmpty &&
              nativeFiles.length == currentEffectiveList.length) {
            try {
              final priorities = diffed.map((f) {
                final selected = (f['selected'] as bool?) != false;
                if (!selected) return 0;
                return (f['priority'] as int?) ?? 4;
              }).toList();
              _torrentService.setFilePriorities(id, priorities);
            } catch (e, st) {
              _log.fine('Ensuring file priorities failed: $e', e, st);
            }
          }
          final snapshot = TorrentFileSnapshot(diffed);
          if (snapshot.hash != rt.lastSnapshotHash) {
            rt.lastSnapshotHash = snapshot.hash;
            resolvedFiles = diffed;
            rt.cachedAccurateFiles = diffed;
          } else {
            resolvedFiles = rt.cachedAccurateFiles;
          }
        }
      } catch (e, st) {
        _log.fine('Failed to fetch native file list: $e', e, st);
      }
    }
    resolvedFiles ??= rt.cachedAccurateFiles;

    final effectiveFiles = resolvedFiles ?? rt.cachedAccurateFiles;
    final int allFilesSum = effectiveFiles?.fold<int>(
            0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0)) ??
        0;
    final int selectedFilesSum = effectiveFiles
            ?.where((f) => (f['selected'] as bool?) ?? true)
            .fold<int>(0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0)) ??
        0;

    int totalSize = (torrent.totalWanted > 0)
        ? torrent.totalWanted
        : (selectedFilesSum > 0
            ? selectedFilesSum
            : (allFilesSum > 0
                ? allFilesSum
                : (knownFileSize > 0 ? knownFileSize : 0)));
    if (totalSize <= 0 && (torrent.hasMetadata || torrent.piecesTotal > 0)) {
      try {
        final nf = _torrentService.getFiles(id);
        if (nf.isNotEmpty) {
          totalSize = nf
              .where((f) => f.selected)
              .fold<int>(0, (s, f) => s + f.size);
          if (totalSize <= 0) {
            totalSize = nf.fold<int>(0, (s, f) => s + f.size);
          }
        }
      } catch (_) {}
    }
    tracker.currentTotalSize = totalSize;
    final bool hasReliableTotalSize =
        selectedFilesSum > 0 || allFilesSum > 0 || torrent.totalWanted > 0;
    final fileCount =
        effectiveFiles?.length ?? (rt.cachedAccurateFiles?.length ?? 0);
    final inBg = DownloadEngine.isInBackground;

    if (fileCount > 0 &&
        fileCount <= 1000 &&
        !shouldSkipPerFileSync(fileCount, inBackground: inBg)) {
      final syncInterval =
          computeAdaptiveSyncInterval(fileCount, inBackground: inBg);
      if (now.difference(rt.lastAccurateSync) >= syncInterval) {
        rt.lastAccurateSync = now;
        try {
          final saveDir = File(localFilePath).parent.path;
          String normKey(String n) => n.toLowerCase().replaceAll('\\', '/');
          final previousLengthMap = <String, int>{};
          final previousLengthByIndex = <int, int>{};
          if (effectiveFiles != null) {
            for (var i = 0; i < effectiveFiles.length; i++) {
              final len = (effectiveFiles[i]['length'] as num?)?.toInt() ?? 0;
              if (len <= 0) continue;
              previousLengthByIndex[i] = len;
              final name = effectiveFiles[i]['name'];
              if (name is String) previousLengthMap[normKey(name)] = len;
            }
          }
          final accurate = await _torrentService.getAccurateFileProgress(
            id,
            saveDir,
            knownSizes: previousLengthByIndex,
          );
          if (accurate.isNotEmpty) {
            final previousSelectedMap = <String, bool>{};
            final previousPriorityMap = <String, int>{};
            if (effectiveFiles != null) {
              for (final f in effectiveFiles) {
                final name = f['name'];
                if (name is String) {
                  final k = normKey(name);
                  previousSelectedMap[k] = (f['selected'] as bool?) ?? true;
                  final prio = f['priority'];
                  if (prio is int) previousPriorityMap[k] = prio;
                }
              }
            }
            resolvedFiles = [
              for (var i = 0; i < accurate.length; i++)
                () {
                  final f = accurate[i];
                  final len = TorrentFileNormalizer.resolveFileLength(
                    f.size,
                    previousLength: previousLengthMap[normKey(f.name)] ??
                        previousLengthByIndex[i],
                  );
                  final dl = len > 0
                      ? f.downloadedBytes.clamp(0, len)
                      : f.downloadedBytes;
                  return <String, dynamic>{
                    'name': f.name,
                    'length': len,
                    'downloadedBytes': dl,
                    'selected': previousSelectedMap[normKey(f.name)] ?? true,
                    'priority': previousPriorityMap[normKey(f.name)] ?? 4,
                    'progress': len > 0 ? (dl / len).clamp(0.0, 1.0) : 0.0,
                    'isComplete': !f.isEstimated && len > 0 && dl >= len,
                    'progressEstimated': f.isEstimated,
                  };
                }()
            ];
            rt.cachedAccurateFiles = resolvedFiles;
          }
        } catch (e, st) {
          _log.warning('Accurate file sync failed: $e', e, st);
        }
      }
    }

    final rawDownloaded = torrent.totalWantedDone > 0
        ? torrent.totalWantedDone
        : torrent.totalDone;

    // While libtorrent is in checking_files / checking_resume_data /
    // queued_for_checking, `progress` and `totalWantedDone` describe how much
    // of the file has been hash-verified so far — not how much has been
    // downloaded. Treating them as download progress makes a resumed torrent
    // ramp 0% → n% as verification walks the file, which reads as a fake
    // percentage. Keep the two meanings apart.
    final bool isChecking = torrent.isChecking;
    final double verificationProgress = isChecking && torrent.progress.isFinite
        ? torrent.progress.clamp(0.0, 1.0)
        : 0.0;

    // A stale native binary lays out `lt_torrent_status` differently from these
    // FFI bindings, so every field past the drift point decodes as unrelated
    // memory rather than as zero: a torrent added seconds ago reports 100%
    // with 0 bytes done, 0/1 pieces, and invented transfer rates. None of the
    // struct is trustworthy in that state, so publish nothing derived from it
    // instead of fiction — and above all never let a fabricated 100% reach
    // _detectCompletion, which would mark an empty file as finished.
    final bool bridgeUntrusted = !TorrentService.bridgeCompatible;
    // `isChecking`, `rawDownloaded` and `hasMetadata` are all struct reads, so
    // an untrusted bridge must not be allowed to bank a byte count as
    // "confirmed" — nor to trip the recovery recheck below, which would put a
    // healthy torrent through a full re-hash of every piece on the strength of
    // a garbage zero.
    if (!isChecking && !bridgeUntrusted) {
      rt.lastConfirmedDownloadedBytes = rawDownloaded;
      if (rt.resumeExpectedBytes > 0 && torrent.hasMetadata) {
        // The engine finished checking with nothing on disk while the resume
        // store claimed real progress: this build's native binary silently
        // dropped the add-time resume blob (no lt_add_torrent_file_resume /
        // lt_add_magnet_resume export). Recover the on-disk data with a
        // one-shot recheck rather than re-downloading from scratch.
        if (rawDownloaded <= 0 && !rt.resumeRecheckIssued) {
          rt.resumeRecheckIssued = true;
          _log.warning(
            'Add-time resume data did not take effect for torrent $id '
            '(expected ${rt.resumeExpectedBytes} bytes, engine reports 0); '
            'issuing one recovery recheck',
          );
          try {
            _torrentService.recheckTorrent(id);
          } catch (e, st) {
            _log.warning('Recovery recheck failed for $id', e, st);
          }
        } else if (rawDownloaded > 0) {
          rt.resumeExpectedBytes = 0;
        }
      }
    }

    int? selectiveDownloadedBytes;
    bool? hasEstimatedFileProgress;
    final bool hasSelectiveFiles = effectiveFiles != null &&
        effectiveFiles.any((f) =>
            (f['selected'] as bool?) == false ||
            (f['priority'] as int? ?? 4) == 0);
    if (torrent.fileProgress.isNotEmpty &&
        hasSelectiveFiles &&
        !isChecking &&
        !bridgeUntrusted) {
      int selectiveSum = 0;
      for (var i = 0; i < torrent.fileProgress.length; i++) {
        if (i < effectiveFiles.length) {
          final isSelected = (effectiveFiles[i]['selected'] as bool?) ?? true;
          final prio = effectiveFiles[i]['priority'] as int? ?? 4;
          if (isSelected && prio > 0) {
            selectiveSum += torrent.fileProgress[i];
          }
        }
      }
      selectiveDownloadedBytes = selectiveSum;
      hasEstimatedFileProgress = false;
    }

    if (totalSize <= 0 && !torrent.hasMetadata && torrent.piecesTotal <= 0) {
      // Same rule as the main path below: nothing read out of the status struct
      // may be published while the bridge is untrusted.
      final downloadedBytes = bridgeUntrusted ? 0 : rawDownloaded;
      final speed =
          bridgeUntrusted ? 0.0 : torrent.downloadPayloadRate.toDouble();
      tracker.lastTorrentSpeed = speed;
      tracker.lastTorrentPeerCount = bridgeUntrusted ? 0 : torrent.numPeers;
      emitProgress(DownloadProgress(
        downloadedBytes: downloadedBytes,
        fileSize: 0,
        speed: speed,
        eta: null,
        fileName: (torrent.hasMetadata && torrent.name.isNotEmpty) ? torrent.name : null,
        torrentFiles: bridgeUntrusted ? null : (resolvedFiles ?? rt.cachedAccurateFiles),
        cycleState: CycleState.fetchingMetadata,
        totalPieces: bridgeUntrusted ? 0 : torrent.piecesTotal,
        completedPieces: bridgeUntrusted ? null : torrent.piecesHave,
        statusMessage: bridgeUntrusted
            ? 'Torrent engine out of date — progress unavailable'
            : 'Fetching metadata…',
        torrentId: id,
        downloadedFileBytes: selectiveDownloadedBytes,
        hasEstimatedFileProgress: hasEstimatedFileProgress,
      ));
      return;
    }

    final bool isProgressValid = (torrent.hasMetadata || torrent.totalDone > 0) &&
        (torrent.totalWanted > 0 ||
            rawDownloaded > 0 ||
            stateLabel == 'seeding');
    // `torrent.progress` is only download progress outside a checking phase.
    // While checking, fall back to the last confirmed byte count so the bar
    // holds its previous position instead of tracking verification.
    final safeProgress = bridgeUntrusted
        ? 0.0
        : isChecking
            ? (totalSize > 0
                ? (rt.lastConfirmedDownloadedBytes / totalSize).clamp(0.0, 1.0)
                : 0.0)
            : (isProgressValid &&
                    torrent.progress.isFinite &&
                    torrent.progress > 0)
                ? torrent.progress.clamp(0.0, 1.0)
                : (rawDownloaded > 0 && totalSize > 0
                    ? (rawDownloaded / totalSize).clamp(0.0, 1.0)
                    : (torrent.totalDone > 0 && torrent.totalWanted > 0
                        ? (torrent.totalDone / torrent.totalWanted)
                            .clamp(0.0, 1.0)
                        : 0.0));
    final filesToUpdate = resolvedFiles ?? rt.cachedAccurateFiles;
    // Per-file byte counts reported during a checking phase are verification
    // counters, so leave the cached file list untouched until checking ends.
    // An untrusted bridge reports garbage per-file bytes for the same reason.
    if (filesToUpdate != null &&
        filesToUpdate.isNotEmpty &&
        !isChecking &&
        !bridgeUntrusted) {
      bool pieceMapped = false;

      if (torrent.fileProgress.isNotEmpty &&
          torrent.fileProgress.length == filesToUpdate.length) {
        for (var i = 0; i < filesToUpdate.length; i++) {
          final f = filesToUpdate[i];
          final dl = torrent.fileProgress[i];
          final len = (f['length'] as num?)?.toInt() ?? 0;
          // FIX(M3): Guard corrupt dl > len log spam
          if (dl > len && len > 0) {
            if (!rt.corruptSizeLogged) {
              rt.corruptSizeLogged = true;
              _log.warning(
                  'Corrupt size detected in torrent $id file ${f['name']}: dl=$dl > len=$len; clamping');
            }
          }
          final safeDl = len > 0 ? dl.clamp(0, len) : 0;
          f['downloadedBytes'] = safeDl;
          f['progressEstimated'] = false;
          if (len > 0) {
            f['progress'] = (safeDl / len).clamp(0.0, 1.0);
            f['isComplete'] = safeDl >= len;
          } else {
            f['progress'] = 0.0;
            f['isComplete'] = false;
          }
        }
        pieceMapped = true;
      } else if (fileCount > 1000) {
        try {
          final pieceProgress = await _torrentService.getPieceProgress(id);
          if (pieceProgress != null) {
            final piecesHave =
                (pieceProgress['piecesHave'] as num?)?.toInt() ?? 0;
            final piecesTotal =
                (pieceProgress['piecesTotal'] as num?)?.toInt() ?? 0;
            if (piecesTotal > 0) {
              final pieceRatio =
                  (piecesHave / piecesTotal).clamp(0.0, 1.0);
              TorrentFileProgressEstimator.updateFilesWithNativeProgress(
                filesToUpdate,
                pieceRatio,
                rawDownloaded,
                sequential: _torrentService.sequentialDownloadEnabled,
              );
              pieceMapped = true;
            }
          }
        } catch (e, st) {
          _log.fine('Piece progress query failed: $e', e, st);
        }
      }

      if (!pieceMapped) {
        TorrentFileProgressEstimator.updateFilesWithNativeProgress(
          filesToUpdate,
          safeProgress,
          rawDownloaded,
          sequential: _torrentService.sequentialDownloadEnabled,
        );
      }
      resolvedFiles = filesToUpdate;
      rt.cachedAccurateFiles = filesToUpdate;
    }

    final downloadedBytes =
        isChecking ? rt.lastConfirmedDownloadedBytes : rawDownloaded;
    final speed = torrent.downloadPayloadRate.toDouble();
    // The stall watchdog reads these back, so an untrusted bridge must not seed
    // them with struct noise.
    tracker.lastTorrentSpeed = bridgeUntrusted ? 0.0 : speed;
    tracker.lastTorrentPeerCount = bridgeUntrusted ? 0 : torrent.numPeers;
    var resolvedCycleState = CycleState.fromLibtorrent(
      torrent.stateLabel,
      seedingEnabled: _torrentService.seedingEnabled,
    );
    var resolvedStatusMessage = torrent.stateLabel;
    if (isChecking) {
      // Surface verification as its own phase with its own percentage, so the
      // UI shows "Verifying files… 43%" instead of a frozen or fake download
      // percentage.
      resolvedCycleState = CycleState.verifying;
      resolvedStatusMessage =
          'Verifying files… ${(verificationProgress * 100).toStringAsFixed(0)}%';
    }
    if (bridgeUntrusted) {
      // The transfer itself may well be running; it is only the reporting that
      // is unreadable. Say that plainly instead of showing invented figures.
      //
      // `stateLabel` comes out of the same garbage struct, so the state derived
      // from it is fiction too — it is what put a "Re-verifying" chip on a
      // torrent that was actually downloading. Report the phase the task is
      // genuinely in from the app's own point of view instead of the engine's.
      resolvedCycleState = CycleState.downloading;
      resolvedStatusMessage =
          'Torrent engine out of date — progress unavailable';
      if (!rt.bridgeMismatchLogged) {
        rt.bridgeMismatchLogged = true;
        _log.severe(
          'Suppressing torrent stats for $id: the native bridge does not match '
          'these FFI bindings, so lt_torrent_status decodes as garbage. '
          'Rebuild liblibtorrent_flutter from src/torrent_bridge.cpp. '
          '${TorrentService.bridgeDiagnostics ?? ''}',
        );
      }
    }
    // Stall detection compares byte counts and rates across ticks. Both are
    // struct noise while the bridge is untrusted, so there is no way to tell a
    // stalled torrent from a healthy one — and guessing "stalled" would put a
    // false label on a download that is in fact running.
    if (!bridgeUntrusted &&
        (speed > 0 ||
            downloadedBytes != tracker.lastTorrentDownloadedBytes)) {
      tracker.lastTorrentDownloadedBytes = downloadedBytes;
      tracker.lastTorrentProgressTime = DateTime.now();
    } else if (!bridgeUntrusted && speed == 0) {
      final elapsed =
          DateTime.now().difference(tracker.lastTorrentProgressTime);
      final isNonDownloadPhase = torrent.isChecking ||
          torrent.state == TorrentState.downloadingMetadata ||
          torrent.state == TorrentState.allocating;
      if (!torrent.isPaused &&
          torrent.state != TorrentState.seeding &&
          torrent.state != TorrentState.error &&
          !isNonDownloadPhase) {
        if (elapsed >= const Duration(minutes: 5)) {
          if (torrent.state == TorrentState.downloading &&
              torrent.peerCount == 0) {
            resolvedStatusMessage = 'Stalled (no peers)';
            resolvedCycleState = CycleState.stalled;
          }
        } else if (elapsed >= const Duration(seconds: 60)) {
          resolvedStatusMessage = 'Looking for peers…';
          resolvedCycleState = CycleState.stalled;
        }
      }
    }

    final isRecovering =
        (previousState == 'stalled' || previousState == 'error') &&
            (torrent.state == TorrentState.downloading ||
                torrent.state == TorrentState.downloadingMetadata ||
                torrent.isChecking);
    final String? resolvedTorrentName =
        (torrent.hasMetadata && torrent.name.isNotEmpty)
            ? torrent.name
            : null;

    // `piecesHave` counts verified pieces while checking, so withholding it
    // keeps a piece-based progress bar on its last real value.
    final int? emittedCompletedPieces =
        (isChecking || bridgeUntrusted) ? null : torrent.piecesHave;

    // Byte counts, rates and piece totals all come out of the status struct, so
    // an untrusted bridge must report none of them. `totalSize` is kept: it is
    // derived from the parsed torrent metadata / resume store, not the struct.
    final int emittedDownloadedBytes = bridgeUntrusted ? 0 : downloadedBytes;
    final double emittedSpeed = bridgeUntrusted ? 0.0 : speed;
    final int emittedTotalPieces = bridgeUntrusted ? 0 : torrent.piecesTotal;

    // Per-file rows carry their own byte counts, and those are measurements too.
    // Withholding the list entirely would leave whatever a previous session
    // persisted on screen — which is exactly how a just-added torrent kept
    // showing "99%  6.0 GB / 6.1 GB". Publish the rows instead with their names
    // and lengths (parsed from metadata, trustworthy) and their measurements
    // cleared and flagged, so the stale figures get overwritten.
    var emittedTorrentFiles = resolvedFiles ?? rt.cachedAccurateFiles;
    if (bridgeUntrusted && emittedTorrentFiles != null) {
      emittedTorrentFiles = [
        for (final f in emittedTorrentFiles)
          <String, dynamic>{
            ...f,
            'downloadedBytes': 0,
            'progress': 0.0,
            'isComplete': false,
            'progressEstimated': true,
          }
      ];
    }
    final bool? emittedHasEstimatedFileProgress =
        bridgeUntrusted ? true : hasEstimatedFileProgress;

    if (isRecovering) {
      tracker.lastRecoveryEmit = DateTime.now();
      emitProgress(DownloadProgress(
        downloadedBytes: emittedDownloadedBytes,
        fileSize: totalSize,
        speed: emittedSpeed,
        eta: null,
        fileName: resolvedTorrentName,
        torrentFiles: emittedTorrentFiles,
        cycleState: CycleState.retrying,
        totalPieces: emittedTotalPieces,
        completedPieces: emittedCompletedPieces,
        statusMessage: 'Retrying torrent…',
        torrentId: id,
        downloadedFileBytes: selectiveDownloadedBytes,
        hasEstimatedFileProgress: emittedHasEstimatedFileProgress,
      ));
    }
    if (tracker.lastRecoveryEmit == null ||
        DateTime.now()
                .difference(tracker.lastRecoveryEmit!)
                .inMilliseconds >=
            2000) {
      emitProgress(DownloadProgress(
        downloadedBytes: emittedDownloadedBytes,
        fileSize: totalSize,
        speed: emittedSpeed,
        eta: null,
        fileName: resolvedTorrentName,
        torrentFiles: emittedTorrentFiles,
        cycleState: resolvedCycleState,
        totalPieces: emittedTotalPieces,
        completedPieces: emittedCompletedPieces,
        statusMessage: resolvedStatusMessage,
        torrentId: id,
        downloadedFileBytes: selectiveDownloadedBytes,
        hasEstimatedFileProgress: emittedHasEstimatedFileProgress,
      ));
    }

    // A checking torrent has no trustworthy completion signal: `progress` and
    // `totalWantedDone` are verification counters, so a torrent part-way
    // through a recheck can momentarily look finished. An untrusted bridge is
    // worse still — its garbage `progress` reads 1.0 on a torrent with zero
    // bytes on disk, which would mark a brand-new download complete.
    if (isChecking || bridgeUntrusted) return;

    _detectCompletion(
      id: id,
      torrent: torrent,
      totalSize: totalSize,
      downloadedBytes: downloadedBytes,
      speed: speed,
      resolvedTorrentName: resolvedTorrentName,
      resolvedFiles: resolvedFiles,
      hasReliableTotalSize: hasReliableTotalSize,
      stateLabel: stateLabel,
      emitProgress: emitProgress,
      completer: completer,
    );
  }

  void _detectCompletion({
    required int id,
    required TorrentUpdateInfo torrent,
    required int totalSize,
    required int downloadedBytes,
    required double speed,
    required String? resolvedTorrentName,
    required List<Map<String, dynamic>>? resolvedFiles,
    required bool hasReliableTotalSize,
    required String stateLabel,
    required void Function(DownloadProgress) emitProgress,
    required Completer<void> completer,
  }) {
    final rt = _getRuntime(id);
    // Verification counters can transiently satisfy every completion predicate
    // below, so a checking torrent is never treated as complete.
    if (torrent.isChecking) return;
    final bool isProgressComplete = (torrent.progress >= 0.999 && totalSize > 0) ||
        (totalSize > 0 && downloadedBytes >= totalSize) ||
        (torrent.totalWanted > 0 &&
            torrent.totalWantedDone >= torrent.totalWanted &&
            torrent.progress >= 0.999);
    final bool isSeedingComplete = (stateLabel == 'seeding' || stateLabel == 'finished') &&
        (isProgressComplete || (totalSize > 0 && downloadedBytes >= (totalSize * 0.99).toInt()));

    final bool isCompleted = torrent.hasMetadata &&
        hasReliableTotalSize &&
        (isProgressComplete || isSeedingComplete);
    if (!isCompleted) return;

    final isSeedingEnabled = _torrentService.seedingEnabled;
    final finalCycleState = (stateLabel == 'seeding' && isSeedingEnabled)
        ? CycleState.seeding
        : CycleState.completed;
    final finalStatusMessage = (stateLabel == 'seeding' && isSeedingEnabled)
        ? 'Seeding…'
        : 'Completed';
    final List<Map<String, dynamic>>? finalFiles =
        resolvedFiles ?? rt.cachedAccurateFiles;
    if (finalFiles != null && finalFiles.isNotEmpty) {
      for (final f in finalFiles) {
        final len = (f['length'] as num?)?.toInt() ?? 0;
        final isSelected = isTorrentFileSelected(f);
        if (isSelected && len > 0) {
          f['downloadedBytes'] = len;
          f['progress'] = 1.0;
          f['isComplete'] = true;
          f['progressEstimated'] = false;
        } else if (!isSelected) {
          f['downloadedBytes'] = 0;
          f['progress'] = 0.0;
          f['isComplete'] = false;
          f['progressEstimated'] = false;
        }
      }
    }
    emitProgress(DownloadProgress(
      downloadedBytes: totalSize > 0 ? totalSize : downloadedBytes,
      fileSize: totalSize,
      speed: isSeedingEnabled ? speed : 0,
      eta: 0,
      fileName: resolvedTorrentName,
      torrentFiles: finalFiles,
      cycleState: finalCycleState,
      totalPieces: torrent.piecesTotal,
      completedPieces: torrent.piecesTotal,
      statusMessage: finalStatusMessage,
      torrentId: id,
    ));

    _activeTorrentIds.remove(id);
    TorrentSubscriptionRegistry.instance.unregister(id, this);
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  Future<void> _cleanup(int id, StreamSubscription? sub) async {
    final rt = _runtime.remove(id);
    rt?.close();
    await sub?.cancel();
    _activeTorrentIds.remove(id);
    TorrentSubscriptionRegistry.instance.unregister(id, this);
  }
}

class _TorrentTrackerState {
  DateTime lastTorrentProgressTime = DateTime.now();
  int lastTorrentDownloadedBytes = 0;
  double lastTorrentSpeed = 0.0;
  int lastTorrentPeerCount = 0;
  int currentTotalSize = 0;
  DateTime? lastRecoveryEmit;
}
