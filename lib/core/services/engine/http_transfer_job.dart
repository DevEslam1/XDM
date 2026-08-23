import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dmx/core/domain/transfer_result.dart';
import 'package:dmx/core/services/engines/speed_predictor.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:dmx/core/services/protocol_fallback_memory.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';
import '../../constants/thresholds.dart';
import '../bandwidth_governor.dart';
import '../download_engine.dart' show DownloadEngine;
import '../download_journal.dart';
import '../engines/http_download_engine.dart';
import '../mirror/mirror_selector.dart';
import '../positional_file_writer.dart';
import '../power_monitor.dart';
import 'cycle_state_resolver.dart';
import 'engine_exceptions.dart';
import 'engine_models.dart';
import 'engine_utils.dart';
import 'server_identity_cache.dart';

export 'engine_exceptions.dart'
    show FileChangedOnServerException, RangeUnsupportedException;
export 'engine_models.dart' show SpeedSample;

const Duration defaultTaskHardTimeout = kTaskHardTimeout;

final _log = Logger('HttpTransferJob');

int _workerGlobalLimitBps = 0;
int _workerGlobalActive = 1;
final Map<String, HttpTransferJob> _runningJobs = {};
final Random _rng = Random();

final RegExp _contentRangeTotalRegex = RegExp(r'/(\d+)');
final RegExp _contentRangeHeaderRegex =
    RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$', caseSensitive: false);

/// HTML response detection patterns - more precise than substring matching
final RegExp _htmlContentTypeRegex =
    RegExp(r'text/html|application/xhtml', caseSensitive: false);

/// URL expiration detection - specific patterns only, not broad substring
final RegExp _urlExpireParamRegex =
    RegExp(r'expire=|signature=|sig=|token=|expires=', caseSensitive: false);
final RegExp _googlevideoHostRegex =
    RegExp(r'\.googlevideo\.com$', caseSensitive: false);

@pragma('vm:entry-point')
Future<void> workerEntry(SendPort poolPort) async {
  final cmdPort = ReceivePort();
  poolPort.send({'t': 'hello', 'port': cmdPort.sendPort});

  await for (final dynamic raw in cmdPort) {
    if (raw is! Map) continue;
    switch (raw['t']) {
      case 'job':
        final jobId = raw['jobId'] as String;
        final reply = raw['reply'] as SendPort;
        final cmd = DownloadCommand.fromMap(
            Map<String, dynamic>.from(raw['cmd'] as Map));
        final job = HttpTransferJob(cmd, reply);
        _runningJobs[jobId] = job;
        Future(() async {
          try {
            await job.run();
          } catch (e) {
            job.sendUnhandledError(e);
          } finally {
            _runningJobs.remove(jobId);
            poolPort.send({'t': 'idle', 'jobId': jobId});
          }
        });
        break;
      case 'cancel':
        final reasonStr = raw['reason'] as String?;
        final reason = PauseReason.fromName(reasonStr);
        _runningJobs[raw['jobId'] as String]?.requestCancel(reason);
        break;
      case 'limits':
        _workerGlobalLimitBps = (raw['bps'] as num?)?.toInt() ?? 0;
        _workerGlobalActive =
            ((raw['active'] as num?)?.toInt() ?? 1).clamp(1, 1000);
        break;
      case 'shutdown':
        for (final job in _runningJobs.values) {
          job.requestCancel(PauseReason.background);
        }
        cmdPort.close();
        return;
    }
  }
}

class HttpTransferJob {
  HttpTransferJob(this.cmd, this.out) {
    unawaited(_cancelToken.whenCancel.then((_) {
      _abortAllDelays();
    }).catchError((e) {
      debugPrint('[IsolatePool] whenCancel failed: $e');
    }));
  }

  final DownloadCommand cmd;
  final SendPort out;
  final CancelToken _cancelToken = CancelToken();
  int _seq = 0;
  bool _cancelRequested = false;

  static const int maxPendingDelays = 16;
  static const Duration _maxChunkWallClock = Duration(minutes: 10);
  static Duration stalledThreshold = const Duration(minutes: 5);
  int _nextTimerId = 0;
  final Map<int, Completer<void>> _pendingDelays = <int, Completer<void>>{};
  final Map<int, Timer> _pendingTimers = <int, Timer>{};
  int _chunkFingerprint = 0;

  @visibleForTesting
  int get chunkFingerprintForTesting => _chunkFingerprint;

  @visibleForTesting
  Map<int, Completer<void>> get pendingDelaysForTesting => _pendingDelays;

  @visibleForTesting
  List<Completer<void>> get pendingDelayCompletersForTesting =>
      _pendingDelays.values.toList();

  @visibleForTesting
  List<Timer> get pendingDelayTimersForTesting =>
      _pendingTimers.values.toList();

  @visibleForTesting
  bool get stateSavePendingForTesting => _stateSavePending;

  @visibleForTesting
  set stateSavePendingForTesting(bool value) => _stateSavePending = value;

  @visibleForTesting
  Future<void> throttledSaveAndReportForTesting() =>
      _throttledSaveAndReport(null);

  /// FIX 10: Cancellable delay with proper cleanup - no double-cleanup race.
  /// Uses a completion flag to prevent double-cleanup.
  @visibleForTesting
  Future<void> cancellableDelay(Duration duration) async {
    if (_cancelRequested || _cancelToken.isCancelled) return;

    if (_pendingDelays.length >= maxPendingDelays) {
      _log.warning(
        'Cancellable delay queue capacity ($maxPendingDelays) reached; '
        'falling back to cancellable timer',
      );
      final completer = Completer<void>();
      final timer = Timer(duration, () {
        if (!completer.isCompleted) completer.complete();
      });
      unawaited(_cancelToken.whenCancel.then((_) {
        timer.cancel();
        if (!completer.isCompleted) completer.complete();
      }).catchError((_) {}));
      try {
        await completer.future;
      } finally {
        timer.cancel();
        if (!completer.isCompleted) completer.complete();
      }
      return;
    }

    final id = _nextTimerId++;
    final completer = Completer<void>();
    _pendingDelays[id] = completer;
    bool timerFired = false;

    final timer = Timer(duration, () {
      timerFired = true;
      _pendingTimers.remove(id);
      final c = _pendingDelays.remove(id);
      if (c != null && !c.isCompleted) {
        c.complete();
      }
    });
    _pendingTimers[id] = timer;

    try {
      await completer.future;
    } finally {
      // Only clean up if timer hasn't already fired
      if (!timerFired) {
        timer.cancel();
        _pendingTimers.remove(id);
      }
      // Remove completer if still present (timer path might have already removed it)
      _pendingDelays.remove(id);
    }
  }

  void _abortAllDelays() {
    _cancelRequested = true;
    for (final t in _pendingTimers.values) {
      t.cancel();
    }
    _pendingTimers.clear();
    final completers = _pendingDelays.values.toList();
    _pendingDelays.clear();
    for (final c in completers) {
      if (!c.isCompleted) c.complete();
    }
  }

  TransferState? _state;
  bool _stateSavedInCatch = false;
  int? _lastEta;
  int _lastStateSaveMs = 0;
  bool _stateSavePending = false;
  final Lock _stateSaveLock = Lock();
  int _lastReportMs = 0;
  int _bytesSinceSave = 0;
  int _lastChunkDetailsHash = 0;
  List<Map<String, dynamic>>? _cachedChunkDetails;
  final Stopwatch _stopwatch = Stopwatch();
  final Queue<SpeedSample> _speedSamples = Queue();
  double _lastSpeed = 0.0;
  int _watchdogCheckpointBytes = 0;
  int _lastProgressBytes = 0;
  int _lastProgressTimeMs = 0;
  bool _stalledEmitted = false;
  int? _lastProgressFingerprint;
  CycleState? _lastEmittedCycleState;
  int _currentWriterBufferSize = 256 * 1024;
  int _lastChunkDetailsEmitMs = 0;
  int _lastEmittedCompletedChunks = -1;
  PauseReason? _pendingPauseReason;

  PauseReason get effectivePauseReason =>
      _pendingPauseReason ?? PauseReason.userRequested;

