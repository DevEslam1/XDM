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
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';
import '../../constants/thresholds.dart';
import '../../domain/resume_identity.dart';
import '../bandwidth_governor.dart';
import '../checksum_service.dart';
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
    RegExp(r'text/html|application/xhtml(\+xml)?', caseSensitive: false);

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
        final taskId = (raw['taskId'] as String?) ?? jobId;
        final reply = raw['reply'] as SendPort;
        final cmd = DownloadCommand.fromMap(
            Map<String, dynamic>.from(raw['cmd'] as Map));
        final job = HttpTransferJob(cmd, reply);
        _runningJobs[jobId] = job;
        Future(() async {
          try {
            await job.run();
          } catch (e, st) {
            job.sendUnhandledError(e, st);
          } finally {
            _runningJobs.remove(jobId);
            poolPort.send({'t': 'idle', 'jobId': jobId, 'taskId': taskId});
          }
        });
        break;
      case 'cancel':
        final reasonStr = raw['reason'] as String?;
        final reason = PauseReason.fromName(reasonStr);
        final targetId = raw['jobId'] as String?;
        if (targetId != null) {
          final direct = _runningJobs[targetId];
          if (direct != null) {
            direct.requestCancel(reason);
          } else {
            for (final j in _runningJobs.values) {
              if (j.cmd.taskId == targetId) {
                j.requestCancel(reason);
              }
            }
          }
        }
        break;
      case 'flush':
        final reqId = raw['reqId'];
        Future(() async {
          final jobs = _runningJobs.values.toList(growable: false);
          for (final job in jobs) {
            try {
              await job.flushDurableState();
            } catch (_) {}
          }
          poolPort.send({'t': 'flushed', 'reqId': reqId});
        });
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
      if (!_multiThreadCancelToken.isCancelled) {
        _multiThreadCancelToken.cancel(_cancelToken.cancelError?.message);
      }
    }).catchError((e) {
      debugPrint('[IsolatePool] whenCancel failed: $e');
    }));
  }

  final DownloadCommand cmd;
  final SendPort out;
  final CancelToken _cancelToken = CancelToken();
  CancelToken _multiThreadCancelToken = CancelToken();
  int _seq = 0;
  bool _cancelRequested = false;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  void dispose() {
    _disposed = true;
    _abortAllDelays();
    cancelWatchdogs();
  }

  static const int maxPendingDelays = 16;
  static const Duration _maxChunkWallClock = Duration(minutes: 10);
  // F4: per-job stall threshold. This used to be a static field, which every
  // job running in the shared worker isolate overwrote with its own
  // cmd.stalledTimeoutMinutes — corrupting the stall detection of all peers.
  Duration stalledThreshold = const Duration(minutes: 5);
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
      // F26: reuse the tracked-timer bookkeeping for the fallback delay. The
      // previous fallback registered a fresh `_cancelToken.whenCancel.then`
      // listener on every call; Future listeners cannot be removed, so one
      // closure (timer + completer) leaked per capped call until cancel.
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
        if (!timerFired) {
          timer.cancel();
          _pendingTimers.remove(id);
        }
        _pendingDelays.remove(id);
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

  /// F25: serializes every operation on the single-stream [RandomAccessFile]
  /// (writeFrom / flush / close). The unawaited durable state-save runs its
  /// `preSaveFlush` (raf.flush) off the write loop; without this lock it can
  /// overlap an in-flight `writeFrom`, which dart:io rejects with
  /// "An async operation is currently pending" — the bogus "File system error"
  /// that aborted otherwise-healthy large single-stream downloads once the
  /// ~2MB state-save threshold was crossed.
  final Lock _streamRafLock = Lock();

  /// F26: set once resume-state persistence fails permanently. The write loops
  /// poll this and throw [StatePersistenceException]; we avoid cancelling the
  /// Dio token because the resulting `DioException(cancel)` would be misread as
  /// a user pause.
  bool _persistenceFailed = false;

  void _throwIfPersistenceFailed() {
    if (!_persistenceFailed) return;
    throw StatePersistenceException(
      'Cannot write resume data to the download folder. '
      'Pick a different folder or grant storage access.',
      directory: File(cmd.tempFilePath).parent.path,
    );
  }
  int _lastReportMs = 0;
  int _bytesSinceSave = 0;
  int _lastChunkDetailsHash = 0;
  List<Map<String, dynamic>>? _cachedChunkDetails;
  final Stopwatch _stopwatch = Stopwatch();
  final Queue<SpeedSample> _speedSamples = Queue();
  double _lastSpeed = 0.0;
  int _watchdogCheckpointBytes = 0;

  /// FIX(journal-init): tracks whether this job wrote the journal `init`
  /// record, so crash recovery knows the real threadCount/totalSize even
  /// after compaction (recovery previously fell back to chunk-list length /
  /// knownFileSize).
  bool _journalInitWritten = false;
  int _journalChunkWritesSinceCheckpoint = 0;
  static const int _journalCheckpointEveryChunks = 8;

  /// Server-advertised whole-file digest parsed from the `Digest` /
  /// `Repr-Digest` / `Content-Digest` response header (RFC 3230 / 9530), if the
  /// origin sent one. Captured once from the first successful transfer response
  /// and verified against the finished file in [_finalize]. `key` is the
  /// normalized algorithm (`sha256` / `sha1` / `md5`), `value` the hex digest.
  MapEntry<String, String>? _serverDigest;

  void _captureServerDigest(Headers headers) {
    if (_serverDigest != null) return;
    final raw = headers.value('digest') ??
        headers.value('repr-digest') ??
        headers.value('content-digest');
    final parsed = ChecksumService.parseDigestHeader(raw);
    if (parsed != null) _serverDigest = parsed;
  }

  /// FIX(C-2): Per-chunk progress already durable at job start (loaded from
  /// previous session's durable save / journal replay). Bytes written this
  /// session only count toward persisted state once the writer confirms the
  /// OS write succeeded (see PositionalFileWriter.flushedHighWater).
  List<int> _chunkDurabilityBaselines = const [];
  int _lastProgressBytes = 0;
  int _lastProgressTimeMs = 0;
  bool _stalledEmitted = false;
  int? _lastProgressFingerprint;
  CycleState? _lastEmittedCycleState;
  int _currentWriterBufferSize = 256 * 1024;
  int _lastChunkDetailsEmitMs = 0;
  int _lastEmittedCompletedChunks = -1;
  PauseReason? _pendingPauseReason;
  bool _urlChangedFromSavedState = false;

  /// Returns a strong validator suitable for an HTTP `If-Range` header.
  /// Weak ETags (`W/"..."`) are forbidden by RFC 9110 §13.1.5 in `If-Range`
  /// and cause conforming servers to return `200 OK` instead of `206`.
  @visibleForTesting
  static String? strongIfRangeValidator(String? etag, String? lastModified) {
    final trimmedEtag = etag?.trim();
    if (trimmedEtag != null && trimmedEtag.isNotEmpty) {
      if (trimmedEtag.startsWith('W/') || trimmedEtag.startsWith('w/')) {
        return null;
      }
      return trimmedEtag;
    }
    final trimmedLm = lastModified?.trim();
    if (trimmedLm != null && trimmedLm.isNotEmpty) {
      return trimmedLm;
    }
    return null;
  }

  static bool _isAntiBotChallenge(Response<dynamic>? response) {
    if (response == null) return false;
    final status = response.statusCode;
    if (status != 403 && status != 503) return false;
    final cfMitigated =
        response.headers.value('cf-mitigated')?.toLowerCase() ?? '';
    return cfMitigated.contains('challenge');
  }

  static bool _isExplicitHtmlPath(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return path.endsWith('.html') ||
        path.endsWith('.htm') ||
        path.endsWith('.xhtml');
  }

  PauseReason get effectivePauseReason =>
      _pendingPauseReason ?? PauseReason.userRequested;

  // F6: the writer of the in-flight multi-thread transfer, tracked so
  // requestCancel can flush buffered bytes and persist a durability-clamped
  // snapshot instead of raw live counters.
  PositionalFileWriter? _activeWriter;

  // Single-stream RAF tracked so requestCancel can flush single-stream buffers
  RandomAccessFile? _singleStreamRaf;

  Future<void>? _inFlightCancelWork;

  @visibleForTesting
  set activeWriterForTesting(PositionalFileWriter? writer) =>
      _activeWriter = writer;

  /// Flushes all active file/journal buffers and persists a durability-clamped
  /// state snapshot without cancelling the transfer (used on app background/detach).
  Future<void> flushDurableState() async {
    final st = _state;
    if (st == null || _disposed || _finalized) return;
    await _stateSaveLock.synchronized(() async {
      if (_disposed || _finalized) return;
      final writer = _activeWriter;
      if (writer != null && !writer.isClosed) {
        try {
          await writer.flushAll();
        } catch (e, stLog) {
          _log.fine('Writer flush on flushDurableState failed', e, stLog);
        }
      }
      final streamRaf = _singleStreamRaf;
      if (streamRaf != null) {
        try {
          await _streamRafLock.synchronized(() => streamRaf.flush());
        } catch (e, stLog) {
          _log.fine(
              'Single-stream RAF flush on flushDurableState failed', e, stLog);
        }
      }
      try {
        await DownloadJournal.flushAndSyncForFile(cmd.tempFilePath,
            taskId: cmd.taskId);
      } catch (_) {}
      try {
        await StateStore.save(
          cmd.tempFilePath,
          _durableStateSnapshot(st, writer),
          durable: true,
          taskId: cmd.taskId,
          allowRegression: true,
        );
      } catch (_) {}
    });
  }

  Future<void> requestCancel([PauseReason? reason]) {
    if (reason != null) {
      _pendingPauseReason = reason;
    }
    _abortAllDelays();
    final existing = _inFlightCancelWork;
    if (existing != null) {
      if (!_cancelToken.isCancelled) {
        _cancelToken.cancel('paused:${effectivePauseReason.name}');
      }
      return existing;
    }
    final work = () async {
      final st = _state;
      if (st != null && !_disposed && !_finalized) {
        st.status = DmxStateStatus.paused;
        st.pauseReason = effectivePauseReason;
        try {
          await DownloadJournal.flushAndSyncForFile(cmd.tempFilePath,
              taskId: cmd.taskId);
        } catch (_) {}
        // F6: workers can still be writing while this save runs — persisting
        // the raw live state could record counters beyond the flushed bytes.
        // Flush first, then save the durability-clamped snapshot.
        final writer = _activeWriter;
        if (writer != null && !writer.isClosed) {
          try {
            await writer.flushAll();
          } catch (e, stLog) {
            _log.fine('Writer flush on requestCancel failed', e, stLog);
          }
        }
        final streamRaf = _singleStreamRaf;
        if (streamRaf != null) {
          try {
            await _streamRafLock.synchronized(() => streamRaf.flush());
          } catch (e, stLog) {
            _log.fine('Single-stream RAF flush on requestCancel failed', e, stLog);
          }
        }
        if (!_stateSavedInCatch && !_disposed && !_finalized) {
          try {
            await StateStore.save(
                cmd.tempFilePath, _durableStateSnapshot(st, writer),
                durable: true, taskId: cmd.taskId, allowRegression: true);
          } catch (_) {}
        }
      }
      if (!_cancelToken.isCancelled) {
        _cancelToken.cancel('paused:${effectivePauseReason.name}');
      }
    }();
    _inFlightCancelWork = work;
    return work;
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

  /// Emits typed TransferResult containing classified taxonomy code and retryable flag.
  void sendUnhandledError(Object e, [StackTrace? stackTrace]) {
    // F9: the hard-timeout path already sent the error for this event; the
    // worker-entry catch re-invokes us with the follow-on cancel DioException
    // (and later teardown errors) — do not emit a duplicate.
    if (_timeoutErrorSent) return;
    // Diagnostic: the real exception object never crosses the isolate boundary
    // (only the classified string does), so surface its true type + OS details
    // HERE, in the worker, before it is reduced to "File system error".
    var diag = '${e.runtimeType}: $e';
    Object? probe = e;
    if (probe is DioException) probe = probe.error ?? probe;
    if (probe is FileSystemException) {
      diag = 'FileSystemException osError=${probe.osError} path=${probe.path}';
    } else if (probe is PositionalFileWriterException) {
      diag = 'PositionalFileWriterException: ${probe.message}';
    }
    _log.warning('[job-error] taskId=${cmd.taskId} $diag\n$stackTrace');
    debugPrint('[DMX-Job] unhandled error for ${cmd.taskId}: $diag');
    if (stackTrace != null) {
      debugPrint('[DMX-Job] stacktrace: $stackTrace');
    }
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
  // F9: set when onHardTimeout has emitted the explicit timeout error. The
  // follow-on cancel DioException must not be re-emitted as a second error
  // for the same event via sendUnhandledError (workerEntry catch).
  bool _timeoutErrorSent = false;

  @visibleForTesting
  Timer? get jobHealthTimerForTesting => _jobHealthTimer;

  /// FIX 13: Hard timeout now uses 50 KB/s baseline (was 100 KB/s) and
  /// has a lower minimum for small files.
  @visibleForTesting
  void registerWatchdogs() {
    stalledThreshold = Duration(
      minutes: cmd.stalledTimeoutMinutes,
    );
    final hardTimeoutDuration = _computeHardTimeout();
    void onHardTimeout() {
      // F10: a hard timeout is a timeout, not a user pause — persist the
      // correct pause reason so auto-resume policy sees the truth.
      if (_timeoutErrorSent) return;
      _timeoutErrorSent = true;
      requestCancel(PauseReason.timeout);
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
    final savedUrl = _state!.url;
    _urlChangedFromSavedState = savedUrl != null &&
        savedUrl.trim().isNotEmpty &&
        ResumeIdentity.normalizeUrl(savedUrl) !=
            ResumeIdentity.normalizeUrl(cmd.url);
    if (!_urlChangedFromSavedState && (savedUrl == null || savedUrl.isEmpty)) {
      _state!.url = cmd.url;
    }

    // FIX(C-3): Resolve a known file size BEFORE any redistribution. Previously
    // the size fix-up ran *after* redistribution, so an unknown-size download
    // (totalSize 0 → plan() returns one indeterminate chunk with size == −1)
    // produced nEnd = start + size = −1 → zero range overlap on every old
    // chunk → all downloaded bytes wiped and the journal already cleared:
    // unrecoverable full re-download whenever the thread count changed.
    if (_state!.totalSize <= 0 && cmd.knownFileSize > 0) {
      _state!.totalSize = cmd.knownFileSize;
    }

    // Redistribute chunks if thread count changed.
    // FIX(C-3): never re-plan an unknown-size (indeterminate) layout — there
    // are no byte ranges to map overlap against, so redistribution can only
    // destroy progress. The indeterminate chunk is carried verbatim instead.
    final hasIndeterminateProgress =
        _state!.chunks.any((c) => c.isIndeterminate);
    // FIX(CORRUPT-RESUME): If progress has already been downloaded (> 0 bytes),
    // NEVER re-partition chunks into a new grid. In multithreaded downloads,
    // progress across chunks is non-contiguous. Summing overlaps into a single
    // linear chunk prefix skips un-downloaded byte ranges, creating permanent
    // zero-byte holes on disk.
    // Instead, retain existing chunk boundaries (which map 1:1 to physical disk
    // segments); the worker pool naturally processes pending chunks.
    // If downloadedBytes == 0, re-planning to the new thread count is safe.
    if (_state!.chunks.isNotEmpty &&
        _state!.chunks.length != cmd.threadCount &&
        _state!.totalSize > 0 &&
        !hasIndeterminateProgress) {
      if (_state!.downloadedBytes == 0) {
        _state!.chunks = ChunkScheduler.plan(
          totalSize: _state!.totalSize,
          threadCount: cmd.threadCount,
        );
        _state!.threadCount = cmd.threadCount;
        debugPrint(
          '[Resume] Re-planned 0-progress chunks: '
          '${load.state.chunks.length} → ${cmd.threadCount}',
        );
      } else {
        debugPrint(
          '[Resume] Preserving ${_state!.chunks.length} physical chunks '
          '(${_state!.downloadedBytes} bytes downloaded) for concurrency ${cmd.threadCount}',
        );
      }
    }

    if (_state!.chunks.isEmpty) {
      final canMulti = _state!.totalSize > 0 &&
          cmd.supportsResume &&
          cmd.threadCount > 1 &&
          _state!.totalSize >= ChunkScheduler.minSizeForMultithread;
      if (canMulti) {
        _state!.chunks = ChunkScheduler.plan(
          totalSize: _state!.totalSize,
          threadCount: cmd.threadCount,
        );
        _state!.threadCount = cmd.threadCount;
      } else {
        _state!.chunks = ChunkScheduler.singleStream(_state!.totalSize);
        _state!.threadCount = 1;
      }
    }

    _state!.status = DmxStateStatus.active;
    await StateStore.save(cmd.tempFilePath, _state!,
        taskId: cmd.taskId, allowRegression: true);
    // FIX(C-2): capture durability baselines once the final chunk layout is
    // settled (after redistribution / size fix-up).
    _chunkDurabilityBaselines =
        List<int>.from(_state!.chunks.map((c) => c.downloaded));

    if (_state!.downloadedBytes > 0) {
      _stalledEmitted = false;
      _emitProgress(0,
          statusMessage: 'Verifying resume data…',
          cycleStateOverride: CycleState.verifying);
      if (cmd.supportsResume || _urlChangedFromSavedState) {
        await _verifyServerIdentity(dio);
      }
      _emitProgress(0,
          statusMessage: 'Resuming…', cycleStateOverride: CycleState.resuming);
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
        // F16: the wipe (temp file + state + journal) must complete before
        // the single-stream download opens its own writer on the same path.
        await _resetToSingleStream();
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
    _stateSavedInCatch = false;
    _stopwatch.start();
    final dio = buildTransferDio(
      url: cmd.punyUrl,
      customUserAgent: cmd.customUserAgent,
      referer: cmd.referer,
      cookies: cmd.cookies,
      oauthToken: cmd.oauthToken,
      authUsername: cmd.authUsername,
      authPassword: cmd.authPassword,
      customHeaders: cmd.customHeaders,
      httpsOnly: cmd.httpsOnly,
      proxyType: cmd.proxyType,
      proxyHost: cmd.proxyHost,
      proxyPort: cmd.proxyPort,
      proxyUsername: cmd.proxyUsername,
      proxyPassword: cmd.proxyPassword,
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
      final cancelWork = _inFlightCancelWork;
      if (cancelWork != null) {
        try {
          await cancelWork;
        } catch (_) {}
      }
      // FIX 15: Check _stateSavedInCatch before saving in finally
      if (!_stateSavedInCatch && _state != null && !_finalized) {
        try {
          // Force flush any pending state save microtask first
          _stateSavePending = false;
          await StateStore.save(cmd.tempFilePath, _state!,
              taskId: cmd.taskId, allowRegression: true);
        } catch (e, st) {
          _log.fine('Failed to save state during job finalize', e, st);
        }
      }
      _cachedChunkDetails = null;
      _lastChunkDetailsHash = 0;
      _disposed = true;
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
    // F3: align the code with the documented 50 KB/s baseline (the constant
    // was still 100 KB/s, computing timeouts twice as generous as intended).
    final computed = Duration(seconds: totalSize ~/ (50 * 1024));
    if (computed < minTimeout) return minTimeout;
    if (computed > maxTimeout) return maxTimeout;
    return computed;
  }

  Duration _computeHardTimeout() {
    // F10: test seam — a null override falls through to the computed value.
    final override = hardTimeoutForTesting;
    if (override != null) return override;
    final st = _state;
    if (st == null || st.totalSize <= 0) return defaultTaskHardTimeout;
    return computeHardTimeoutForSize(st.totalSize);
  }

  /// Test-only override for the hard-timeout watchdog duration.
  @visibleForTesting
  static Duration? hardTimeoutForTesting;

  @visibleForTesting
  void startStopwatchForTesting() => _stopwatch.start();

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

  /// Verifies up to 2 already-downloaded byte slices on disk against [cmd.punyUrl].
  /// Returns `true` if all sampled ranges match byte-for-byte, `false` if the
  /// server returned valid 206 bytes that differ from disk, or `null` if the
  /// probe could not verify (network/403/5xx/HTML/non-206).
  Future<bool?> _verifyDiskBytesAgainstServer(Dio dio) async {
    final st = _state;
    if (st == null || st.chunks.isEmpty) return null;
    final tempFile = File(cmd.tempFilePath);
    if (!await tempFile.exists()) return null;
    final diskLen = await tempFile.length();
    if (diskLen <= 0) return null;

    const sliceMax = 16 * 1024;
    final samples = <({int start, int length})>[];
    for (final c in st.chunks) {
      if (c.downloaded <= 0) continue;
      final availableOnDisk = min(c.downloaded, diskLen - c.start);
      if (availableOnDisk <= 0) continue;
      samples.add((start: c.start, length: min(sliceMax, availableOnDisk)));
      break;
    }
    for (final c in st.chunks.reversed) {
      if (c.downloaded <= 0) continue;
      final availableOnDisk = min(c.downloaded, diskLen - c.start);
      if (availableOnDisk <= 0) continue;
      final len = min(sliceMax, availableOnDisk);
      final start = c.start + availableOnDisk - len;
      if (samples.isEmpty ||
          start >= samples.first.start + samples.first.length) {
        samples.add((start: start, length: len));
      }
      break;
    }
    if (samples.isEmpty) return null;

    RandomAccessFile? raf;
    try {
      raf = await tempFile.open(mode: FileMode.read);
      for (final sample in samples) {
        await raf.setPosition(sample.start);
        final diskBytes = await raf.read(sample.length);
        if (diskBytes.length != sample.length) return null;

        final response = await dio.get<ResponseBody>(
          cmd.punyUrl,
          cancelToken: _cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: true,
            headers: {
              'Range':
                  'bytes=${sample.start}-${sample.start + sample.length - 1}',
            },
            validateStatus: (_) => true,
          ),
        );
        if (_isAntiBotChallenge(response) || response.statusCode != 206) {
          await response.data?.stream.listen((_) {}).cancel();
          return null;
        }
        final respContentType =
            response.headers.value('content-type')?.toLowerCase() ?? '';
        if (_htmlContentTypeRegex.hasMatch(respContentType) &&
            !_isExplicitHtmlPath(cmd.punyUrl)) {
          await response.data?.stream.listen((_) {}).cancel();
          return null;
        }
        final cr = response.headers.value('content-range');
        if (cr != null) {
          final match = _contentRangeHeaderRegex.firstMatch(cr.trim());
          if (match != null) {
            final crStart = int.tryParse(match.group(1) ?? '');
            final crTotalText = match.group(3);
            final crTotal = crTotalText == null || crTotalText == '*'
                ? null
                : int.tryParse(crTotalText);
            if (crStart != sample.start) {
              await response.data?.stream.listen((_) {}).cancel();
              return null;
            }
            if (st.totalSize > 0 && crTotal != null && crTotal != st.totalSize) {
              await response.data?.stream.listen((_) {}).cancel();
              return false;
            }
          }
        }
        final stream = response.data?.stream;
        if (stream == null) return null;
        final builder = BytesBuilder(copy: false);
        await for (final b in stream) {
          builder.add(b);
          if (builder.length > sample.length) {
            break;
          }
        }
        final netBytes = builder.takeBytes();
        if (netBytes.length < diskBytes.length) return null;
        final compared = netBytes.length == diskBytes.length
            ? netBytes
            : Uint8List.sublistView(netBytes, 0, diskBytes.length);
        if (!listEquals(compared, diskBytes)) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return null;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  /// Verifies server identity (etag/last-modified) to detect file changes
  /// and enriches knowledge with Range support, TTFB, and initial goodput estimate.
  Future<void> _verifyServerIdentity(Dio dio) async {
    final savedUrl = _state!.url;
    final urlChanged = savedUrl != null &&
        savedUrl.trim().isNotEmpty &&
        ResumeIdentity.normalizeUrl(savedUrl) !=
            ResumeIdentity.normalizeUrl(cmd.url);
    if (urlChanged) {
      _urlChangedFromSavedState = true;
      invalidateIdentityCacheForUrl(savedUrl);
    }
    final cacheKey =
        '${Uri.tryParse(cmd.punyUrl)?.host}|${_state!.etag}|${_state!.lastModified}|${_state!.totalSize}';
    final identityCache = ServerIdentityCache.instance;
    identityCache.removeStale(const Duration(minutes: 10));
    if (!urlChanged && identityCache.containsKey(cacheKey)) {
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
      final status = response.statusCode;
      final host = Uri.tryParse(cmd.punyUrl)?.host.toLowerCase() ?? '';
      if (_isAntiBotChallenge(response)) {
        await response.data?.stream.listen((_) {}).cancel();
        throw DioException(
          requestOptions: response.requestOptions,
          type: DioExceptionType.badResponse,
          response: response,
          message:
              'Blocked by anti-bot challenge (Cloudflare HTTP $status). '
              'Open in browser or update link.',
        );
      }
      final isYtOrSigned = _isExpiredUrlOrSite(cmd.url, host);
      // F11: Check for expired URL (401, 403, 410) directly since validateStatus: (_) => true prevents DioException
      if (isYtOrSigned &&
          (status == 401 || status == 403 || status == 410)) {
        await response.data?.stream.listen((_) {}).cancel();
        identityCache.remove(cacheKey);
        _emitProgress(0,
            statusMessage: 'Refreshing links…',
            cycleStateOverride: CycleState.updatingLinks);
        if (_state != null) {
          _state!.cycleState = CycleState.updatingLinks.name;
          try {
            await StateStore.save(cmd.tempFilePath, _state!,
                durable: true, taskId: cmd.taskId, allowRegression: true);
          } catch (e, st) {
            _log.fine('Failed to save state on expired URL', e, st);
          }
        }
        await Future.delayed(const Duration(milliseconds: 10));
        throw UrlExpiredException(
          'YouTube / signed URL expired during identity probe (HTTP $status).',
        );
      }
      if (response.statusCode == 206 || response.statusCode == 200) {
        final contentType =
            response.headers.value('content-type')?.toLowerCase() ?? '';
        if (_htmlContentTypeRegex.hasMatch(contentType) &&
            !_isExplicitHtmlPath(cmd.punyUrl)) {
          await response.data?.stream.listen((_) {}).cancel();
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            response: response,
            message: 'HTML_INSTEAD_OF_MEDIA',
          );
        }

        final contentRange = response.headers.value('content-range');
        _probeSupportsRange = response.statusCode == 206;

        int? serverTotal;
        if (response.statusCode == 206) {
          if (contentRange != null) {
            serverTotal = int.tryParse(
                _contentRangeTotalRegex.firstMatch(contentRange)?.group(1) ??
                    '');
          }
        } else {
          serverTotal = int.tryParse(
              response.headers.value(Headers.contentLengthHeader) ?? '');
        }
        final newEtag = response.headers.value('etag');
        final newLm = response.headers.value('last-modified');

        if (response.statusCode == 200) {
          try {
            await response.data?.stream.listen((_) {}).cancel();
          } catch (_) {}
        } else {
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
        }

        final isYoutubeTransfer = cmd.ytStreamKind != null ||
            _googlevideoHostRegex.hasMatch(host) ||
            host.contains('youtube.com') ||
            host.contains('youtu.be');

        if (serverTotal != null && serverTotal > 0) {
          if (_state!.totalSize <= 0) {
            _state!.totalSize = serverTotal;
          } else {
            final mismatch = isYoutubeTransfer
                ? (serverTotal - _state!.totalSize).abs() >
                    (_state!.totalSize * 0.001)
                        .clamp(2048.0, 10 * 1024 * 1024)
                : serverTotal != _state!.totalSize;
            if (mismatch) {
              if (urlChanged) {
                throw DioException(
                  requestOptions: response.requestOptions,
                  type: DioExceptionType.badResponse,
                  response: response,
                  message:
                      'Updated link file size ($serverTotal B) does not match '
                      'existing download (${_state!.totalSize} B). Progress preserved.',
                );
              }
              await StateStore.resetTransferState(
                cmd.tempFilePath,
                taskId: cmd.taskId,
                state: _state,
                deleteTempFile: true,
              );
              _log.info(
                  '[Journal-J1] Server size changed ($serverTotal vs ${_state!.totalSize}); wiped state and journal');
              _state!.totalSize = serverTotal;
              await StateStore.save(cmd.tempFilePath, _state!,
                  durable: true, taskId: cmd.taskId, allowRegression: true);
              throw FileChangedOnServerException();
            }
          }
        }

        if (response.statusCode == 200 &&
            urlChanged &&
            _state!.downloadedBytes > 0) {
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            response: response,
            message:
                'Updated link does not support byte-range resume (HTTP 200); '
                'existing downloaded data preserved.',
          );
        }

        final oldIdentity = firstNonEmpty(_state!.etag, _state!.lastModified);
        final newIdentity = firstNonEmpty(newEtag, newLm);
        final identityChanged = oldIdentity != null &&
            newIdentity != null &&
            oldIdentity != newIdentity;
        if (_state!.downloadedBytes > 0 && (urlChanged || identityChanged)) {
          final matched = await _verifyDiskBytesAgainstServer(dio);
          if (matched == true) {
            _state!.url = cmd.url;
            _state!.etag = newEtag ?? _state!.etag;
            _state!.lastModified = newLm ?? _state!.lastModified;
            _urlChangedFromSavedState = false;
            await StateStore.save(cmd.tempFilePath, _state!,
                durable: true, taskId: cmd.taskId, allowRegression: true);
          } else if (matched == null) {
            if (urlChanged) {
              throw DioException(
                requestOptions: response.requestOptions,
                type: DioExceptionType.badResponse,
                response: response,
                message:
                    'Could not verify updated link against existing partial data. '
                    'Progress preserved.',
              );
            }
          } else {
            if (urlChanged) {
              throw DioException(
                requestOptions: response.requestOptions,
                type: DioExceptionType.badResponse,
                response: response,
                message:
                    'Updated link content differs from already-downloaded bytes. '
                    'Progress preserved.',
              );
            }
            debugPrint('[DMX-Job] resource identity changed — restarting');
            await StateStore.resetTransferState(
              cmd.tempFilePath,
              taskId: cmd.taskId,
              state: _state,
              deleteTempFile: true,
            );
            _log.info(
                '[Journal-J1] Server identity changed ($oldIdentity -> $newIdentity); wiped state and journal');
            _state!.etag = newEtag;
            _state!.lastModified = newLm;
            _state!.migrationNote =
                '${_state!.migrationNote ?? ''} identity_restart'.trim();
            await StateStore.save(cmd.tempFilePath, _state!,
                durable: true, taskId: cmd.taskId, allowRegression: true);
            _emitProgress(0,
                statusMessage: 'Source changed on server — restarting');
          }
        } else {
          _state!.url = cmd.url;
          _state!.etag ??= newEtag;
          _state!.lastModified ??= newLm;
          _urlChangedFromSavedState = false;
        }
        final verifiedCacheKey =
            '${Uri.tryParse(cmd.punyUrl)?.host}|${_state!.etag}|${_state!.lastModified}|${_state!.totalSize}';
        identityCache.put(verifiedCacheKey, true);
      } else {
        await response.data?.stream.listen((_) {}).cancel();
        if (urlChanged && status != null && status >= 400) {
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            response: response,
            message:
                'Updated link returned HTTP $status. Progress preserved.',
          );
        }
      }
    } on FileChangedOnServerException {
      identityCache.remove(cacheKey);
      rethrow;
    } on DioException catch (e) {
      if (_isAntiBotChallenge(e.response) ||
          e.message == 'HTML_INSTEAD_OF_MEDIA' ||
          e.type == DioExceptionType.badResponse) {
        identityCache.remove(cacheKey);
        rethrow;
      }
      final status = e.response?.statusCode;
      final host = Uri.tryParse(cmd.punyUrl)?.host.toLowerCase() ?? '';
      final isYtOrSigned = _isExpiredUrlOrSite(cmd.url, host);
      // F11: 410 Gone also signals an expired signed URL.
      if (isYtOrSigned &&
          (status == 401 || status == 403 || status == 410)) {
        identityCache.remove(cacheKey);
        _emitProgress(0,
            statusMessage: 'Refreshing links…',
            cycleStateOverride: CycleState.updatingLinks);
        if (_state != null) {
          _state!.cycleState = CycleState.updatingLinks.name;
          try {
            await StateStore.save(cmd.tempFilePath, _state!,
                durable: true, taskId: cmd.taskId, allowRegression: true);
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

  @visibleForTesting
  Future<void> resetToSingleStreamForTesting() => _resetToSingleStream();

  Future<void> _resetToSingleStream() async {
    final st = _state!;
    _log.info(
        'resume_range_ignored: resetting to single-stream for ${cmd.taskId}');
    _send('telemetry', {
      'event': 'resume_range_ignored',
      'taskId': cmd.taskId,
      'url': cmd.url,
    });
    if (!_multiThreadCancelToken.isCancelled) {
      _multiThreadCancelToken.cancel('fallback_to_single_stream');
    }
    if (_activeWriter != null) {
      try {
        await _activeWriter!.close();
      } catch (e, stLog) {
        _log.fine('Closing active writer during reset to single-stream', e, stLog);
      }
      _activeWriter = null;
    }
    _multiThreadCancelToken = CancelToken();
    // F16: this must complete before the single-stream download opens its
    // writer. The reset deletes the temp file, the state snapshot, and the
    // journal; running it concurrently with the new download raced the
    // unlink against the first writes (POSIX: unlinked inode breaks the
    // finalize rename; Windows: the delete was silently swallowed).
    await StateStore.resetTransferState(
      cmd.tempFilePath,
      taskId: cmd.taskId,
      state: st,
      deleteTempFile: true,
    );
    st.chunks = ChunkScheduler.singleStream(st.totalSize);
    st.threadCount = 1;
    _chunkDurabilityBaselines =
        List<int>.from(st.chunks.map((c) => c.downloaded));
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
      final innerSink = ChunkedConversionSink<Digest>.withCallback((results) {
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
        : cmd.threadCount.clamp(1, 16);

    if (st.chunks.isEmpty) {
      st.chunks = ChunkScheduler.plan(
        totalSize: st.totalSize,
        threadCount: targetConcurrency,
      );
      st.threadCount = targetConcurrency;
      _chunkDurabilityBaselines =
          List<int>.from(st.chunks.map((c) => c.downloaded));
    }

    PositionalFileWriter writer;
    final hasPriorBytes = st.downloadedBytes > 0;
    if (hasPriorBytes && await File(cmd.tempFilePath).exists()) {
      // F17: capture the REAL disk length BEFORE openForResume pre-sizes the
      // file to totalSize (zero-filling any holes). Once the file is
      // pre-extended, a chunk claiming more bytes than the disk actually
      // holds becomes undetectable — the stale J4 pre-flight in _runChunk
      // compares against the inflated length and never fires, so resume
      // would replay only the tail over a zero-filled hole and the final
      // size check would still pass. Treat the on-disk length as truth.
      final diskLenBeforeExtend = await File(cmd.tempFilePath).length();
      var clampedAny = false;
      for (final c in st.chunks) {
        if (c.downloaded > 0 && c.start + c.downloaded > diskLenBeforeExtend) {
          final durable = (diskLenBeforeExtend - c.start).clamp(0, c.downloaded);
          _log.warning(
            '[F17] Chunk [${c.start}..${c.end}] claims ${c.downloaded} bytes '
            'but disk ends at $diskLenBeforeExtend — clamping to $durable.',
          );
          c.downloaded = durable;
          // The recorded digest no longer covers the clamped prefix.
          c.hash = null;
          clampedAny = true;
        }
      }
      if (clampedAny) {
        st.migrationNote =
            '${st.migrationNote ?? ''} f17_disk_truth_clamp'.trim();
        await StateStore.save(cmd.tempFilePath, st,
            durable: true, taskId: cmd.taskId, allowRegression: true);
      }
      _chunkDurabilityBaselines =
          List<int>.from(st.chunks.map((c) => c.downloaded));
      writer = await PositionalFileWriter.openForResume(cmd.tempFilePath,
          threadCount: st.threadCount,
          totalSize: st.totalSize,
          diskWriteBatching: cmd.diskWriteBatching);
    } else {
      writer = await PositionalFileWriter.open(cmd.tempFilePath,
          totalSize: st.totalSize,
          threadCount: st.threadCount,
          diskWriteBatching: cmd.diskWriteBatching);
      for (final c in st.chunks) {
        c.downloaded = 0;
      }
      _chunkDurabilityBaselines =
          List<int>.from(st.chunks.map((c) => c.downloaded));
    }
    // F6: let requestCancel flush + clamp against this writer while the
    // transfer is running.
    _activeWriter = writer;

    final governor = BandwidthGovernor(
      _effectiveGlobalLimit(),
      1.0,
      cmd.throttleFactor,
    );
    governor.registerConsumer();
    if (cmd.speedLimitKbps > 0) {
      governor.setTaskLimit(cmd.taskId, cmd.speedLimitKbps * 125);
    }

    if (hasPriorBytes && cmd.resumeIntegrityCheck) {
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

      // F26: the workers poll this flag and rethrow, but a worker that exited
      // just before the flag was set could leave the scheduling pass clean.
      _throwIfPersistenceFailed();

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
            reconcileChunksWithDisk(st, actualLen);
          }
        } catch (e, stLog) {
          _log.fine('Reconcile with disk on cancel failed', e, stLog);
        }
        _stateSavedInCatch = true;
        await _stateSaveLock.synchronized(() async {
          await StateStore.save(
              cmd.tempFilePath, _durableStateSnapshot(st, writer),
              durable: true, taskId: cmd.taskId, allowRegression: true);
        });
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
        // FIX(C-2): persist the durability-clamped snapshot — previously a
        // failed flush was logged and then the *inflated* live counters were
        // saved anyway, letting resume trust bytes that never hit the disk.
        await _stateSaveLock.synchronized(() async {
          await StateStore.save(
              cmd.tempFilePath, _durableStateSnapshot(st, writer),
              durable: true, taskId: cmd.taskId, allowRegression: true);
          _stateSavedInCatch = true;
        });
        _emitProgress(0, statusMessage: _formatFailedMessage(e));
      }
      rethrow;
    } finally {
      _activeWriter = null;
      governor.removeTaskLimit(cmd.taskId);
      governor.unregisterConsumer();
      governor.dispose();
      try {
        await writer.close();
      } catch (closeErr, closeSt) {
        // F8: close() rethrows InsufficientStorage/WriterException from its
        // final flush. Throwing here (a finally block) would REPLACE the
        // in-flight error — e.g. turning a cancel-triggered pause into a
        // failure — so log and continue, preserving the original semantics.
        _log.fine(
            'Writer close after transfer end failed (original error preserved)',
            closeErr,
            closeSt);
      }
    }
  }

  /// F7: reconcile persisted chunk counters with the real on-disk length at
  /// pause time. Each chunk keeps what its own range actually holds on disk:
  /// `clamp(actualLen - c.start, 0, c.downloaded)`.
  ///
  /// The previous implementation subtracted already-consumed bytes from a
  /// rolling `remaining` counter AND then subtracted the absolute `c.start`
  /// from it again — double-counting chunk starts, discarding real frontier
  /// progress — and clamped indeterminate chunks (size < 0) to 0 outright.
  @visibleForTesting
  void reconcileChunksWithDisk(TransferState st, int actualLen) {
    for (final c in st.chunks) {
      final allowance = (actualLen - c.start).clamp(0, c.downloaded);
      c.downloaded = allowance;
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
    // F13: the scheduling loop may need extra passes — e.g. under
    // maxConcurrency == 1 the only worker re-queues a chunk after exhausting
    // its retries and then retires, which previously stranded the queue (the
    // chunk was never picked up and surfaced later as a
    // DownloadIntegrityException). Re-run the loop, bounded.
    var passCompleter = completer;

    Future<void> spawnWorker(int workerId) async {
      runningWorkers++;
      try {
        activeSpeedPredictors[workerId] = SpeedPredictor();
        if (_probeInitialGoodputBps != null && _probeInitialGoodputBps! > 0) {
          activeSpeedPredictors[workerId]!.addSample(_probeInitialGoodputBps!);
        }

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
                // Guard: verify second chunk starts strictly ahead of parent's current progress
                // with safety margin so in-flight network buffers don't overshoot first.end
                if (second.start > parent.start + parent.downloaded + 65536) {
                  parent.end = first.end;
                  st.chunks.add(second);
                  if (_chunkDurabilityBaselines.length < st.chunks.length) {
                    _chunkDurabilityBaselines.add(0);
                  }
                  st.threadCount = st.chunks.length;
                  chunkIndex = st.chunks.length - 1;
                  debugPrint(
                    '[AdaptiveScheduler] Split hottest chunk $bestHottest -> '
                    'new chunk $chunkIndex (range ${second.start}-${second.end})',
                  );
                }
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
                    host, max(4, runningWorkers - 1));
              }

              if (attempts >= maxAttempts) {
                final nextMirror = failover.advance(failover.activeUrl);
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
        if (!_multiThreadCancelToken.isCancelled) {
          _multiThreadCancelToken.cancel('worker_permanent_error');
        }
        if (!failFast.isCompleted) failFast.complete();
      } finally {
        activeChunkIndices.remove(workerId);
        activeSpeedPredictors.remove(workerId);
        runningWorkers--;
        if (runningWorkers == 0 && !passCompleter.isCompleted) {
          passCompleter.complete();
        }
      }
    }

    // F13: bounded scheduling passes. The normal case completes in one pass
    // (queue drained, workers exit); a pass only repeats when workers retired
    // while chunks were still queued.
    const maxSchedulingPasses = 3;
    for (var pass = 0; pass < maxSchedulingPasses; pass++) {
      if (pendingQueue.isEmpty) break;
      if (_cancelRequested || _cancelToken.isCancelled) break;
      if (failFast.isCompleted) break;
      if (pass > 0) {
        passCompleter = Completer<void>();
        debugPrint(
            '[AdaptiveScheduler] F13: re-running scheduling pass $pass with '
            '${pendingQueue.length} queued chunk(s)');
      }
      final initialWorkers = min(maxConcurrency, max(1, pendingQueue.length));
      for (var i = 0; i < initialWorkers; i++) {
        unawaited(spawnWorker(nextWorkerId++));
      }

      await passCompleter.future;
    }

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
        if (chunk.hash == null) continue;
        // F17: an incomplete chunk that was resumed with data can carry a
        // proven hash covering only its downloaded prefix (recorded at the
        // chunk-boundary save). Digest exactly that prefix — hashing the
        // full chunk size would compare against the un-downloaded tail and
        // always fail, which is why incomplete chunks were previously
        // excluded from verification altogether.
        final verifyLen = chunk.isComplete ? chunk.size : chunk.downloaded;
        if (verifyLen <= 0) continue;
        final diskHash = await _computeChunkDiskSha256(
          cmd.tempFilePath,
          chunk.start,
          verifyLen,
        );
        if (diskHash.toLowerCase() != chunk.hash!.toLowerCase()) {
          _log.warning(
            '[IntegrityPipeline] Corrupted chunk detected at index $i (range ${chunk.start}-${chunk.end}). '
            'Expected hash: ${chunk.hash}, actual: $diskHash. Triggering re-download of ONLY this chunk.',
          );
          corruptedChunks.add(i);
        }
      }

      if (corruptedChunks.isEmpty) {
        _log.info(
            '[IntegrityPipeline] All ${st.chunks.length} chunks verified OK.');
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
        if (i < _chunkDurabilityBaselines.length) {
          _chunkDurabilityBaselines[i] = 0;
        }
        await writer.resetChunkHighWater(i);
      }
      await StateStore.save(cmd.tempFilePath, st,
          durable: true, taskId: cmd.taskId, allowRegression: true);

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

  /// Advances to next mirror and probes identity to prevent corrupting chunk resume.
  Future<String?> _advanceChunkMirror({
    required Dio dio,
    required MirrorFailover failover,
    required String currentUrl,
    required ChunkState chunk,
  }) async {
    final next = failover.advance(currentUrl);
    if (next == null) return null;
    try {
      final probe = await dio.head(
        next,
        cancelToken: _multiThreadCancelToken,
        options: Options(
          followRedirects: true,
          validateStatus: (s) => s != null && s < 400,
        ),
      );
      final newClStr = probe.headers.value(Headers.contentLengthHeader);
      final newCl = newClStr != null ? int.tryParse(newClStr) : null;
      final newEtag = probe.headers.value('etag');
      final newLm = probe.headers.value('last-modified');

      final oldTotal = _state?.totalSize ?? 0;
      final oldEtag = _state?.etag;
      final oldLm = _state?.lastModified;

      var mismatch = false;
      if (oldTotal > 0 && newCl != null && newCl > 0 && newCl != oldTotal) {
        mismatch = true;
      }
      if (oldEtag != null && newEtag != null && oldEtag != newEtag) {
        mismatch = true;
      }
      if (oldLm != null && newLm != null && oldLm != newLm) {
        mismatch = true;
      }
      if (mismatch) {
        _log.warning(
          '[MirrorFailover] Mirror $next metadata differs from original source. '
          'Zeroing chunk progress to prevent corruption.',
        );
        chunk.downloaded = 0;
      }
    } catch (e, st) {
      _log.fine('[MirrorFailover] HEAD probe on mirror $next failed: $e', e, st);
    }
    return next;
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
    var skipIfRangeThisChunk = false;
    final chunkStartWallClock = DateTime.now();

    while (!chunk.isComplete) {
      _throwIfCancelled();
      final chunkSw = Stopwatch()..start();
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
        int currentDiskLen = 0;
        try {
          if (tempFile.existsSync()) {
            currentDiskLen = tempFile.lengthSync();
          }
        } catch (_) {
          currentDiskLen = 0;
        }
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
        if (resumeFrom > 0 && !skipIfRangeThisChunk && !_urlChangedFromSavedState) {
          final ifRange =
              strongIfRangeValidator(_state!.etag, _state!.lastModified);
          if (ifRange != null) headers['If-Range'] = ifRange;
        }
        final response = await dio.get<ResponseBody>(
          activeUrl,
          cancelToken: _multiThreadCancelToken,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: true,
            headers: headers,
            validateStatus: (_) => true,
          ),
        );

        if (response.statusCode == 200) {
          await response.data?.stream.listen((_) {}).cancel();
          if (headers.containsKey('If-Range') && resumeFrom > 0) {
            _log.info(
                'HTTP 200 received with If-Range validator on chunk $chunkIndex — '
                're-verifying without If-Range');
            skipIfRangeThisChunk = true;
            _state!.etag = null;
            _state!.lastModified = null;
            invalidateIdentityCacheForUrl(cmd.punyUrl);
            await _verifyServerIdentity(dio);
            continue;
          }
          if (_urlChangedFromSavedState && (_state?.downloadedBytes ?? 0) > 0) {
            throw DioException(
              requestOptions: response.requestOptions,
              type: DioExceptionType.badResponse,
              response: response,
              message:
                  'Updated link does not support byte-range resume (HTTP 200); '
                  'existing downloaded data preserved.',
            );
          }
          _send('telemetry', {
            'event': 'range_not_supported_200',
            'taskId': cmd.taskId,
            'url': cmd.url,
          });
          if (resumeFrom > 0) {
            chunk.downloaded = 0;
            if (chunkIndex < _chunkDurabilityBaselines.length) {
              _chunkDurabilityBaselines[chunkIndex] = 0;
            }
            await writer.resetChunkHighWater(chunkIndex);
            try {
              await StateStore.resetTransferState(cmd.tempFilePath,
                  taskId: cmd.taskId);
            } catch (e, st) {
              _log.fine('Failed to reset state store on HTTP 200 resume reject',
                  e, st);
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
          if (_isAntiBotChallenge(response)) {
            throw DioException(
              requestOptions: response.requestOptions,
              type: DioExceptionType.badResponse,
              response: response,
              message:
                  'Blocked by anti-bot challenge (Cloudflare HTTP ${response.statusCode}). '
                  'Open in browser or update link.',
            );
          }
          if (response.statusCode == 401 ||
              response.statusCode == 403 ||
              response.statusCode == 410) {
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
                      durable: true, taskId: cmd.taskId, allowRegression: true);
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
        if (_htmlContentTypeRegex.hasMatch(contentType) &&
            !_isExplicitHtmlPath(cmd.punyUrl)) {
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
            allowUnknown: (chunk.downloaded == 0 && absStart == 0) ||
                (response.headers.value('content-range') == null &&
                    response.statusCode == 206),
            url: cmd.punyUrl,
          );
        } on DioException {
          chunk.downloaded = 0;
          if (chunkIndex < _chunkDurabilityBaselines.length) {
            _chunkDurabilityBaselines[chunkIndex] = 0;
          }
          await writer.resetChunkHighWater(chunkIndex);
          rethrow;
        }

        _state!.etag ??= response.headers.value('etag');
        _state!.lastModified ??= response.headers.value('last-modified');
        _captureServerDigest(response.headers);
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
          // F18: the writer may still hold up to 256KB per chunk in its
          // buffers from earlier attempts this session. Digesting the raw
          // file without flushing folds a zero gap into the hash and
          // persists a wrong digest (which later fails integrity checks or
          // resurrects bad data). readRange flushes all writer buffers
          // before reading, so the digest always covers what is on disk.
          final resumedBytes = await writer.readRange(chunk.start, resumeFrom);
          if (resumedBytes.isNotEmpty) {
            digestSink.add(resumedBytes);
          }
        }

        var sessionBytes = 0;
        // F24: pump the response stream through a pass-through controller so
        // the source subscription can be cancelled explicitly when the chunk
        // loop exits early (full chunk / hot-split overshoot breaks). Relying
        // on the loop's implicit break-cancel leaves the HTTP socket draining
        // in the background while the chunk loop moves on.
        final pieceController = StreamController<Uint8List>();
        final sourceSub = stream.listen(
          pieceController.add,
          onError: pieceController.addError,
          onDone: pieceController.close,
        );
        try {
          await for (final piece in pieceController.stream) {
            _throwIfCancelled();
            _throwIfPersistenceFailed();
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
              final elapsedSec = chunkSw.elapsedMilliseconds / 1000.0;
              if (elapsedSec > 0) {
                speedPredictor.addSample(sessionBytes / elapsedSec);
              }
            }

            await _throttledSaveAndReport(writer);

            if (chunk.size >= 0 && (resumeFrom + sessionBytes) >= chunk.size) {
              break;
            }
          }
        } finally {
          // F24: release the response connection deterministically. The
          // controller itself is intentionally left unclosed to avoid
          // add-after-close races with in-flight source events; it is
          // garbage-collected together with its buffered events.
          await sourceSub.cancel();
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
            // FIX(C-2): durability-clamped snapshot (other workers keep
            // mutating the live state while we flush).
            await StateStore.save(
                cmd.tempFilePath, _durableStateSnapshot(_state!, writer),
                durable: true, taskId: cmd.taskId);
            final journal = DownloadJournal(
                StateStore.journalPathFor(cmd.tempFilePath, taskId: cmd.taskId));
            await journal.open();
            try {
              // FIX(journal-init): write the init record the first time the
              // journal is opened for this file, so recovery after compaction
              // has accurate threadCount/totalSize (writeInit is a no-op when
              // the journal already has content). Also emit a periodic
              // checkpoint so recovery metadata stays accurate.
              final st = _state!;
              if (!_journalInitWritten) {
                await journal.writeInit(st.threadCount, st.totalSize);
                _journalInitWritten = true;
              } else if (st.chunks.length > 1) {
                _journalChunkWritesSinceCheckpoint++;
                if (_journalChunkWritesSinceCheckpoint >=
                    _journalCheckpointEveryChunks) {
                  _journalChunkWritesSinceCheckpoint = 0;
                  await journal.writeCheckpoint(
                    st.chunks.map((c) => c.downloaded).toList(),
                    st.totalSize,
                    hashes: {
                      for (var i = 0; i < st.chunks.length; i++)
                        if (st.chunks[i].hash != null) i: st.chunks[i].hash!,
                    },
                  );
                }
              }
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
              await StateStore.save(
                  cmd.tempFilePath, _durableStateSnapshot(_state!, writer),
                  durable: true, taskId: cmd.taskId);
            } catch (e, st) {
              _log.fine('Failed backup state save at chunk boundary', e, st);
            }
          }
        }
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        if (e.message == 'HTML_INSTEAD_OF_MEDIA') rethrow;
        if (_isAntiBotChallenge(e.response)) rethrow;
        if (e.message?.contains('Progress preserved') == true ||
            e.message?.contains('existing downloaded data preserved') == true) {
          rethrow;
        }
        if (e.message?.startsWith('Server rejected resume') == true) rethrow;

        final status = e.response?.statusCode;
        // F11: 410 Gone is how GCS/Azure expire signed URLs — treat it like
        // 401/403 so link refresh can kick in.
        if (status == 401 || status == 403 || status == 410) {
          final host = Uri.tryParse(cmd.punyUrl)?.host.toLowerCase() ?? '';
          final isLikelyExpired = _isExpiredUrlOrSite(cmd.url, host);
          if (isLikelyExpired) {
            _emitProgress(0,
                statusMessage: 'Refreshing links…',
                cycleStateOverride: CycleState.updatingLinks);
            if (_state != null) {
              _state!.cycleState = CycleState.updatingLinks.name;
              try {
                await StateStore.save(cmd.tempFilePath, _state!,
                    durable: true, taskId: cmd.taskId);
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
          final next = await _advanceChunkMirror(
            dio: dio,
            failover: failover,
            currentUrl: activeUrl,
            chunk: chunk,
          );
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
      } on StatePersistenceException {
        rethrow;
      } catch (e) {
        if (attempts >= maxAttempts) {
          final next = await _advanceChunkMirror(
            dio: dio,
            failover: failover,
            currentUrl: activeUrl,
            chunk: chunk,
          );
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
        if (response.statusCode == 200) {
          // F12: Server returned 200 (range ignored) → server does not support ranges.
          // Reset chunk progress to 0 so fresh download starts from 0 without corrupting offsets.
          await response.data?.stream.listen((_) {}).cancel();
          chunk.downloaded = 0;
          if (chunkIndex < _chunkDurabilityBaselines.length) {
            _chunkDurabilityBaselines[chunkIndex] = 0;
          }
          await writer.resetChunkHighWater(chunkIndex);
          _log.fine(
              '[DMX-Job] spot-check got 200 (range ignored) → chunk $chunkIndex reset to 0');
          return;
        }
        if (response.statusCode != 206 || response.data == null) {
          // F12: transient failures (5xx, 429, throttling, ...) must not
          // destroy real resumed progress — skip the check without wiping.
          await response.data?.stream.listen((_) {}).cancel();
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
          if (chunkIndex < _chunkDurabilityBaselines.length) {
            _chunkDurabilityBaselines[chunkIndex] = 0;
          }
          await writer.resetChunkHighWater(chunkIndex);
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
    var chunk = st.chunks.first;
    final tempFile = File(cmd.tempFilePath);
    await tempFile.parent.create(recursive: true);

    final scopedStateFile =
        File(StateStore.pathFor(cmd.tempFilePath, taskId: cmd.taskId));
    final legacyStateFile = File(StateStore.pathFor(cmd.tempFilePath));
    final hasUsableState = (await scopedStateFile.exists() ||
            await legacyStateFile.exists()) &&
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
          await StateStore.remove(cmd.tempFilePath, taskId: cmd.taskId);
        } catch (e, st) {
          _log.fine('Failed to remove state store on temp file overrun', e, st);
        }
        st.chunks = ChunkScheduler.singleStream(st.totalSize);
        chunk = st.chunks.first;
      } else if (cmd.supportsResume) {
        // F14: disk length is the source of truth on resume — never trust a
        // counter claiming more bytes than the file holds, or FileMode.append
        // will misalign server data against physical offsets.
        chunk.downloaded = st.totalSize > 0 ? len.clamp(0, st.totalSize) : len;
      } else {
        chunk.downloaded = 0;
        await tempFile.delete();
      }
    } else {
      // F14: the temp file is gone but the state may still claim progress.
      // Appending a full-range response to a fresh empty file while the
      // Range header asks for `bytes=resumeFrom-` shifts every byte by
      // resumeFrom; the final size check then either fails the job or —
      // across several restart cycles — finalizes a corrupt, length-correct
      // file. Reset to zero and clear the stale snapshot so the inflated
      // counters cannot resurrect through the stale-write guard.
      if (st.downloadedBytes > 0 || chunk.downloaded > 0) {
        debugPrint('[DMX-Job] F14: temp file missing but state claims '
            '${st.downloadedBytes} bytes — restarting from zero');
        for (final c in st.chunks) {
          c.downloaded = 0;
          c.hash = null;
        }
        try {
          await StateStore.remove(cmd.tempFilePath, taskId: cmd.taskId);
        } catch (e, st) {
          _log.fine('Failed to remove stale state for missing temp file', e, st);
        }
      }
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
        cmd.resumeIntegrityCheck &&
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
                  '[DMX-Job] BUG-2: single-stream spot-check mismatch — resetting chunk progress without deleting file');
              chunk.downloaded = 0;
              st.chunks = ChunkScheduler.singleStream(st.totalSize);
              chunk = st.chunks.first;
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
    var skipIfRangeSingleStream = false;

    // FIX(H-1): Ensure BandwidthGovernor is disposed on ALL exit paths from
    // the single-stream path. Previously disposal only happened after the
    // normal completion path (post-while-loop), leaking the governor's
    // PowerMonitor listener on every exception/exit — a leak on every pause,
    // timeout, range-reject, or other failure.
    try {
      while (!st.isComplete || st.totalSize <= 0) {
        _throwIfCancelled();
        attempts++;
        totalMirrorAttempts++;
        if (totalMirrorAttempts > maxTotalAttempts) {
          throw DownloadIntegrityException(
              'Max total mirror attempts ($maxTotalAttempts) exceeded for single-stream job');
        }
        RandomAccessFile? raf;
        var rafFaulted = false;
        try {
          final resumeFrom = chunk.downloaded;
          final headers = <String, dynamic>{};
          if (resumeFrom > 0 && cmd.supportsResume) {
            headers['Range'] = 'bytes=$resumeFrom-';
            if (!skipIfRangeSingleStream && !_urlChangedFromSavedState) {
              final ifRange =
                  strongIfRangeValidator(st.etag, st.lastModified);
              if (ifRange != null) headers['If-Range'] = ifRange;
            }
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
            final contentRange = response.headers.value('content-range');
            if (contentRange != null) {
              final match = _contentRangeTotalRegex.firstMatch(contentRange);
              if (match != null) {
                final serverTotal = int.tryParse(match.group(1) ?? '');
                if (serverTotal != null && serverTotal > 0) {
                  st.totalSize = serverTotal;
                  chunk.end = serverTotal - 1;
                }
              }
            }
            final currentDiskLen =
                await tempFile.exists() ? await tempFile.length() : 0;
            if (st.totalSize > 0 && currentDiskLen >= st.totalSize) {
              chunk.downloaded = st.totalSize;
              break;
            }
            handle416(chunk, st.totalSize);
            if (st.totalSize > 0 && chunk.downloaded >= st.totalSize) break;
            chunk.downloaded = 0;
            if (await tempFile.exists()) await tempFile.delete();
            continue;
          }

          // FIX 5: HTTP 200 resume rejection - handle server ignoring Range headers
          if (response.statusCode == 200 && resumeFrom > 0) {
            await response.data?.stream.listen((_) {}).cancel();
            if (headers.containsKey('If-Range')) {
              skipIfRangeSingleStream = true;
              st.etag = null;
              st.lastModified = null;
              invalidateIdentityCacheForUrl(cmd.punyUrl);
              await _verifyServerIdentity(dio);
              continue;
            }
            if (_urlChangedFromSavedState) {
              throw DioException(
                requestOptions: response.requestOptions,
                type: DioExceptionType.badResponse,
                response: response,
                message:
                    'Updated link does not support byte-range resume (HTTP 200); '
                    'existing downloaded data preserved.',
              );
            }
            _log.info(
                'resume_range_ignored (single-stream): resetting for ${cmd.taskId}');
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
            // F15: clear the state via StateStore.remove, which resolves the
            // SAME per-task path (pathFor → `<temp>.<taskId>.dmxstate`) the
            // saves use. The hand-built legacy paths previously left the
            // current snapshot intact, letting the stale pre-restart counters
            // resurrect through the journal's stale-write guard on the next
            // pause.
            try {
              await StateStore.remove(cmd.tempFilePath, taskId: cmd.taskId);
            } catch (e, st) {
              _log.fine(
                  'Failed to remove state store on single-stream restart',
                  e,
                  st);
            }
            if (await tempFile.exists()) {
              try {
                await tempFile.delete();
              } catch (e, st) {
                _log.fine('Failed to delete temp file on single-stream restart',
                    e, st);
              }
            }
            chunk.downloaded = 0;
            st.chunks = ChunkScheduler.singleStream(st.totalSize);
            chunk = st.chunks.first;
            // Restart from the beginning with this mirror
            continue;
          }

          if (response.statusCode != 200 && response.statusCode != 206) {
            await response.data?.stream.listen((_) {}).cancel();
            if (_isAntiBotChallenge(response)) {
              throw DioException(
                requestOptions: response.requestOptions,
                type: DioExceptionType.badResponse,
                response: response,
                message:
                    'Blocked by anti-bot challenge (Cloudflare HTTP ${response.statusCode}). '
                    'Open in browser or update link.',
              );
            }
            // FIX 4: URL expiration detection (F11: also 410 Gone)
            if (response.statusCode == 401 ||
                response.statusCode == 403 ||
                response.statusCode == 410) {
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
                        durable: true, taskId: cmd.taskId, allowRegression: true);
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
          if (_htmlContentTypeRegex.hasMatch(contentType) &&
              !_isExplicitHtmlPath(cmd.punyUrl)) {
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
          _captureServerDigest(response.headers);
          final contentLength = int.tryParse(
                  response.headers.value(Headers.contentLengthHeader) ?? '') ??
              0;
          if (contentLength > 0) {
            final actual = (isPartial ? chunk.downloaded : 0) + contentLength;
            if (st.totalSize <= 0) {
              st.totalSize = actual;
              chunk.end = actual - 1;
            } else if (actual != st.totalSize) {
              final oldIdentity = firstNonEmpty(st.etag, st.lastModified);
              final newIdentity = firstNonEmpty(
                  response.headers.value('etag'),
                  response.headers.value('last-modified'));
              if (oldIdentity != null &&
                  newIdentity != null &&
                  oldIdentity != newIdentity) {
                _log.info(
                    'Resource identity changed during single-stream transfer; restarting');
                chunk.downloaded = 0;
                if (await tempFile.exists()) await tempFile.delete();
                st.totalSize = actual;
                chunk.end = actual - 1;
              } else {
                _log.warning(
                    'Single-stream contentLength sum ($actual) != totalSize (${st.totalSize})');
              }
            }
          }

          raf = await tempFile.open(
            mode: chunk.downloaded > 0 ? FileMode.append : FileMode.write,
          );
          _singleStreamRaf = raf;
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
              _throwIfPersistenceFailed();
              final sleepMs =
                  await governor.acquire(piece.length, taskId: cmd.taskId);
              if (sleepMs > 0) {
                await _cancellableDelay(Duration(milliseconds: sleepMs));
                _throwIfCancelled();
              }
              try {
                final streamRaf = raf;
                await _streamRafLock
                    .synchronized(() => streamRaf.writeFrom(piece));
              } on FileSystemException catch (writeErr) {
                rafFaulted = true;
                // F23: the raw raf write bypasses the writer's ENOSPC
                // mapping — surface disk-full as InsufficientStorageException
                // instead of a generic FileSystemException.
                final diskFull =
                    PositionalFileWriter.mapDiskFullError(writeErr);
                if (diskFull != null) throw diskFull;
                rethrow;
              }
              chunk.downloaded += piece.length;
              _bytesSinceSave += piece.length;
              await _throttledSaveAndReport(
                null,
                preSaveFlush: () async {
                  final streamRaf = raf;
                  if (streamRaf != null) {
                    await _streamRafLock
                        .synchronized(() => streamRaf.flush());
                  }
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
            final streamRaf = raf;
            await _streamRafLock.synchronized(() async {
              await streamRaf.flush();
              await streamRaf.close();
            });
          } catch (e, st) {
            // F23: a disk-full surface here too, not just on write.
            final diskFull = PositionalFileWriter.mapDiskFullError(e);
            if (diskFull != null) throw diskFull;
            _log.fine('Failed to flush/close raf in single-stream', e, st);
          }
          raf = null;
          _singleStreamRaf = null;
          failover.reportSuccess();
          attempts = 0;
          if (st.totalSize <= 0) {
            // FIX-P0-1
            final actualDiskLen = await tempFile.length(); // FIX-P0-1
            // M-3: total size was never known (no usable Content-Length), so the
            // on-disk length is the only measure of what arrived. Only seal it as
            // a finished file when the response framing gave a real completion
            // signal (chunked terminator / graceful close); otherwise the stream
            // may have been truncated by an early socket close, so throw a
            // retryable error and let the outer loop resume rather than reporting
            // a partial file as success.
            if (!unknownLengthEofIsTrustworthy(
                response.headers, actualDiskLen)) {
              throw DioException(
                requestOptions: response.requestOptions,
                type: DioExceptionType.connectionError,
                message:
                    'Stream ended without a completion signal (possible truncation).',
              );
            }
            chunk.downloaded = actualDiskLen; // FIX-P0-1
            st.totalSize = actualDiskLen; // FIX-P0-1
            chunk.end = actualDiskLen > 0 ? actualDiskLen - 1 : 0; // FIX-P0-1
          } // FIX-P0-1
          if (chunk.isComplete ||
              (st.totalSize > 0 && chunk.downloaded >= st.totalSize)) {
            // FIX-P0-1
            await StateStore.save(cmd.tempFilePath, _state!,
                durable: true, taskId: cmd.taskId); // FIX-P0-1
          } // FIX-P0-1
          break;
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel) {
            // FIX 1: Pause - save state synchronously
            _state!.status = DmxStateStatus.paused;
            try {
              final streamRaf = raf;
              if (streamRaf != null) {
                await _streamRafLock.synchronized(() async {
                  await streamRaf.flush();
                  await streamRaf.close();
                });
              }
            } catch (flushErr, flushSt) {
              _log.fine(
                  'RAF flush on pause failed: $flushErr', flushErr, flushSt);
            }
            raf = null;
            _singleStreamRaf = null;
            // BUG-7: clamp chunk progress to actual file length on disk
            try {
              final actualLen = await File(cmd.tempFilePath).length();
              if (_state!.chunks.isNotEmpty) {
                _state!.chunks[0].downloaded = actualLen.clamp(
                  0,
                  _state!.totalSize > 0 ? _state!.totalSize : actualLen,
                );
              }
            } catch (_) {}
            await StateStore.save(cmd.tempFilePath, _state!,
                durable: true, taskId: cmd.taskId, allowRegression: true);
            _stateSavedInCatch = true;
            _emitProgress(0,
                statusMessage: 'Paused', pauseReason: effectivePauseReason);
            rethrow;
          }
          if (e.message == 'HTML_INSTEAD_OF_MEDIA' ||
              _isAntiBotChallenge(e.response) ||
              e.message?.contains('Progress preserved') == true ||
              e.message?.contains('existing downloaded data preserved') == true) {
            _state!.status = DmxStateStatus.failed;
            _emitProgress(0, statusMessage: _formatFailedMessage(e));
            rethrow;
          }

          final status = e.response?.statusCode;
          // FIX 4: URL expiration detection - precise patterns only
          // (F11: also 410 Gone, used by GCS/Azure for expired signatures)
          if (status == 401 || status == 403 || status == 410) {
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
          if (status == 401 ||
              status == 403 ||
              status == 404 ||
              status == 410) {
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
            final next = failover.advance(activeUrl);
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
        } on FileSystemException catch (e, stLog) {
          final diskFull = PositionalFileWriter.mapDiskFullError(e);
          if (diskFull != null) {
            _state!.status = DmxStateStatus.failed;
            _emitProgress(0, statusMessage: diskFull.message);
            throw diskFull;
          }
          _log.warning(
              'Single-stream FileSystemException on attempt $attempts: $e',
              e,
              stLog);
          try {
            final streamRaf = raf;
            if (streamRaf != null) {
              await _streamRafLock.synchronized(() => streamRaf.close());
            }
          } catch (_) {}
          raf = null;
          rafFaulted = true;
          if (await tempFile.exists()) {
            chunk.downloaded = await tempFile.length();
          }
          if (attempts >= maxAttempts) {
            _state!.status = DmxStateStatus.failed;
            final next = failover.advance(activeUrl);
            if (next != null) {
              activeUrl = next;
              attempts = 0;
              totalMirrorAttempts = 0;
              _state!.status = DmxStateStatus.active;
              _emitProgress(_stopwatch.elapsedMilliseconds,
                  statusMessage: 'Retrying (mirror failover)…',
                  cycleStateOverride: CycleState.retrying);
              continue;
            }
            _emitProgress(0, statusMessage: 'File system error: ${e.message}');
            rethrow;
          }
          _emitProgress(_stopwatch.elapsedMilliseconds,
              statusMessage: 'Retrying…');
          await _cancellableDelay(
              Duration(seconds: (attempts * attempts * 2) + _rng.nextInt(3)));
        } finally {
          if (!rafFaulted) {
            try {
              final streamRaf = raf;
              if (streamRaf != null) {
                await _streamRafLock.synchronized(() async {
                  await streamRaf.flush();
                  await streamRaf.close();
                });
              }
            } catch (e, st) {
              _log.fine(
                  'Failed to flush/close raf in single-stream finally', e, st);
            }
          } else {
            try {
              final streamRaf = raf;
              if (streamRaf != null) {
                await _streamRafLock.synchronized(() => streamRaf.close());
              }
            } catch (_) {}
          }
          raf = null;
          _singleStreamRaf = null;
          // FIX 15: Only save if not already saved in catch
          if (!_stateSavedInCatch) {
            try {
              await StateStore.save(cmd.tempFilePath, _state!,
                  durable: true, taskId: cmd.taskId, allowRegression: true);
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
          final raf = await tempFile.open(mode: FileMode.append);
          await raf.truncate(st.totalSize);
          await raf.close();
        } else {
          st.status = DmxStateStatus.failed;
          await StateStore.save(cmd.tempFilePath, st,
              durable: true, taskId: cmd.taskId, allowRegression: true);
          final err = DownloadIntegrityException(
              'expected ${st.totalSize} bytes, got $actualLen');
          _emitProgress(0, statusMessage: _formatFailedMessage(err));
          throw err;
        }
      }
      governor.removeTaskLimit(cmd.taskId);
      governor.unregisterConsumer();
    } finally {
      governor.dispose();
    }
  }

  bool _finalized = false;

  /// Finalizes the download: renames temp file to final, cleans up state.
  Future<void> _finalize(Dio dio) async {
    // M-2: guard against double finalize (called from both the multi-threaded
    // and single-stream completion paths).
    if (_finalized) return;
    final st = _state!;
    if (cmd.tempFilePath != cmd.localFilePath) {
      final tempExists = await File(cmd.tempFilePath).exists();
      if (!tempExists) {
        st.status = DmxStateStatus.failed;
        await StateStore.save(cmd.tempFilePath, st,
            durable: true, taskId: cmd.taskId);
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

      // Windows sharing violation resilience: retry delete/rename with backoff
      var moveSuccess = false;
      Object? lastMoveError;
      for (var attempt = 0; attempt < 5; attempt++) {
        try {
          if (await finalFile.exists()) {
            await finalFile.delete();
          }
          await File(cmd.tempFilePath).rename(cmd.localFilePath);
          moveSuccess = true;
          break;
        } catch (err) {
          lastMoveError = err;
          if (attempt < 4) {
            await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
          }
        }
      }

      if (!moveSuccess) {
        // Fallback to stream copy if rename/delete failed
        final srcFile = File(cmd.tempFilePath);
        final dstFile = File(cmd.localFilePath);
        try {
          final srcStream = srcFile.openRead();
          final dstSink = dstFile.openWrite();
          await srcStream.pipe(dstSink);

          final srcLen = await srcFile.length();
          final dstLen = await dstFile.length();
          if (srcLen == dstLen) {
            try {
              await srcFile.delete();
            } catch (_) {}
          } else {
            if (await dstFile.exists()) {
              try {
                await dstFile.delete();
              } catch (_) {}
            }
            throw DownloadIntegrityException(
                'File copy length mismatch ($srcLen != $dstLen) on rename fallback.');
          }
        } catch (copyErr) {
          if (await dstFile.exists()) {
            try {
              await dstFile.delete();
            } catch (_) {}
          }
          throw DownloadIntegrityException(
              'Finalize failed to move temp file ($lastMoveError) and copy fallback failed: $copyErr');
        }
      }
    } else {
      final localExists = await File(cmd.localFilePath).exists();
      if (!localExists) {
        st.status = DmxStateStatus.failed;
        await StateStore.save(cmd.tempFilePath, st,
            durable: true, taskId: cmd.taskId);
        final err = DownloadIntegrityException(
            'Download output file missing: ${cmd.localFilePath}');
        _emitProgress(0, statusMessage: _formatFailedMessage(err));
        throw err;
      }
    }

    // Whole-file integrity: if the origin advertised a digest (RFC 3230/9530
    // `Digest` / `Repr-Digest` / `Content-Digest`), verify the finished file
    // against it before sealing completion. Only runs (and only hashes) when a
    // digest header was actually present, so it costs nothing on the common
    // path. A mismatch fails the download so the outer retry/failover can react
    // rather than delivering a corrupt file.
    final serverDigest = _serverDigest;
    if (serverDigest != null) {
      try {
        final ok = await ChecksumService.verify(
          cmd.localFilePath,
          serverDigest.value,
          serverDigest.key,
        );
        if (!ok) {
          st.status = DmxStateStatus.failed;
          await StateStore.save(cmd.tempFilePath, st,
              durable: true, taskId: cmd.taskId);
          final err = DownloadIntegrityException(
              'Server ${serverDigest.key} digest mismatch — file failed integrity check.');
          _emitProgress(0, statusMessage: _formatFailedMessage(err));
          throw err;
        }
        _log.info('Server ${serverDigest.key} digest verified for ${cmd.taskId}');
      } on DownloadIntegrityException {
        rethrow;
      } catch (e, stLog) {
        // A hashing/IO error during verification must not silently pass a
        // possibly-corrupt file, but it also isn't proof of corruption; log and
        // continue to the size-gated completion (the orchestrator gate re-checks
        // any user-supplied checksum independently).
        _log.warning('Server digest verification errored (continuing): $e', e, stLog);
      }
    }

    st.status = DmxStateStatus.complete;
    await StateStore.save(cmd.tempFilePath, st,
        durable: true, taskId: cmd.taskId);
    // H1: write a durable completion marker beside the temp path BEFORE deleting
    // the snapshot/WAL. If the process dies after finalize but before the main
    // isolate commits `completed` to the DB, startup reconciliation can still
    // recognise the file as complete — critically for unknown-length
    // (fileSize == 0) downloads, which the size-based reconcile gate misses.
    await _writeCompletionMarker(st);
    _emitProgress(0, statusMessage: 'Completed');
    await StateStore.remove(cmd.tempFilePath, taskId: cmd.taskId);
    _finalized = true;
  }

  /// Writes `<tempFilePath>.dmxdone` containing the final byte count. Best-effort:
  /// a marker-write failure must never fail an otherwise-complete download, but
  /// it is still surfaced as telemetry rather than swallowed.
  Future<void> _writeCompletionMarker(TransferState st) async {
    try {
      final finalSize = st.totalSize > 0
          ? st.totalSize
          : await File(cmd.localFilePath).length();
      await File('${cmd.tempFilePath}.dmxdone')
          .writeAsString('$finalSize', flush: true);
    } catch (e, stackTrace) {
      StateStore.recordSaveFailure(
          '${cmd.tempFilePath}.dmxdone', e, stackTrace);
    }
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
    // If cancelled or paused, force immediate durable save
    if (_cancelRequested || _cancelToken.isCancelled) {
      final st = _state;
      if (st != null && !_stateSavedInCatch) {
        try {
          await _stateSaveLock.synchronized(() async {
            if (preSaveFlush != null) await preSaveFlush();
            if (writer != null) await writer.flushAll();
            await DownloadJournal.flushAllActive();
            await StateStore.save(
                cmd.tempFilePath, _durableStateSnapshot(st, writer),
                durable: true, taskId: cmd.taskId);
          });
        } catch (e, stackTrace) {
          StateStore.recordSaveFailure(cmd.tempFilePath, e, stackTrace);
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
        ? const Duration(seconds: 8).inMilliseconds
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

    // F21: a pending save must no longer swallow DUE PROGRESS REPORTS — it
    // only suppresses scheduling another durable save. The previous
    // early-return dropped every report for the whole save duration (up to
    // the fsync + write time), freezing the UI's progress for seconds.
    if (dueSave &&
        !_stateSavePending &&
        !(st.chunks.isEmpty && st.downloadedBytes == 0)) {
      _lastStateSaveMs = nowMs;
      _bytesSinceSave = 0;
      _stateSavePending = true;
      unawaited(_stateSaveLock.synchronized(() async {
        try {
          if (_disposed) return;
          if (preSaveFlush != null) await preSaveFlush();
          if (_disposed) return;
          // C-1: fsync buffered data to disk before persisting progress, so the
          // saved state can never claim more bytes than are durably on disk.
          // flushAll() issues a real fsync barrier (handle.flush()); flushBuffers()
          // only drains to the OS page cache and is lost on power failure.
          if (writer != null && !writer.isClosed) await writer.flushAll();
          if (_disposed) return;
          // FIX(C-2): serialize a durability-clamped clone. The live state
          // keeps mutating during the flush awaits; saving it directly could
          // record offsets beyond what was actually written to disk.
          await StateStore.save(
            cmd.tempFilePath,
            _durableStateSnapshot(st, writer),
            durable: true,
            screenOff: PowerMonitor.screenOff,
            taskId: cmd.taskId,
          );
        } catch (e, stackTrace) {
          StateStore.recordSaveFailure(cmd.tempFilePath, e, stackTrace);
        } finally {
          _stateSavePending = false;
        }
        // F26: StateStore.save() swallows write errors by design, so inspect
        // its recorded outcome. A permanent failure (EACCES/EROFS — the folder
        // is not writable) means resume progress can never be recorded; flag it
        // so the write loops abort with an actionable storage error instead of
        // silently sitting at 0% and later surfacing "File system error".
        final permanent = StateStore.hasPermanentSaveFailure(
            cmd.tempFilePath,
            taskId: cmd.taskId);
        if (permanent) {
          if (!_persistenceFailed) {
            debugPrint('[DMX-Job] F26: cannot persist resume state for '
                '${cmd.taskId} — aborting with a storage error.');
          }
          _persistenceFailed = true;
        }
      }));
    }

    if (dueReport && !PowerMonitor.screenOff) {
      _lastReportMs = nowMs;
      _emitProgress(nowMs, writer: writer);
    }
  }

  /// FIX(C-2): Returns a clone of [st] whose per-chunk counters never exceed
  /// bytes actually written to the file. `flushAll()` fsyncs, but the live
  /// TransferState keeps mutating while we await — serializing it after the
  /// flush could persist offsets that were never fsynced (silent corruption
  /// window on power loss). Each chunk's durable amount is:
  ///   baseline (previous session's durable progress)
  ///   + bytes this session whose OS write succeeded (writer high-water).
  TransferState _durableStateSnapshot(
      TransferState st, PositionalFileWriter? writer) {
    final snap = st.clone();
    if (writer == null) {
      // BUG-9: For single-stream (writer is null), clamp against physical disk length
      if (snap.threadCount <= 1 && snap.chunks.isNotEmpty) {
        try {
          final f = File(cmd.tempFilePath);
          if (f.existsSync()) {
            final len = f.lengthSync();
            snap.chunks[0].downloaded =
                len.clamp(0, snap.totalSize > 0 ? snap.totalSize : len);
          }
        } catch (_) {}
      }
      return snap;
    }
    final baselines = _chunkDurabilityBaselines;
    if (baselines.isEmpty) return snap;
    final highWater = writer.snapshotFlushedHighWater();
    for (var i = 0; i < snap.chunks.length; i++) {
      final c = snap.chunks[i];
      final baseline = i < baselines.length ? baselines[i] : 0;
      final absEnd = highWater[i] ?? (c.start + baseline);
      var durable = absEnd - c.start;
      if (durable < 0) durable = 0;
      if (durable > c.downloaded) durable = c.downloaded;
      c.downloaded = durable;
    }
    return snap;
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
    // this only applies to multi-threaded, which is correct).
    // Skipped when batching is disabled: writes flush immediately, so buffer
    // size is irrelevant.
    if (writer != null && cmd.diskWriteBatching) {
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
      // Note: chunkDetails provides per-chunk progress data equivalent to HttpPartStatus.
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
    final trimmed = value.trim();
    if (trimmed.toLowerCase() == 'bytes */0' ||
        trimmed.toLowerCase() == 'bytes */*') {
      if (expectedStart == 0 && (allowUnknown || expectedTotal == 0)) return;
      throw DioException(
        requestOptions: RequestOptions(path: url ?? ''),
        type: DioExceptionType.badResponse,
        message: 'Invalid Content-Range response for resume: $value.',
      );
    }
    final match = _contentRangeHeaderRegex.firstMatch(trimmed);
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