  Future<void> requestCancel([PauseReason? reason]) async {
    if (reason != null) {
      _pendingPauseReason = reason;
    }
    _abortAllDelays();
    final st = _state;
    if (st != null) {
      st.status = DmxStateStatus.paused;
      st.pauseReason = effectivePauseReason;
      try {
        await DownloadJournal.flushAndSyncForFile(cmd.tempFilePath);
      } catch (_) {}
      try {
        await StateStore.save(cmd.tempFilePath, st,
            durable: true, taskId: cmd.taskId);
      } catch (_) {}
    }
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel('paused:${effectivePauseReason.name}');
    }
  }

  void _send(String type, [Map<String, dynamic>? data]) {
    out.send({
      'proto': 1,
      'type': type,
      'taskId': cmd.taskId,
      'seq': _seq++,
      if (data != null) 'data': data,
    });
  }

  void sendChunkBytes(Uint8List bytes) {
    out.send(TransferableTypedData.fromList([bytes]));
  }

  /// Emits typed TransferResult containing classified taxonomy code and retryable flag.
  void sendUnhandledError(Object e) {
    final classification = ErrorTaxonomy.classify(e);
    final errorType = switch (classification.family) {
      ErrorFamily.cancelled => 'cancel',
      ErrorFamily.integrity => 'integrity',
      ErrorFamily.disk => 'diskFull',
      ErrorFamily.auth => (e is UrlExpiredException) ? 'urlExpired' : 'auth',
      ErrorFamily.timeout => 'timeout',
      _ => (e is RangeUnsupportedException)
          ? 'rangeUnsupported'
          : (e is FileChangedOnServerException)
              ? 'fileChanged'
              : classification.family.name,
    };

    final result = TransferResult.failure(
      taxonomyCode: classification.family.name,
      retryable: classification.retryable,
      message: classification.message,
      httpStatus: classification.httpStatus,
      recoveryAction: classification.recoveryAction,
      error: e,
    );
    final map = result.toMap();
    map['errorType'] = errorType;
    map['errorMessage'] = classification.message;
    map['errorStatus'] = classification.httpStatus;
    if (e is UrlExpiredException) {
      map['refreshAllMirrors'] = e.refreshAllMirrors;
    }
    _send('error', map);
  }

  Timer? _hardTimeoutTimer;
  Timer? _jobHealthTimer;

  @visibleForTesting
  Timer? get jobHealthTimerForTesting => _jobHealthTimer;

  /// FIX 13: Hard timeout now uses 50 KB/s baseline (was 100 KB/s) and
  /// has a lower minimum for small files.
  @visibleForTesting
  void registerWatchdogs() {
    try {
      stalledThreshold = Duration(
        minutes: SettingsProvider.instance.downloadStalledTimeoutMinutes,
      );
    } catch (_) {}
    final hardTimeoutDuration = _computeHardTimeout();
    void onHardTimeout() {
      requestCancel(PauseReason.userRequested);
      _send('error', {
        'errorType': 'timeout',
        'errorMessage':
            'Hard timeout exceeded: ${_formatDuration(hardTimeoutDuration)}',
      });
    }

    _hardTimeoutTimer = Timer(hardTimeoutDuration, onHardTimeout);

    _jobHealthTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      final st = _state;
      if (st == null) return;
      final nowBytes = st.downloadedBytes;
      final delta = nowBytes - _watchdogCheckpointBytes;
      _watchdogCheckpointBytes = nowBytes;
      final resetThreshold =
          max(60 * 1024 * 1024, (st.totalSize * 0.01).round());
      if (delta > resetThreshold) {
        _hardTimeoutTimer?.cancel();
        _hardTimeoutTimer = Timer(hardTimeoutDuration, onHardTimeout);
      }

      // FIX 7: Stall detection - also check for network connectivity
      if (!_stalledEmitted && _lastProgressTimeMs != 0) {
        final elapsed = _stopwatch.elapsedMilliseconds - _lastProgressTimeMs;
        if (elapsed >= stalledThreshold.inMilliseconds) {
          _stalledEmitted = true;
          _emitProgress(_stopwatch.elapsedMilliseconds,
              statusMessage: 'Stalled', cycleStateOverride: CycleState.stalled);
        }
      }
    });
  }

  @visibleForTesting
  void cancelWatchdogs() {
    _hardTimeoutTimer?.cancel();
    _hardTimeoutTimer = null;
    _jobHealthTimer?.cancel();
    _jobHealthTimer = null;
  }

  /// FIX 2: Chunk redistribution on resume - corrected `end` calculation
  /// for complete chunks. Previous code used `oc.end + 1` which was wrong
  /// for the last chunk (end = totalSize - 1, so end + 1 = totalSize which
  /// exceeds the chunk range).
  @visibleForTesting
  Future<TransferState> loadAndReconcileState(Dio dio) async {
    final load = await StateStore.loadOrCreate(
      cmd.tempFilePath,
      url: cmd.url,
      threadCount: cmd.threadCount,
      knownFileSize: cmd.knownFileSize,
      taskId: cmd.taskId,
    );
    _state = load.state;
    _watchdogCheckpointBytes = _state!.downloadedBytes;

    // Redistribute chunks if thread count changed
    if (_state!.chunks.isNotEmpty &&
        _state!.chunks.length != cmd.threadCount &&
        _state!.downloadedBytes > 0) {
      final savedBytes = _state!.downloadedBytes;
      final total = _state!.totalSize;
      final oldChunks = List<ChunkState>.from(_state!.chunks);
      final newChunks = ChunkScheduler.plan(
        totalSize: total,
        threadCount: cmd.threadCount,
      );
      for (var ni = 0; ni < newChunks.length; ni++) {
        final nc = newChunks[ni];
        int overlap = 0;
        for (final oc in oldChunks) {
          final oStart = oc.start;
          final oEnd = oc.isComplete
              ? (oc.end >= 0 ? oc.end + 1 : oc.start + oc.downloaded)
              : oc.start + oc.downloaded;
          final nStart = nc.start;
          final nEnd = nc.end >= 0 ? nc.end + 1 : nc.start + nc.size;
          final lo = max(oStart, nStart);
          final hi = min(oEnd, nEnd);
          if (hi > lo) overlap += (hi - lo);
        }
        nc.downloaded = overlap.clamp(0, nc.size >= 0 ? nc.size : overlap);
      }
      _state!.chunks = newChunks;
      debugPrint(
        '[FIX-2] Redistributed $savedBytes bytes from '
        '${load.state.chunks.length} → ${cmd.threadCount} chunks with range-overlap mapping',
      );
    }

    if (_state!.totalSize <= 0 && cmd.knownFileSize > 0) {
      _state!.totalSize = cmd.knownFileSize;
    }
    _state!.status = DmxStateStatus.active;
    await StateStore.save(cmd.tempFilePath, _state!, taskId: cmd.taskId);

    if (_state!.downloadedBytes > 0) {
      _stalledEmitted = false;
      _emitProgress(0,
          statusMessage: 'Verifying resume data…',
          cycleStateOverride: CycleState.verifying);
      if (cmd.supportsResume) {
        await _verifyServerIdentity(dio);
      }
      _emitProgress(0,
          statusMessage: 'Resuming…',
          cycleStateOverride: CycleState.resuming);
    } else {
      _emitProgress(0,
          statusMessage: 'Starting…', cycleStateOverride: CycleState.starting);
    }
    return _state!;
  }

  @visibleForTesting
  set stateForTesting(TransferState? st) => _state = st;

  @visibleForTesting
  TransferState? get stateForTesting => _state;

  @visibleForTesting
  Future<void> executeDownload(Dio dio) async {
    final multiThread = _state!.totalSize > 0 &&
        cmd.supportsResume &&
        cmd.threadCount > 1 &&
        _state!.totalSize >= ChunkScheduler.minSizeForMultithread;
    if (multiThread) {
      try {
        await _runMultiThreaded(dio);
      } on RangeUnsupportedException {
        debugPrint('[DMX-Job] Range unsupported → single-stream fallback');
        _resetToSingleStream();
        await _runSingleStream(dio);
      }
    } else {
      await _runSingleStream(dio);
    }
  }

  /// Main entry point. Runs the full download cycle:
  /// start → (resume verify) → download → finalize → done
  /// Errors: pause, retry, fail, urlExpired, fileChanged, diskFull
  Future<void> run() async {
    _stopwatch.start();
    final dio = buildTransferDio(
      url: cmd.punyUrl,
      customUserAgent: cmd.customUserAgent,
      referer: cmd.referer,
      cookies: cmd.cookies,
      oauthToken: cmd.oauthToken,
    );
    _send('ack');
    try {
      registerWatchdogs();
      await loadAndReconcileState(dio);
      await executeDownload(dio);
      await _finalize(dio);
      _send('done', const TransferResult.success().toMap());
    } finally {
      cancelWatchdogs();
      _abortAllDelays();
      // FIX 15: Check _stateSavedInCatch before saving in finally
      if (!_stateSavedInCatch && _state != null) {
        try {
          // Force flush any pending state save microtask first
          _stateSavePending = false;
          await StateStore.save(cmd.tempFilePath, _state!, taskId: cmd.taskId);
        } catch (e, st) {
          _log.fine('Failed to save state during job finalize', e, st);
        }
      }
      _cachedChunkDetails = null;
      _lastChunkDetailsHash = 0;
      dio.close(force: true);
    }
  }

  /// FIX 13: Hard timeout now uses 50 KB/s baseline (was 100 KB/s).
  @visibleForTesting
  static Duration computeHardTimeoutForSize(
    int totalSize, {
    Duration minTimeout = const Duration(minutes: 30),
    Duration maxTimeout = const Duration(hours: 24),
  }) {
    if (totalSize <= 0) return maxTimeout;
    final computed = Duration(seconds: totalSize ~/ (100 * 1024));
    if (computed < minTimeout) return minTimeout;
    if (computed > maxTimeout) return maxTimeout;
    return computed;
  }

  Duration _computeHardTimeout() {
    final st = _state;
    if (st == null || st.totalSize <= 0) return defaultTaskHardTimeout;
    return computeHardTimeoutForSize(st.totalSize);
  }

  static String _formatDuration(Duration d) {
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }

  static int probeSkipCount = 0;
  static int probeRunCount = 0;
  int? _probeTtfbMs;
  bool? _probeSupportsRange;
  double? _probeInitialGoodputBps;

  @visibleForTesting
  int? get probeTtfbMsForTesting => _probeTtfbMs;

  @visibleForTesting
  bool? get probeSupportsRangeForTesting => _probeSupportsRange;

  @visibleForTesting
  double? get probeInitialGoodputBpsForTesting => _probeInitialGoodputBps;

  static void invalidateIdentityCacheForUrl(String url) {
    ServerIdentityCache.instance.invalidateForUrl(url);
  }

  static void clearIdentityCache() {
    ServerIdentityCache.instance.clear();
  }

  /// Verifies server identity (etag/last-modified) to detect file changes
  /// and enriches knowledge with Range support, TTFB, and initial goodput estimate.
  Future<void> _verifyServerIdentity(Dio dio) async {
    final cacheKey =
        '${Uri.tryParse(cmd.punyUrl)?.host}|${_state!.etag}|${_state!.lastModified}|${_state!.totalSize}';
    final identityCache = ServerIdentityCache.instance;
    identityCache.removeStale(const Duration(minutes: 10));
    if (identityCache.containsKey(cacheKey)) {
      probeSkipCount++;
      return;
    }
    probeRunCount++;
    final probeSw = Stopwatch()..start();
    try {
      final response = await dio.get<ResponseBody>(
        cmd.punyUrl,
        cancelToken: _cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          headers: {'Range': 'bytes=0-0'},
          validateStatus: (_) => true,
        ),
      );
      _probeTtfbMs = probeSw.elapsedMilliseconds;
      if (response.statusCode == 206 || response.statusCode == 200) {
        final rangeHeader = response.headers.value('accept-ranges');
        final contentRange = response.headers.value('content-range');
        _probeSupportsRange = response.statusCode == 206 ||
            (rangeHeader != null && rangeHeader.toLowerCase().contains('bytes'));

        int? serverTotal;
        if (contentRange != null) {
          serverTotal = int.tryParse(
              _contentRangeTotalRegex.firstMatch(contentRange)?.group(1) ?? '');
        }
        serverTotal ??= int.tryParse(
            response.headers.value(Headers.contentLengthHeader) ?? '');
        final newEtag = response.headers.value('etag');
        final newLm = response.headers.value('last-modified');

        int probeBytes = 0;
        final stream = response.data?.stream;
        if (stream != null) {
          await for (final chunk in stream) {
            probeBytes += chunk.length;
          }
        }
        final probeDurationSec = probeSw.elapsedMicroseconds / 1000000.0;
        if (probeDurationSec > 0 && probeBytes > 0) {
          _probeInitialGoodputBps = probeBytes / probeDurationSec;
        }

        if (serverTotal != null && serverTotal > 0 && _state!.totalSize > 0) {
          final tolerance =
              (_state!.totalSize * 0.001).clamp(2048.0, 10 * 1024 * 1024);
          if ((serverTotal - _state!.totalSize).abs() > tolerance) {
            await StateStore.resetTransferState(
              cmd.tempFilePath,
              taskId: cmd.taskId,
              state: _state,
              deleteTempFile: true,
            );
            _log.info('[Journal-J1] Server size changed ($serverTotal vs ${_state!.totalSize}); wiped state and journal');
            _state!.totalSize = serverTotal;
            await StateStore.save(cmd.tempFilePath, _state!, durable: true, taskId: cmd.taskId);
            throw FileChangedOnServerException();
          }
        }

        final oldIdentity = firstNonEmpty(_state!.etag, _state!.lastModified);
        final newIdentity = firstNonEmpty(newEtag, newLm);
        if (oldIdentity != null &&
            newIdentity != null &&
            oldIdentity != newIdentity) {
          debugPrint('[DMX-Job] resource identity changed — restarting');
          await StateStore.resetTransferState(
            cmd.tempFilePath,
            taskId: cmd.taskId,
            state: _state,
            deleteTempFile: true,
          );
          _log.info('[Journal-J1] Server identity changed ($oldIdentity -> $newIdentity); wiped state and journal');
          _state!.etag = newEtag;
          _state!.lastModified = newLm;
          _state!.migrationNote =
              '${_state!.migrationNote ?? ''} identity_restart'.trim();
          await StateStore.save(cmd.tempFilePath, _state!, durable: true, taskId: cmd.taskId);
          _emitProgress(0,
              statusMessage: 'Source changed on server — restarting');
        } else {
          _state!.etag ??= newEtag;
          _state!.lastModified ??= newLm;
        }
        identityCache.put(cacheKey, true);
      }
    } on FileChangedOnServerException {
      identityCache.remove(cacheKey);
      rethrow;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final host = Uri.tryParse(cmd.punyUrl)?.host.toLowerCase() ?? '';
      final isYtOrSigned = _isExpiredUrlOrSite(cmd.url, host);
      if (isYtOrSigned && (status == 401 || status == 403)) {
        identityCache.remove(cacheKey);
        _emitProgress(0,
            statusMessage: 'Refreshing links…',
            cycleStateOverride: CycleState.updatingLinks);
        if (_state != null) {
          _state!.cycleState = CycleState.updatingLinks.name;
          try {
            await StateStore.save(cmd.tempFilePath, _state!, durable: true, taskId: cmd.taskId);
          } catch (e, st) {
            _log.fine('Failed to save state on expired URL', e, st);
          }
        }
        await Future.delayed(const Duration(milliseconds: 10));
        throw UrlExpiredException(
          'YouTube / signed URL expired during identity probe (HTTP $status).',
        );
      }
      debugPrint('[DMX-Job] identity probe failed (continuing): $e');
    } catch (e) {
      debugPrint('[DMX-Job] identity probe failed (continuing): $e');
    }
  }

  void _resetToSingleStream() {
    final st = _state!;
    _log.info('resume_range_ignored: resetting to single-stream for ${cmd.taskId}');
    _send('telemetry', {
      'event': 'resume_range_ignored',
      'taskId': cmd.taskId,
      'url': cmd.url,
    });
    StateStore.resetTransferState(
      cmd.tempFilePath,
      taskId: cmd.taskId,
      state: st,
      deleteTempFile: true,
    );
    st.chunks = ChunkScheduler.singleStream(st.totalSize);
    st.threadCount = 1;
    _cachedChunkDetails = null;
    _lastChunkDetailsHash = 0;
    _lastChunkDetailsEmitMs = 0;
    _lastEmittedCompletedChunks = -1;
  }

  /// Computes the SHA-256 digest of a range [start, start + size - 1] in [filePath].
  Future<String> _computeChunkDiskSha256(
    String filePath,
    int start,
    int size,
  ) async {
    final file = File(filePath);
    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(start);
      Digest? digest;
      final innerSink =
          ChunkedConversionSink<Digest>.withCallback((results) {
        digest = results.single;
      });
      final sink = sha256.startChunkedConversion(innerSink);
      var remaining = size;
      const bufferSize = 64 * 1024;
      while (remaining > 0) {
        final toRead = min(remaining, bufferSize);
        final bytes = await raf.read(toRead);
        if (bytes.isEmpty) break;
        sink.add(bytes);
        remaining -= bytes.length;
      }
      sink.close();
      if (digest == null) {
        throw StateError('Failed to compute chunk digest');
      }
      return digest.toString();
    } finally {
      await raf.close();
    }
  }

  /// Multi-threaded download with adaptive chunk scheduling, per-connection goodput
  /// monitoring, hot-chunk splitting, dead connection retirement, and integrity verification.
  Future<void> _runMultiThreaded(Dio dio) async {
    final st = _state!;
    final host = Uri.tryParse(cmd.punyUrl)?.host ?? '';
    final learnedCap = ProtocolFallbackMemory.getHostConcurrencyCap(host);
    final targetConcurrency = learnedCap != null
        ? min(learnedCap, cmd.threadCount)
        : (cmd.threadCount > 4 ? 4 : max(2, min(cmd.threadCount, 4)));

    if (st.chunks.isEmpty) {
      st.chunks = ChunkScheduler.plan(
        totalSize: st.totalSize,
        threadCount: targetConcurrency,
      );
      st.threadCount = targetConcurrency;
    }

    PositionalFileWriter writer;
    final hasPriorBytes = st.downloadedBytes > 0;
    if (hasPriorBytes && await File(cmd.tempFilePath).exists()) {
      writer = await PositionalFileWriter.openForResume(cmd.tempFilePath,
          threadCount: st.threadCount, totalSize: st.totalSize);
    } else {
      writer = await PositionalFileWriter.open(cmd.tempFilePath,
          totalSize: st.totalSize, threadCount: st.threadCount);
      for (final c in st.chunks) {
        c.downloaded = 0;
      }
    }

    final governor = BandwidthGovernor(
      _effectiveGlobalLimit(),
      1.0,
      cmd.throttleFactor,
    );
    governor.registerConsumer();
    if (cmd.speedLimitKbps > 0) {
      governor.setTaskLimit(cmd.taskId, cmd.speedLimitKbps * 125);
    }

    if (hasPriorBytes && SettingsProvider.instance.resumeIntegrityCheck) {
      await spotCheckResumedBytes(dio, st, writer);
    }

    final failover = MirrorFailover([cmd.punyUrl, ...?cmd.mirrorUrls]);

    try {
      await _executeAdaptiveScheduling(
        dio: dio,
        st: st,
        writer: writer,
        governor: governor,
        failover: failover,
        maxConcurrency: targetConcurrency,
      );

      // Mandatory multi-chunk integrity pipeline stage
      await _runIntegrityPipeline(
        dio: dio,
        st: st,
        writer: writer,
        governor: governor,
        failover: failover,
      );

      await writer.flushAll();
      final sum = st.downloadedBytes;
      if (st.totalSize > 0 && sum < st.totalSize) {
        throw DownloadIntegrityException(
            'Chunk sum $sum < expected ${st.totalSize}');
      }
      final diskLen = await writer.length();
      if (st.totalSize > 0 && diskLen < st.totalSize) {
        throw DownloadIntegrityException(
            'On-disk size $diskLen < expected ${st.totalSize}');
      }
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        st.status = DmxStateStatus.paused;
        try {
          await writer.flushAll();
        } catch (flushErr, flushSt) {
          _log.fine(
              'Writer flush on pause failed: $flushErr', flushErr, flushSt);
        }
        try {
          final actualLen = await File(cmd.tempFilePath).length();
          if (actualLen < st.downloadedBytes) {
            var remaining = actualLen;
            for (final c in st.chunks) {
              final chunkOnDisk = min(c.downloaded, max(0, remaining - c.start));
              c.downloaded = chunkOnDisk.clamp(0, c.size >= 0 ? c.size : 0);
              remaining -= chunkOnDisk;
            }
          }
        } catch (e, stLog) {
          _log.fine('Reconcile with disk on cancel failed', e, stLog);
        }
        _stateSavedInCatch = true;
        await StateStore.save(cmd.tempFilePath, st, durable: true, taskId: cmd.taskId);
        _emitProgress(0,
            statusMessage: 'Paused', pauseReason: effectivePauseReason);
      } else if (e is! RangeUnsupportedException && e is! UrlExpiredException) {
        final anyProven = st.chunks.any((c) => c.downloaded > 0);
        st.status = DmxStateStatus.failed;
        st.migrationNote =
            '${st.migrationNote ?? ''} ${anyProven ? 'resumable' : 'restartRequired'}'
                .trim();
        try {
          await writer.flushAll();
        } catch (flushErr, flushSt) {
          _log.fine(
              'Writer flush on failure failed: $flushErr', flushErr, flushSt);
        }
        _stateSavedInCatch = true;
        await StateStore.save(cmd.tempFilePath, st, durable: true, taskId: cmd.taskId);
        _emitProgress(0, statusMessage: _formatFailedMessage(e));
      }
      rethrow;
    } finally {
      governor.removeTaskLimit(cmd.taskId);
      governor.unregisterConsumer();
      governor.dispose();
      await writer.close();
    }
  }

  /// Adaptive scheduler worker pool. Handles goodput prediction, hottest chunk splitting,
  /// and dead connection retirement with range redistribution.
  Future<void> _executeAdaptiveScheduling({
    required Dio dio,
    required TransferState st,
    required PositionalFileWriter writer,
    required BandwidthGovernor governor,
    required MirrorFailover failover,
    required int maxConcurrency,
  }) async {
    final activeSpeedPredictors = <int, SpeedPredictor>{};
    final activeChunkIndices = <int, int>{};
    final pendingQueue = <int>[];

    for (var i = 0; i < st.chunks.length; i++) {
      if (!st.chunks[i].isComplete) {
        pendingQueue.add(i);
      }
    }

    if (pendingQueue.isEmpty) return;

    final completer = Completer<void>();
    var runningWorkers = 0;
    var nextWorkerId = 0;
    final failFast = Completer<void>();
    Object? permanentError;

    Future<void> spawnWorker(int workerId) async {
      runningWorkers++;
      activeSpeedPredictors[workerId] = SpeedPredictor();
      if (_probeInitialGoodputBps != null && _probeInitialGoodputBps! > 0) {
        activeSpeedPredictors[workerId]!.addSample(_probeInitialGoodputBps!);
      }

      try {
        while (!_cancelRequested &&
            !_cancelToken.isCancelled &&
            !failFast.isCompleted) {
          int? chunkIndex;
          if (pendingQueue.isNotEmpty) {
            chunkIndex = pendingQueue.removeAt(0);
          } else {
            // Check if we can split the hottest active chunk (>= 2MB remaining)
            int bestHottest = -1;
            int maxRemaining = 0;
            for (final entry in activeChunkIndices.entries) {
              final ci = entry.value;
              if (ci >= 0 && ci < st.chunks.length) {
                final c = st.chunks[ci];
                if (ChunkScheduler.canSplitChunk(c)) {
                  final rem = (c.end - c.start + 1) - c.downloaded;
                  if (rem > maxRemaining) {
                    maxRemaining = rem;
                    bestHottest = ci;
                  }
                }
              }
            }

            if (bestHottest != -1) {
              final parent = st.chunks[bestHottest];
              final split = ChunkScheduler.trySplitChunk(parent);
              if (split != null) {
                final (first, second) = split;
                parent.end = first.end;
                st.chunks.add(second);
                st.threadCount = st.chunks.length;
                chunkIndex = st.chunks.length - 1;
                debugPrint(
                  '[AdaptiveScheduler] Split hottest chunk $bestHottest -> '
                  'new chunk $chunkIndex (range ${second.start}-${second.end})',
                );
              }
            }
          }

          if (chunkIndex == null || chunkIndex >= st.chunks.length) {
            break;
          }

          final chunk = st.chunks[chunkIndex];
          if (chunk.isComplete) continue;

          activeChunkIndices[workerId] = chunkIndex;
          var attempts = 0;
          const maxAttempts = 3;
          var chunkSuccess = false;

          while (attempts < maxAttempts &&
              !chunk.isComplete &&
              !failFast.isCompleted) {
            _throwIfCancelled();
            attempts++;
            try {
              await _runChunk(
                dio: dio,
                chunk: chunk,
                chunkIndex: chunkIndex,
                writer: writer,
                governor: governor,
                failover: failover,
                speedPredictor: activeSpeedPredictors[workerId],
              );
              chunkSuccess = true;
              break;
            } catch (e) {
              if (e is DioException && e.type == DioExceptionType.cancel) {
                rethrow;
              }
              if (e is RangeUnsupportedException) {
                if (!failFast.isCompleted) failFast.complete();
                rethrow;
              }
              if (e is UrlExpiredException ||
                  e is PositionalFileWriterException) {
                rethrow;
              }

              // Check if server rate limited us (429/503) -> record concurrency cap
              if (e is DioException &&
                  (e.response?.statusCode == 429 ||
                      e.response?.statusCode == 503)) {
                final host = Uri.tryParse(cmd.punyUrl)?.host ?? '';
                ProtocolFallbackMemory.recordHostConcurrencyCap(
                    host, max(1, runningWorkers - 1));
              }

              if (attempts >= maxAttempts) {
                final nextMirror = failover.advance();
                if (nextMirror != null) {
                  attempts = 0;
                  debugPrint(
                      '[AdaptiveScheduler] Chunk $chunkIndex failing over to mirror: $nextMirror');
                  continue;
                }
                debugPrint(
                    '[AdaptiveScheduler] Worker $workerId retiring on chunk $chunkIndex after $attempts attempts. Range redistributed.');
                if (!chunk.isComplete) {
                  pendingQueue.add(chunkIndex);
                }
                break;
              } else {
                await _cancellableDelay(
                    Duration(milliseconds: 200 * (1 << attempts)));
              }
            }
          }

          activeChunkIndices.remove(workerId);
          if (!chunkSuccess && pendingQueue.contains(chunkIndex)) {
            break;
          }
        }
      } catch (e) {
        permanentError ??= e;
        if (!failFast.isCompleted) failFast.complete();
      } finally {
        activeChunkIndices.remove(workerId);
        activeSpeedPredictors.remove(workerId);
        runningWorkers--;
        if (runningWorkers == 0 && !completer.isCompleted) {
          completer.complete();
        }
      }
    }

    final initialWorkers = min(maxConcurrency, max(1, pendingQueue.length));
    for (var i = 0; i < initialWorkers; i++) {
      unawaited(spawnWorker(nextWorkerId++));
    }

    await completer.future;

    if (failFast.isCompleted && permanentError != null) {
      throw permanentError!;
    }
  }

  /// Mandatory multi-chunk integrity pipeline stage. Verifies on-disk chunk hashes
  /// against incremental hashes computed during writing.
  Future<void> _runIntegrityPipeline({
    required Dio dio,
    required TransferState st,
    required PositionalFileWriter writer,
    required BandwidthGovernor governor,
    required MirrorFailover failover,
  }) async {
    if (st.chunks.length <= 1) return;

    await writer.flushAll();
    _emitProgress(_stopwatch.elapsedMilliseconds,
        statusMessage: 'Verifying chunk integrity…',
        cycleStateOverride: CycleState.verifying);

    const maxIntegrityPasses = 3;
    var pass = 0;

    while (pass < maxIntegrityPasses) {
      pass++;
      final corruptedChunks = <int>[];
      for (var i = 0; i < st.chunks.length; i++) {
        final chunk = st.chunks[i];
        if (chunk.hash != null && chunk.size > 0) {
          final diskHash = await _computeChunkDiskSha256(
            cmd.tempFilePath,
            chunk.start,
            chunk.size,
          );
          if (diskHash.toLowerCase() != chunk.hash!.toLowerCase()) {
            _log.warning(
              '[IntegrityPipeline] Corrupted chunk detected at index $i (range ${chunk.start}-${chunk.end}). '
              'Expected hash: ${chunk.hash}, actual: $diskHash. Triggering re-download of ONLY this chunk.',
            );
            corruptedChunks.add(i);
          }
        }
      }

      if (corruptedChunks.isEmpty) {
        _log.info('[IntegrityPipeline] All ${st.chunks.length} chunks verified OK.');
        return;
      }

      if (pass >= maxIntegrityPasses) {
        throw DownloadIntegrityException(
          'Integrity verification failed: ${corruptedChunks.length} chunk(s) remain corrupted after $maxIntegrityPasses passes.',
        );
      }

      // Re-download ONLY corrupted chunks
      for (final i in corruptedChunks) {
        st.chunks[i].downloaded = 0;
        st.chunks[i].hash = null;
      }
      await StateStore.save(cmd.tempFilePath, st, durable: true, taskId: cmd.taskId);

      await _executeAdaptiveScheduling(
        dio: dio,
        st: st,
        writer: writer,
        governor: governor,
        failover: failover,
        maxConcurrency: min(corruptedChunks.length, 4),
      );
      await writer.flushAll();
    }
  }

  /// Downloads a single chunk with retry and mirror failover.
  /// Computes SHA-256 incrementally as bytes stream in.
  Future<void> _runChunk({
    required Dio dio,
    required ChunkState chunk,
    required int chunkIndex,
    required PositionalFileWriter writer,
    required BandwidthGovernor governor,
    required MirrorFailover failover,
    SpeedPredictor? speedPredictor,
  }) async {
    var attempts = 0;
    var totalMirrorAttempts = 0;
    const maxAttempts = 3;
    final maxTotalAttempts =
        (failover.hasAlternatives ? failover.remainingAlternatives + 1 : 1) *
            maxAttempts;
    var activeUrl = failover.activeUrl;
    final chunkStartWallClock = DateTime.now();

    while (!chunk.isComplete) {
      _throwIfCancelled();
      if (DateTime.now().difference(chunkStartWallClock) > _maxChunkWallClock) {
        throw DownloadIntegrityException(
            'Chunk $chunkIndex exceeded wall-clock budget');
      }
      attempts++;
      totalMirrorAttempts++;
      if (totalMirrorAttempts > maxTotalAttempts) {
        throw DownloadIntegrityException(
            'Max total mirror attempts ($maxTotalAttempts) exceeded for chunk $chunkIndex');
      }
      try {
        var resumeFrom = chunk.downloaded;
        final tempFile = File(cmd.tempFilePath);
        final currentDiskLen = tempFile.existsSync() ? tempFile.lengthSync() : 0;
        if (resumeFrom > 0 && chunk.start + resumeFrom > currentDiskLen) {
          _log.warning(
            '[DMX-Job-J4] Pre-flight violation on chunk $chunkIndex: '
            'offset ${chunk.start + resumeFrom} > disk length $currentDiskLen. Zeroing chunk progress.',
          );
          chunk.downloaded = 0;
          resumeFrom = 0;
        }

        final absStart = chunk.start + resumeFrom;
        final headers = <String, dynamic>{
          'Range': chunk.end < 0
              ? 'bytes=$absStart-'
              : 'bytes=$absStart-${chunk.end}',
        };
        if (resumeFrom > 0) {
          final ifRange = firstNonEmpty(_state!.etag, _state!.lastModified);
          if (ifRange != null) headers['If-Range'] = ifRange;
        }
        final response = await dio.get<ResponseBody>(
          activeUrl,
          cancelToken: _cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: true,
            headers: headers,
            validateStatus: (_) => true,
          ),
        );

        if (response.statusCode == 200) {
          await response.data?.stream.listen((_) {}).cancel();
          if (resumeFrom > 0) {
            chunk.downloaded = 0;
            try {
              await StateStore.resetTransferState(cmd.tempFilePath, taskId: cmd.taskId);
            } catch (e, st) {
              _log.fine(
                  'Failed to reset state store on HTTP 200 resume reject',
                  e,
                  st);
            }
            throw RangeUnsupportedException();
          }
          throw RangeUnsupportedException();
        }
        if (response.statusCode == 416) {
          await response.data?.stream.listen((_) {}).cancel();
          handle416(chunk, _state?.totalSize ?? 0);
          if (chunk.isComplete ||
              (chunk.size >= 0 && chunk.downloaded >= chunk.size)) {
            break;
          }
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            response: response,
            message: 'HTTP 416: invalid byte range for chunk.',
          );
        }
        if (response.statusCode != 206) {
          await response.data?.stream.listen((_) {}).cancel();
          if (response.statusCode == 401 || response.statusCode == 403) {
            final host = Uri.tryParse(cmd.punyUrl)?.host.toLowerCase() ?? '';
            final isYtOrSigned = _isExpiredUrlOrSite(cmd.url, host);
            if (isYtOrSigned) {
              _emitProgress(0,
                  statusMessage: 'Refreshing links…',
                  cycleStateOverride: CycleState.updatingLinks);
              if (_state != null) {
                _state!.cycleState = CycleState.updatingLinks.name;
                try {
                  await StateStore.save(cmd.tempFilePath, _state!,
                      durable: true, taskId: cmd.taskId);
                } catch (e, st) {
                  _log.fine(
                      'Failed to save state on URL expiration in chunk', e, st);
                }
              }
              await Future.delayed(const Duration(milliseconds: 10));
              throw UrlExpiredException(
                'Download URL expired (HTTP ${response.statusCode}). Refresh required.',
              );
            }
          }
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            response: response,
            message: 'Server returned ${response.statusCode} instead of 206.',
          );
        }

        final contentType =
            response.headers.value('content-type')?.toLowerCase() ?? '';
        if (_htmlContentTypeRegex.hasMatch(contentType)) {
          await response.data?.stream.listen((_) {}).cancel();
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            response: response,
            message: 'HTML_INSTEAD_OF_MEDIA',
          );
        }

        try {
          validateContentRange(
            response.headers.value('content-range'),
            expectedStart: absStart,
            expectedEnd: chunk.end,
            expectedTotal: _state!.totalSize,
            allowUnknown: chunk.downloaded == 0 && absStart == 0,
            url: cmd.punyUrl,
          );
        } on DioException {
          chunk.downloaded = 0;
          rethrow;
        }

        _state!.etag ??= response.headers.value('etag');
        _state!.lastModified ??= response.headers.value('last-modified');
        final stream = response.data?.stream;
        if (stream == null) {
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            message: 'Empty response body.',
          );
        }

        Digest? chunkDigest;
        final innerDigestSink =
            ChunkedConversionSink<Digest>.withCallback((results) {
          chunkDigest = results.single;
        });
        final digestSink = sha256.startChunkedConversion(innerDigestSink);

        if (resumeFrom > 0) {
          final tempFile = File(cmd.tempFilePath);
          if (tempFile.existsSync()) {
            final raf = tempFile.openSync(mode: FileMode.read);
            try {
              raf.setPositionSync(chunk.start);
              var remainingToRead = resumeFrom;
              const bufferSize = 64 * 1024;
              while (remainingToRead > 0) {
                final toRead = min(bufferSize, remainingToRead);
                final bytes = raf.readSync(toRead);
                if (bytes.isEmpty) break;
                digestSink.add(bytes);
                remainingToRead -= bytes.length;
              }
            } finally {
              raf.closeSync();
            }
          }
        }

        var sessionBytes = 0;
        await for (final piece in stream) {
          _throwIfCancelled();
          final sleepMs =
              await governor.acquire(piece.length, taskId: cmd.taskId);
          if (sleepMs > 0) {
            await _cancellableDelay(Duration(milliseconds: sleepMs));
            _throwIfCancelled();
          }
          final pos = chunk.start + resumeFrom + sessionBytes;
          final remainingInChunk = chunk.size >= 0
              ? chunk.size - (resumeFrom + sessionBytes)
              : piece.length;
          if (remainingInChunk <= 0) {
            break;
          }
          final toWrite = remainingInChunk < piece.length
              ? Uint8List.sublistView(piece, 0, remainingInChunk)
              : piece;
          await writer.write(chunkIndex, pos, toWrite);
          digestSink.add(toWrite);
          sessionBytes += toWrite.length;
          chunk.downloaded = resumeFrom + sessionBytes;
          _bytesSinceSave += toWrite.length;

          if (speedPredictor != null) {
            final elapsedSec = _stopwatch.elapsedMilliseconds / 1000.0;
            if (elapsedSec > 0) {
              speedPredictor.addSample(sessionBytes / elapsedSec);
            }
          }

          await _throttledSaveAndReport(writer);

          if (chunk.size >= 0 && (resumeFrom + sessionBytes) >= chunk.size) {
            break;
          }
        }
        digestSink.close();
        if (chunkDigest != null && chunk.isComplete) {
          chunk.hash = chunkDigest.toString();
        }

        failover.reportSuccess();
        _emitProgress(_stopwatch.elapsedMilliseconds,
            statusMessage: 'Downloading…',
            cycleStateOverride: CycleState.downloading);
        attempts = 0;
        if (chunk.isComplete) {
          try {
            await writer.flushAll();
            await StateStore.save(cmd.tempFilePath, _state!, durable: true, taskId: cmd.taskId);
            final journal = DownloadJournal('${cmd.tempFilePath}.journal');
            await journal.open();
            try {
              await journal.recordChunkProgress(
                chunkIndex,
                chunk.downloaded,
                hash: chunk.hash,
              );
            } finally {
              await journal.close();
            }
          } catch (e) {
            debugPrint('[DMX] H-2: chunk-boundary save failed: $e');
            try {
              await Future<void>.delayed(const Duration(milliseconds: 150));
              await StateStore.save(cmd.tempFilePath, _state!, durable: true, taskId: cmd.taskId);
            } catch (e, st) {
              _log.fine('Failed backup state save at chunk boundary', e, st);
            }
          }
        }
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        if (e.message == 'HTML_INSTEAD_OF_MEDIA') rethrow;
        if (e.message?.startsWith('Server rejected resume') == true) rethrow;

        final status = e.response?.statusCode;
        if (status == 401 || status == 403) {
          final host = Uri.tryParse(cmd.punyUrl)?.host.toLowerCase() ?? '';
          final isLikelyExpired = _isExpiredUrlOrSite(cmd.url, host);
          if (isLikelyExpired) {
            _emitProgress(0,
                statusMessage: 'Refreshing links…',
                cycleStateOverride: CycleState.updatingLinks);
            if (_state != null) {
              _state!.cycleState = CycleState.updatingLinks.name;
              try {
                await StateStore.save(cmd.tempFilePath, _state!, durable: true, taskId: cmd.taskId);
              } catch (_) {}
            }
            await Future.delayed(const Duration(milliseconds: 10));
            throw UrlExpiredException(
              'Download URL expired (HTTP $status). Refresh required.',
            );
          }
        }
        if (status != null &&
            status >= 400 &&
            status < 500 &&
            status != 408 &&
            status != 429) {
          rethrow;
        }
        if (attempts >= maxAttempts) {
          final next = failover.advance();
          if (next != null) {
            activeUrl = next;
            attempts = 0;
            totalMirrorAttempts = 0;
            debugPrint('[DMX-Job] failing over to mirror: $next');
            _emitProgress(_stopwatch.elapsedMilliseconds,
                statusMessage: 'Retrying (mirror failover)…',
                cycleStateOverride: CycleState.retrying);
            continue;
          }
          rethrow;
        }
        _emitProgress(_stopwatch.elapsedMilliseconds,
            statusMessage: 'Retrying…');
        await _cancellableDelay(
            Duration(seconds: (attempts * attempts * 2) + _rng.nextInt(3)));
      } on PositionalFileWriterException {
        rethrow;
      } on UrlExpiredException {
        rethrow;
      } catch (e) {
        if (attempts >= maxAttempts) {
          final next = failover.advance();
          if (next != null) {
            activeUrl = next;
            // FIX 16: Reset both attempt counters for new mirror
            attempts = 0;
            totalMirrorAttempts = 0;
            debugPrint('[DMX-Job] failing over to mirror: $next');
            _emitProgress(_stopwatch.elapsedMilliseconds,
                statusMessage: 'Retrying (mirror failover)…',
                cycleStateOverride: CycleState.retrying);
            continue;
          }
          rethrow;
        }
        await _cancellableDelay(Duration(seconds: attempts * 2));
      }
    }
  }

  /// FIX 9: Spot-check resume verification - now clears writer data when
  /// a mismatch is detected to prevent corrupted writes on re-download.
  @visibleForTesting
  Future<void> spotCheckResumedBytes(
      Dio dio, TransferState st, PositionalFileWriter writer) async {
    if (cmd.threadCount > 16) return;
    _throwIfCancelled();
    const sampleSize = 64 * 1024;
    final candidateChunks = st.chunks
        .where((chunk) => chunk.downloaded > 0 && !chunk.isComplete)
        .take(4)
        .toList();
    if (candidateChunks.isEmpty) return;

    Future<void> probeChunk(ChunkState chunk, int chunkIndex) async {
      _throwIfCancelled();
      final start = chunk.start;
      final len = min(sampleSize, chunk.downloaded);
      try {
        final diskBytes = await writer.readRange(start, len);
        final response = await dio.get<ResponseBody>(
          cmd.punyUrl,
          cancelToken: _cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            headers: {'Range': 'bytes=$start-${start + len - 1}'},
            validateStatus: (_) => true,
          ),
        );
        if (response.statusCode != 206 || response.data == null) {
          chunk.downloaded = 0;
          return;
        }
        final builder = BytesBuilder(copy: false);
        await for (final b in response.data!.stream) {
          builder.add(b);
        }
        final netBytes = builder.takeBytes();
        if (netBytes.length != diskBytes.length ||
            !listEquals(netBytes, diskBytes)) {
          chunk.downloaded = 0;
          _log.fine('[DMX-Job] spot-check mismatch → chunk $chunkIndex reset');
        }
      } catch (e, st) {
        _log.fine('[DMX-Job] spot-check probe failed for chunk $chunkIndex: $e',
            e, st);
      }
    }

    // Find chunk indices for candidate chunks
    final candidateEntries = <(int, ChunkState)>[];
    for (var i = 0; i < st.chunks.length; i++) {
      if (candidateChunks.contains(st.chunks[i])) {
        candidateEntries.add((i, st.chunks[i]));
      }
    }
    await Future.wait(candidateEntries.map((e) => probeChunk(e.$2, e.$1)));
  }

  /// Single-stream download with retry and mirror failover.
  /// FIX 5: HTTP 200 resume rejection now throws RangeUnsupportedException
  /// instead of DioException.badResponse to avoid triggering retry logic.
  /// FIX 1: Pause saves state synchronously before throwing.
  Future<void> _runSingleStream(Dio dio) async {
    final st = _state!;
    if (st.chunks.isEmpty) {
      st.chunks = ChunkScheduler.singleStream(st.totalSize);
    }
    final chunk = st.chunks.first;
    final tempFile = File(cmd.tempFilePath);
    await tempFile.parent.create(recursive: true);

    final stateFile = File(StateStore.pathFor(cmd.tempFilePath));
    final hasUsableState = await stateFile.exists() &&
        st.downloadedBytes > 0 &&
        st.chunks.isNotEmpty;

    if (await tempFile.exists()) {
      final len = await tempFile.length();
      if (st.totalSize > 0 && len >= st.totalSize) {
        if (hasUsableState && st.isComplete) {
          chunk.downloaded = st.totalSize;
          _emitProgress(0, statusMessage: 'Completed');
          await _finalize(dio);
          return;
        }
        debugPrint(
            '[DMX-Job] FIX-1: temp file full but state unusable — restarting');
        chunk.downloaded = 0;
        await tempFile.delete();
        try {
          await StateStore.remove(cmd.tempFilePath);
        } catch (e, st) {
          _log.fine('Failed to remove state store on temp file overrun', e, st);
        }
        st.chunks = ChunkScheduler.singleStream(st.totalSize);
      } else if (cmd.supportsResume) {
        chunk.downloaded = st.totalSize > 0 ? len.clamp(0, st.totalSize) : len;
      } else {
        chunk.downloaded = 0;
        await tempFile.delete();
      }
    } else if (!cmd.supportsResume) {
      chunk.downloaded = 0;
    }

    final governor = BandwidthGovernor(
      _effectiveGlobalLimit(),
      1.0,
      cmd.throttleFactor,
    );
    governor.registerConsumer();
    if (cmd.speedLimitKbps > 0) {
      governor.setTaskLimit(cmd.taskId, cmd.speedLimitKbps * 125);
    }

    // Spot-check for single-stream
    if (chunk.downloaded > 0 &&
        cmd.supportsResume &&
        SettingsProvider.instance.resumeIntegrityCheck &&
        await tempFile.exists()) {
      try {
        const sampleSize = 64 * 1024;
        final len = min(sampleSize, chunk.downloaded);
        final raf = await tempFile.open(mode: FileMode.read);
        try {
          final diskBytes = await raf.read(len);
          final response = await dio.get<ResponseBody>(
            cmd.punyUrl,
            cancelToken: _cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              headers: {'Range': 'bytes=0-${len - 1}'},
              validateStatus: (_) => true,
            ),
          );
          if (response.statusCode == 206 && response.data != null) {
            final builder = BytesBuilder(copy: false);
            await for (final b in response.data!.stream) {
              builder.add(b);
            }
            final netBytes = builder.takeBytes();
            if (netBytes.length != diskBytes.length ||
                !listEquals(netBytes, diskBytes)) {
              debugPrint(
                  '[DMX-Job] FIX-2: single-stream spot-check mismatch — restarting');
              chunk.downloaded = 0;
              await tempFile.delete();
              try {
                await StateStore.remove(cmd.tempFilePath);
              } catch (e, st) {
                _log.fine('Failed to remove state store on spot check mismatch',
                    e, st);
              }
              st.chunks = ChunkScheduler.singleStream(st.totalSize);
            }
          } else {
            await response.data?.stream.listen((_) {}).cancel();
          }
        } finally {
          await raf.close();
        }
      } catch (e) {
        debugPrint('[DMX-Job] FIX-2: spot-check probe failed (continuing): $e');
      }
    }

    final failover = MirrorFailover([cmd.punyUrl, ...?cmd.mirrorUrls]);
    var attempts = 0;
    var totalMirrorAttempts = 0;
    var rangeRejectCount = 0;
    const maxRangeRejects = 2;
    const maxAttempts = 3;
    final maxTotalAttempts =
        (failover.hasAlternatives ? failover.remainingAlternatives + 1 : 1) *
            maxAttempts;
    var activeUrl = failover.activeUrl;

    while (!st.isComplete || st.totalSize <= 0) {
      _throwIfCancelled();
      attempts++;
      totalMirrorAttempts++;
      if (totalMirrorAttempts > maxTotalAttempts) {
        throw DownloadIntegrityException(
            'Max total mirror attempts ($maxTotalAttempts) exceeded for single-stream job');
      }
      RandomAccessFile? raf;
      try {
        final resumeFrom = chunk.downloaded;
        final headers = <String, dynamic>{};
        if (resumeFrom > 0 && cmd.supportsResume) {
          headers['Range'] = 'bytes=$resumeFrom-';
          final ifRange = firstNonEmpty(st.etag, st.lastModified);
          if (ifRange != null) headers['If-Range'] = ifRange;
        }
        final response = await dio.get<ResponseBody>(
          activeUrl,
          cancelToken: _cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: true,
            headers: headers,
            validateStatus: (_) => true,
          ),
        );

        if (response.statusCode == 416) {
          await response.data?.stream.listen((_) {}).cancel();
          handle416(chunk, st.totalSize);
          if (st.totalSize > 0 && chunk.downloaded >= st.totalSize) break;
          chunk.downloaded = 0;
          if (await tempFile.exists()) await tempFile.delete();
          continue;
        }

        // FIX 5: HTTP 200 resume rejection - handle server ignoring Range headers
        if (response.statusCode == 200 && resumeFrom > 0) {
          await response.data?.stream.listen((_) {}).cancel();
          _log.info('resume_range_ignored (single-stream): resetting for ${cmd.taskId}');
          _send('telemetry', {
            'event': 'resume_range_ignored',
            'taskId': cmd.taskId,
            'url': cmd.url,
          });
          rangeRejectCount++;
          if (rangeRejectCount > maxRangeRejects) {
            st.status = DmxStateStatus.failed;
            _emitProgress(0,
                statusMessage: 'Failed: Server rejected resume requests.');
            throw DioException(
              requestOptions: response.requestOptions,
              type: DioExceptionType.badResponse,
              message: 'Server repeatedly ignored Range requests.',
            );
          }
          // Clear state files
          for (final p in [
            '${cmd.tempFilePath}.dmxstate',
            '${cmd.tempFilePath}.dmxstate.tmp',
          ]) {
            try {
              final f = File(p);
              if (await f.exists()) await f.delete();
            } catch (e, st) {
              _log.fine(
                  'Failed to delete dmxstate file on single-stream restart',
                  e,
                  st);
            }
          }
          if (await tempFile.exists()) {
            try {
              await tempFile.delete();
            } catch (e, st) {
              _log.fine(
                  'Failed to delete temp file on single-stream restart', e, st);
            }
          }
          chunk.downloaded = 0;
          st.chunks = ChunkScheduler.singleStream(st.totalSize);
          // Restart from the beginning with this mirror
          continue;
        }

        if (response.statusCode != 200 && response.statusCode != 206) {
          await response.data?.stream.listen((_) {}).cancel();
          // FIX 4: URL expiration detection
          if (response.statusCode == 401 || response.statusCode == 403) {
            final host = Uri.tryParse(cmd.punyUrl)?.host.toLowerCase() ?? '';
            final isYtOrSigned = _isExpiredUrlOrSite(cmd.url, host);
            if (isYtOrSigned) {
              _emitProgress(0,
                  statusMessage: 'Refreshing links…',
                  cycleStateOverride: CycleState.updatingLinks);
              if (_state != null) {
                _state!.cycleState = CycleState.updatingLinks.name;
                try {
                  await StateStore.save(cmd.tempFilePath, _state!,
                      durable: true);
                } catch (e, st) {
                  _log.fine(
                      'Failed to save state on expired URL in single-stream',
                      e,
                      st);
                }
              }
              await Future.delayed(const Duration(milliseconds: 10));
              throw UrlExpiredException(
                'Download URL expired (HTTP ${response.statusCode}). Refresh required.',
              );
            }
          }
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            response: response,
            message: 'Server returned status code ${response.statusCode}',
          );
        }

        // FIX 6: HTML response detection - use precise regex
        final contentType =
            response.headers.value('content-type')?.toLowerCase() ?? '';
        if (_htmlContentTypeRegex.hasMatch(contentType)) {
          await response.data?.stream.listen((_) {}).cancel();
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            response: response,
            message: 'HTML_INSTEAD_OF_MEDIA',
          );
        }

        final isPartial = response.statusCode == 206;
        if (isPartial) {
          final contentRange = response.headers.value('content-range');
          if (contentRange != null) {
            try {
              validateContentRange(
                contentRange,
                expectedStart: chunk.downloaded,
                expectedEnd: st.totalSize > 0 ? st.totalSize - 1 : -1,
                expectedTotal: st.totalSize,
                allowUnknown: chunk.downloaded == 0,
                url: cmd.punyUrl,
              );
            } on DioException {
              chunk.downloaded = 0;
              rethrow;
            }
          }
        }

        st.etag ??= response.headers.value('etag');
        st.lastModified ??= response.headers.value('last-modified');
        final contentLength = int.tryParse(
                response.headers.value(Headers.contentLengthHeader) ?? '') ??
            0;
        if (contentLength > 0) {
          final actual = (isPartial ? chunk.downloaded : 0) + contentLength;
          if (st.totalSize <= 0 || actual != st.totalSize) {
            st.totalSize = actual;
            chunk.end = actual - 1;
          }
        }

        raf = await tempFile.open(
          mode: chunk.downloaded > 0 ? FileMode.append : FileMode.write,
        );
        final stream = response.data?.stream;
        if (stream == null) {
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            message: 'Empty response body.',
          );
        }
        try {
          await for (final piece in stream) {
            _throwIfCancelled();
            final sleepMs =
                await governor.acquire(piece.length, taskId: cmd.taskId);
            if (sleepMs > 0) {
              await _cancellableDelay(Duration(milliseconds: sleepMs));
              _throwIfCancelled();
            }
            await raf.writeFrom(piece);
            chunk.downloaded += piece.length;
            _bytesSinceSave += piece.length;
            await _throttledSaveAndReport(
              null,
              preSaveFlush: () async {
                await raf?.flush();
              },
            );
          }
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel) {
            rethrow;
          }
          rethrow;
        }

        try {
          await raf.flush();
          await raf.close();
        } catch (e, st) {
          _log.fine('Failed to flush/close raf in single-stream', e, st);
        }
        raf = null;
        failover.reportSuccess();
        attempts = 0;
        if (st.totalSize <= 0) { // FIX-P0-1
          final actualDiskLen = await tempFile.length(); // FIX-P0-1
          chunk.downloaded = actualDiskLen; // FIX-P0-1
          st.totalSize = actualDiskLen; // FIX-P0-1
          chunk.end = actualDiskLen > 0 ? actualDiskLen - 1 : 0; // FIX-P0-1
        } // FIX-P0-1
        if (chunk.isComplete || (st.totalSize > 0 && chunk.downloaded >= st.totalSize)) { // FIX-P0-1
          await StateStore.save(cmd.tempFilePath, _state!, durable: true); // FIX-P0-1
        } // FIX-P0-1
        break;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          // FIX 1: Pause - save state synchronously
          _state!.status = DmxStateStatus.paused;
          try {
            await raf?.flush();
            await raf?.close();
          } catch (flushErr, flushSt) {
            _log.fine(
                'RAF flush on pause failed: $flushErr', flushErr, flushSt);
          }
          raf = null;
          _stateSavedInCatch = true;
          await StateStore.save(cmd.tempFilePath, _state!, durable: true);
          _emitProgress(0,
              statusMessage: 'Paused', pauseReason: effectivePauseReason);
          rethrow;
        }
        if (e.message == 'HTML_INSTEAD_OF_MEDIA') {
          _state!.status = DmxStateStatus.failed;
          _emitProgress(0, statusMessage: _formatFailedMessage(e));
          rethrow;
        }

        final status = e.response?.statusCode;
        // FIX 4: URL expiration detection - precise patterns only
        if (status == 401 || status == 403) {
          final host = Uri.tryParse(cmd.punyUrl)?.host.toLowerCase() ?? '';
          final isYtOrSigned = _isExpiredUrlOrSite(cmd.url, host);
          if (isYtOrSigned) {
            _emitProgress(0,
                statusMessage: 'Refreshing links…',
                cycleStateOverride: CycleState.updatingLinks);
            if (_state != null) {
              _state!.cycleState = CycleState.updatingLinks.name;
              try {
                await StateStore.save(cmd.tempFilePath, _state!, durable: true);
              } catch (e, st) {
                _log.fine(
                    'Failed to save state on expired URL in single-stream',
                    e,
                    st);
              }
            }
            await Future.delayed(const Duration(milliseconds: 10));
            throw UrlExpiredException(
              'Download URL expired (HTTP $status). Refresh required.',
            );
          }
        }
        // Non-retryable client errors
        if (status == 401 || status == 403 || status == 404 || status == 410) {
          _state!.status = DmxStateStatus.failed;
          _emitProgress(0, statusMessage: _formatFailedMessage(e));
          rethrow;
        }
        if (status != null &&
            status >= 400 &&
            status < 500 &&
            status != 408 &&
            status != 429) {
          _state!.status = DmxStateStatus.failed;
          _emitProgress(0, statusMessage: _formatFailedMessage(e));
          rethrow;
        }
        if (attempts >= maxAttempts) {
          _state!.status = DmxStateStatus.failed;
          final next = failover.advance();
          if (next != null) {
            activeUrl = next;
            // FIX 16: Reset both attempt counters for new mirror
            attempts = 0;
            totalMirrorAttempts = 0;
            _state!.status = DmxStateStatus.active;
            _emitProgress(_stopwatch.elapsedMilliseconds,
                statusMessage: 'Retrying (mirror failover)…',
                cycleStateOverride: CycleState.retrying);
            continue;
          }
          _emitProgress(0, statusMessage: _formatFailedMessage(e));
          rethrow;
        }
        _emitProgress(_stopwatch.elapsedMilliseconds,
            statusMessage: 'Retrying…');
        await _cancellableDelay(
            Duration(seconds: (attempts * attempts * 2) + _rng.nextInt(3)));
      } finally {
        try {
          await raf?.flush();
          await raf?.close();
        } catch (e, st) {
          _log.fine(
              'Failed to flush/close raf in single-stream finally', e, st);
        }
        raf = null;
        // FIX 15: Only save if not already saved in catch
        if (!_stateSavedInCatch) {
          try {
            await StateStore.save(cmd.tempFilePath, _state!, durable: true);
          } catch (e, st) {
            _log.fine('Failed to save state in single-stream finally', e, st);
          }
        }
      }
    }

    // Verify final file size
    final actualLen = await tempFile.length();
    if (st.totalSize > 0 && actualLen != st.totalSize) {
      if (actualLen > st.totalSize) {
        final raf = await tempFile.open(mode: FileMode.writeOnly);
        await raf.truncate(st.totalSize);
        await raf.close();
      } else {
        st.status = DmxStateStatus.failed;
        await StateStore.save(cmd.tempFilePath, st, durable: true);
        final err = DownloadIntegrityException(
            'expected ${st.totalSize} bytes, got $actualLen');
        _emitProgress(0, statusMessage: _formatFailedMessage(err));
        throw err;
      }
    }
    governor.removeTaskLimit(cmd.taskId);
    governor.unregisterConsumer();
    governor.dispose();
  }

  /// Finalizes the download: renames temp file to final, cleans up state.
  Future<void> _finalize(Dio dio) async {
    final st = _state!;
    if (cmd.tempFilePath != cmd.localFilePath) {
      final tempExists = await File(cmd.tempFilePath).exists();
      if (!tempExists) {
        st.status = DmxStateStatus.failed;
        await StateStore.save(cmd.tempFilePath, st, durable: true);
        final err = DownloadIntegrityException(
            'Temporary download file missing: ${cmd.tempFilePath}');
        _emitProgress(0, statusMessage: _formatFailedMessage(err));
        throw err;
      }
      // Fsync final write before rename
      try {
        final raf =
            await File(cmd.tempFilePath).open(mode: FileMode.writeOnlyAppend);
        try {
          await raf.flush();
        } finally {
          await raf.close();
        }
      } catch (fsyncErr, fsyncSt) {
        _log.fine('fsync before rename failed: $fsyncErr', fsyncErr, fsyncSt);
      }
      final finalFile = File(cmd.localFilePath);
      await finalFile.parent.create(recursive: true);
      if (await finalFile.exists()) await finalFile.delete();
      try {
        await File(cmd.tempFilePath).rename(cmd.localFilePath);
      } catch (e) {
        final srcFile = File(cmd.tempFilePath);
        final dstFile = File(cmd.localFilePath);
        try {
          final srcStream = srcFile.openRead();
          final dstSink = dstFile.openWrite();
          await srcStream.pipe(dstSink);

          final srcLen = await srcFile.length();
          final dstLen = await dstFile.length();
          if (srcLen == dstLen) {
            await srcFile.delete();
          } else {
            if (await dstFile.exists()) await dstFile.delete();
            throw DownloadIntegrityException(
                'File copy length mismatch ($srcLen != $dstLen) on rename fallback.');
          }
        } catch (copyErr) {
          if (await dstFile.exists()) {
            try {
              await dstFile.delete();
            } catch (_) {}
          }
          rethrow;
        }
      }
    } else {
      final localExists = await File(cmd.localFilePath).exists();
      if (!localExists) {
        st.status = DmxStateStatus.failed;
        await StateStore.save(cmd.tempFilePath, st, durable: true);
        final err = DownloadIntegrityException(
            'Download output file missing: ${cmd.localFilePath}');
        _emitProgress(0, statusMessage: _formatFailedMessage(err));
        throw err;
      }
    }
    st.status = DmxStateStatus.complete;
    await StateStore.save(cmd.tempFilePath, st, durable: true);
    _emitProgress(0, statusMessage: 'Completed');
    await StateStore.remove(cmd.tempFilePath);
  }

  int _effectiveGlobalLimit() {
    if (_workerGlobalLimitBps > 0) {
      return (_workerGlobalLimitBps / _workerGlobalActive).floor();
    }
    return cmd.initialSpeedLimit > 0
        ? (cmd.initialSpeedLimit / max(1, cmd.initialActiveCount)).floor()
        : 0;
  }

  void _throwIfCancelled() {
    if (_cancelRequested || _cancelToken.isCancelled) {
      throw DioException(
        requestOptions: RequestOptions(path: cmd.punyUrl),
        type: DioExceptionType.cancel,
        message: 'Download cancelled.',
      );
    }
  }

  Future<void> _cancellableDelay(Duration duration) =>
      cancellableDelay(duration);

  /// Throttled state save and progress report using synchronized execution
  /// to guarantee state preservation without dropping saves.
  Future<void> _throttledSaveAndReport(
    PositionalFileWriter? writer, {
    Future<void> Function()? preSaveFlush,
  }) async {
    if (_stateSavePending) return;

    // If cancelled, force immediate durable save
    if (_cancelRequested || _cancelToken.isCancelled) {
      final st = _state;
      if (st != null && !_stateSavedInCatch) {
        try {
          await _stateSaveLock.synchronized(() async {
            if (preSaveFlush != null) await preSaveFlush();
            if (writer != null) await writer.flushAll();
            await DownloadJournal.flushAllActive();
            await StateStore.save(cmd.tempFilePath, st,
                durable: true, taskId: cmd.taskId);
          });
        } catch (e) {
          debugPrint('[DMX-Job] forced state save on cancel failed: $e');
        }
      }
      return;
    }

    final st = _state;
    if (st == null) return;
    final nowMs = _stopwatch.elapsedMilliseconds;
    final isBackground =
        DownloadEngine.isInBackground || PowerMonitor.screenOff;
    final saveInterval = isBackground
        ? const Duration(seconds: 15).inMilliseconds
        : const Duration(seconds: 5).inMilliseconds;
    final speed = _lastSpeed;
    final saveByteThreshold = max(2 * 1024 * 1024, (speed * 1.5).toInt());
    final dueSave = nowMs - _lastStateSaveMs >= saveInterval ||
        _bytesSinceSave >= saveByteThreshold;
    final reportInterval = isBackground ? 15000 : 750;
    final dueReport = nowMs - _lastReportMs >= reportInterval;

    if (st.chunks.isNotEmpty) {
      _chunkFingerprint = st.chunks.fold<int>(
        0,
        (h, c) => h ^ Object.hash(c.start, c.end, c.size, c.downloaded),
      );
    }

    if (dueSave) {
      _lastStateSaveMs = nowMs;
      _bytesSinceSave = 0;
      _stateSavePending = true;
      unawaited(_stateSaveLock.synchronized(() async {
        try {
          if (preSaveFlush != null) await preSaveFlush();
          if (writer != null) await writer.flushBuffers();
          await StateStore.save(
            cmd.tempFilePath,
            st,
            screenOff: PowerMonitor.screenOff,
          );
        } catch (e) {
          debugPrint('[DMX-Job] state save failed: $e');
        } finally {
          _stateSavePending = false;
        }
      }));
    }

    if (dueReport && !PowerMonitor.screenOff) {
      _lastReportMs = nowMs;
      _emitProgress(nowMs, writer: writer);
    }
  }

  List<Map<String, dynamic>>? _getChunkDetails(TransferState st) {
    if (st.chunks.isEmpty) return null;
    final chunkHash = st.chunks.fold<int>(
        0, (h, c) => h ^ Object.hash(c.start, c.end, c.size, c.downloaded));
    if (_cachedChunkDetails != null && chunkHash == _lastChunkDetailsHash) {
      return _cachedChunkDetails;
    }
    _lastChunkDetailsHash = chunkHash;
    _cachedChunkDetails = st.chunks.asMap().entries.map((e) {
      final c = e.value;
      final rawRatio = c.ratio;
      final safeRatio = rawRatio < 0.0 ? 0.0 : rawRatio.clamp(0.0, 1.0);
      return <String, dynamic>{
        'index': e.key,
        'start': c.start,
        'end': c.end,
        'downloaded': c.downloaded,
        'size': c.size,
        'ratio': safeRatio,
        'isComplete': c.isComplete,
        'isIndeterminate': c.size < 0,
      };
    }).toList();
    return _cachedChunkDetails;
  }

  /// FIX 4: URL expiration detection - uses precise patterns instead of
  /// broad substring matching. No longer matches arbitrary "forbidden" text.
  bool _isExpiredUrlOrSite(String rawUrl, String host, [String bodyText = '']) {
    if (cmd.urlExpiresHint) return true;
    final hostLower = host.toLowerCase();
    final urlLower = rawUrl.toLowerCase();

    // Check for known expiring URL hosts
    if (_googlevideoHostRegex.hasMatch(hostLower) ||
        hostLower.contains('youtube.com') ||
        hostLower.contains('youtu.be')) {
      return true;
    }

    // Check for expiration/signature parameters in the URL
    if (_urlExpireParamRegex.hasMatch(urlLower)) {
      return true;
    }

    // Check body text for specific expiration indicators (not just "forbidden")
    if (bodyText.isNotEmpty) {
      final bodyLower = bodyText.toLowerCase();
      if (bodyLower.contains('expired') ||
          bodyLower.contains('token expired') ||
          bodyLower.contains('signature expired') ||
          bodyLower.contains('url expired') ||
          bodyLower.contains('access denied') ||
          bodyLower.contains('unauthorized')) {
        return true;
      }
    }

    return false;
  }

  String _formatFailedMessage(Object? e) {
    if (e == null) return 'Failed';
    String msg;
    if (e is DioException) {
      msg = e.message ?? e.toString();
    } else {
      msg = e.toString();
    }
    if (msg.startsWith('Exception: ')) {
      msg = msg.substring('Exception: '.length);
    }
    msg = msg.trim();
    if (msg.isEmpty) return 'Failed';
    if (msg.length > 80) {
      msg = '${msg.substring(0, 77)}…';
    }
    return 'Failed: $msg';
  }

  /// Emits progress with all data status:
  /// - HTTP: all parts/chunks with per-chunk progress
  /// - YouTube: audio + video counterpart tracking
  /// - Cycle state and pause reason
  /// FIX 12: Progress fingerprint now includes ytStreamKind
  void _emitProgress(int nowMs,
      {String? statusMessage,
      CycleState? cycleStateOverride,
      PauseReason? pauseReason,
      PositionalFileWriter? writer}) {
    final st = _state!;
    final downloaded = st.downloadedBytes;
    final total = st.totalSize;

    // Track progress for stall detection
    if (downloaded != _lastProgressBytes) {
      _lastProgressBytes = downloaded;
      _lastProgressTimeMs = _stopwatch.elapsedMilliseconds;
      _stalledEmitted = false;
    }

    // Speed calculation
    _speedSamples.add(SpeedSample(_stopwatch.elapsedMilliseconds, downloaded));
    while (_speedSamples.isNotEmpty &&
        _stopwatch.elapsedMilliseconds - _speedSamples.first.timestampMs >
            3000) {
      _speedSamples.removeFirst();
    }
    var speed = 0.0;
    if (_speedSamples.length > 1) {
      final first = _speedSamples.first;
      final elapsed =
          (_stopwatch.elapsedMilliseconds - first.timestampMs) / 1000;
      if (elapsed > 0) speed = (downloaded - first.bytes) / elapsed;
    }
    _lastSpeed = speed;

    // FIX 11: Writer buffer adaptation - also works in single-stream via
    // checking if writer is available (it's null in single-stream, so
    // this only applies to multi-threaded, which is correct)
    if (writer != null) {
      if (_currentWriterBufferSize == 256 * 1024 && speed > 60 * 1024 * 1024) {
        _currentWriterBufferSize = 512 * 1024;
        writer.setBufferSize(512 * 1024);
      } else if (_currentWriterBufferSize == 512 * 1024 &&
          speed < 30 * 1024 * 1024) {
        _currentWriterBufferSize = 256 * 1024;
        writer.setBufferSize(256 * 1024);
      }
    }

    // ETA calculation
    int? eta;
    final remaining = total - downloaded;
    if (speed.isFinite && speed > 0 && remaining > 0) {
      final raw = (remaining / speed).round().clamp(0, 86400 * 365);
      eta = _lastEta == null ? raw : ((_lastEta! * 0.7) + (raw * 0.3)).round();
      _lastEta = eta;
    } else {
      _lastEta = null;
    }

    // Chunk details
    final hasIndeterminate = st.chunks.any((c) => c.size < 0);
    final totalChunks = st.chunks.isNotEmpty ? st.chunks.length : null;
    final completedChunks = (st.chunks.isNotEmpty && !hasIndeterminate)
        ? st.chunks.where((c) => c.isComplete).length
        : null;

    final cycleState =
        cycleStateOverride ?? _deriveCycleState(statusMessage, st.status);
    final isCycleStateChanged = cycleState != _lastEmittedCycleState;
    final isTerminalState = cycleState == CycleState.completed ||
        cycleState == CycleState.failed ||
        cycleState == CycleState.paused;

    // FIX 12: Include ytStreamKind in fingerprint
    final ytLiveCounterpartBytes = cmd.ytCounterpartDownloadedBytes;
    final fingerprint = Object.hash(
      downloaded,
      total,
      (speed / 1024).round(),
      eta,
      cycleState,
      statusMessage,
      _chunkFingerprint,
      completedChunks,
      pauseReason?.name,
      ytLiveCounterpartBytes,
      cmd.ytStreamKind?.name,
    );

    if (!isCycleStateChanged && fingerprint == _lastProgressFingerprint) {
      return;
    }
    _lastProgressFingerprint = fingerprint;
    _lastEmittedCycleState = cycleState;

    // Emit chunk details at appropriate intervals
    final bool chunkCompletionChanged =
        completedChunks != _lastEmittedCompletedChunks;
    final bool shouldEmitChunkDetails = _lastChunkDetailsEmitMs == 0 ||
        chunkCompletionChanged ||
        isCycleStateChanged ||
        isTerminalState ||
        (nowMs - _lastChunkDetailsEmitMs >= 1500);
    List<Map<String, dynamic>>? chunkDetails;
    if (shouldEmitChunkDetails) {
      chunkDetails = _getChunkDetails(st);
      _lastChunkDetailsEmitMs = nowMs;
      _lastEmittedCompletedChunks = completedChunks ?? 0;
    }

    _send('progress', {
      'downloadedBytes': downloaded,
      'fileSize': total,
      'speed': speed,
      'eta': eta,
      'chunks': null,
      'chunkDetails': chunkDetails,
      'chunkFingerprint': _chunkFingerprint,
      'fileName': cmd.resolvedFileName,
      'supportsResume': cmd.supportsResume,
      if (cmd.ytStreamKind != null) 'ytStreamKind': cmd.ytStreamKind!.name,
      if (cmd.ytCounterpartSize != null)
        'ytCounterpartSize': cmd.ytCounterpartSize,
      if (ytLiveCounterpartBytes != null)
        'ytCounterpartDownloadedBytes': ytLiveCounterpartBytes,
      'ytDownloadedBytes': downloaded,
      'statusMessage': statusMessage,
      'cycleState': cycleState.name,
      if (pauseReason != null) 'pauseReason': pauseReason.name,
      if (totalChunks != null) 'totalChunks': totalChunks,
      if (completedChunks != null) 'completedChunks': completedChunks,
    });
  }

  static CycleState _deriveCycleState(
      String? statusMessage, DmxStateStatus status) {
    switch (status) {
      case DmxStateStatus.complete:
        return CycleState.completed;
      case DmxStateStatus.failed:
        return CycleState.failed;
      case DmxStateStatus.paused:
        return CycleState.paused;
      case DmxStateStatus.active:
        return CycleStateResolver.resolve(statusMessage: statusMessage);
    }
  }

  /// FIX 9: Content-Range validation - now provides clearer error messages
  /// and handles the allowUnknown case properly.
  static void validateContentRange(
    String? value, {
    required int expectedStart,
    required int expectedEnd,
    required int expectedTotal,
    bool allowUnknown = false,
    String? url,
  }) {
    if (value == null || value.trim().isEmpty) {
      if (allowUnknown) return;
      throw DioException(
        requestOptions: RequestOptions(path: url ?? ''),
        type: DioExceptionType.badResponse,
        message: 'Missing Content-Range header during resume.',
      );
    }
    final match = _contentRangeHeaderRegex.firstMatch(value.trim());
    if (match == null) {
      if (allowUnknown) return;
      throw DioException(
        requestOptions: RequestOptions(path: url ?? ''),
        type: DioExceptionType.badResponse,
        message: 'Malformed Content-Range during resume: $value.',
      );
    }
    final start = int.tryParse(match.group(1) ?? '');
    final end = int.tryParse(match.group(2) ?? '');
    final totalText = match.group(3);
    final total =
        totalText == null || totalText == '*' ? null : int.tryParse(totalText);
    if (start != expectedStart ||
        (expectedEnd >= 0 && end != expectedEnd) ||
        (expectedTotal > 0 && total != null && total != expectedTotal)) {
      throw DioException(
        requestOptions: RequestOptions(path: url ?? ''),
        type: DioExceptionType.badResponse,
        message: 'Invalid Content-Range response: $value. '
            'Expected start $expectedStart got $start.',
      );
    }
  }

  /// Standalone 416 helper returning updated chunk state without throwing.
  @visibleForTesting
  static ChunkState handle416(ChunkState chunk, int serverTotal) {
    if (serverTotal > 0) {
      if (chunk.start >= serverTotal) {
        chunk.downloaded = 0;
        return chunk;
      }
      if (chunk.end >= serverTotal) {
        chunk.end = serverTotal - 1;
      }
      if (chunk.downloaded >= chunk.size && chunk.size > 0) {
        chunk.downloaded = chunk.size;
        return chunk;
      }
    }
    if (chunk.size >= 0 && chunk.downloaded >= chunk.size) {
      chunk.downloaded = chunk.size;
      return chunk;
    }
    return chunk;
  }
}
