import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/foundation.dart';

import '../../constants/thresholds.dart';
import '../bandwidth_governor.dart';
import '../download_engine.dart' show DownloadEngine;
import '../download_journal.dart';
import '../engines/http_download_engine.dart';
import '../mirror/mirror_selector.dart';
import '../positional_file_writer.dart';
import '../power_monitor.dart';
import 'engine_exceptions.dart';
import 'engine_models.dart';
import 'engine_utils.dart';

export 'engine_exceptions.dart' show FileChangedOnServerException, RangeUnsupportedException;
export 'engine_models.dart' show SpeedSample;

const Duration defaultTaskHardTimeout = kTaskHardTimeout;

int _workerGlobalLimitBps = 0;
int _workerGlobalActive = 1;
final Map<String, HttpTransferJob> _runningJobs = {};
// Task 3.1: Hoist Random and RegExps to avoid per-request allocations.
final Random _rng = Random();
final RegExp _contentRangeTotalRegex = RegExp(r'/(\d+)');
final RegExp _contentRangeHeaderRegex =
    RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$', caseSensitive: false);

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
        _runningJobs[raw['jobId'] as String]?.requestCancel();
        break;
      case 'limits':
        _workerGlobalLimitBps = (raw['bps'] as num?)?.toInt() ?? 0;
        _workerGlobalActive =
            ((raw['active'] as num?)?.toInt() ?? 1).clamp(1, 1000);
        break;
      case 'shutdown':
        for (final job in _runningJobs.values) {
          job.requestCancel();
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
  static const int maxPendingDelays = 32;
  final List<Completer<void>> _pendingDelayCompleters = [];
  final List<Timer> _pendingDelayTimers = [];

  @visibleForTesting
  List<Completer<void>> get pendingDelayCompletersForTesting => _pendingDelayCompleters;

  @visibleForTesting
  List<Timer> get pendingDelayTimersForTesting => _pendingDelayTimers;

  @visibleForTesting
  Future<void> cancellableDelay(Duration duration) {
    if (_cancelRequested || _cancelToken.isCancelled) return Future.value();

    while (_pendingDelayCompleters.length >= maxPendingDelays) {
      final oldCompleter = _pendingDelayCompleters.removeAt(0);
      if (!oldCompleter.isCompleted) oldCompleter.complete();
    }
    while (_pendingDelayTimers.length >= maxPendingDelays) {
      final oldTimer = _pendingDelayTimers.removeAt(0);
      oldTimer.cancel();
    }

    final completer = Completer<void>();
    _pendingDelayCompleters.add(completer);

    final timer = Timer(duration, () {
      _pendingDelayTimers.removeWhere((t) => !t.isActive);
      _pendingDelayCompleters.remove(completer);
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    _pendingDelayTimers.add(timer);

    return completer.future;
  }

  void _abortAllDelays() {
    _cancelRequested = true;
    for (final t in _pendingDelayTimers) {
      t.cancel();
    }
    _pendingDelayTimers.clear();
    for (final c in _pendingDelayCompleters) {
      if (!c.isCompleted) c.complete();
    }
    _pendingDelayCompleters.clear();
  }

  TransferState? _state;
  bool _stateSavedInCatch = false;
  int? _lastEta;
  int _lastStateSaveMs = 0;
  bool _stateSavePending = false;
  int _lastReportMs = 0;
  int _bytesSinceSave = 0;
  int _lastChunkDetailsHash = 0;
  List<Map<String, dynamic>>? _cachedChunkDetails;
  final Stopwatch _stopwatch = Stopwatch();
  final Queue<SpeedSample> _speedSamples = Queue();

  /// Watchdog bookkeeping for dynamic hard-timeout and stall detection.
  int _watchdogCheckpointBytes = 0;
  int _lastProgressBytes = 0;
  int _lastProgressTimeMs = 0;
  bool _stalledEmitted = false;
  int? _lastProgressFingerprint;
  String? _lastEmittedCycleState;
  int _currentWriterBufferSize = 256 * 1024;
  
  void requestCancel() {
    _abortAllDelays();
    if (!_cancelToken.isCancelled) _cancelToken.cancel('paused');
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

  void sendUnhandledError(Object e) {
    if (e is DioException && e.type == DioExceptionType.cancel) {
      _send('error', {
        'errorType': 'cancel',
        'errorMessage': e.message ?? 'cancelled',
      });
      return;
    }
    if (e is DownloadIntegrityException) {
      _send('error', {'errorType': 'integrity', 'errorMessage': e.message});
      return;
    }
    if (e is InsufficientStorageException ||
        (e is PositionalFileWriterException && _looksLikeDiskFull(e.message))) {
      _send('error', {'errorType': 'diskFull', 'errorMessage': e.toString()});
      return;
    }
    if (e is FileChangedOnServerException) {
      _send('error', {
        'errorType': 'fileChanged',
        'errorMessage': 'File changed on server. Restart required.',
      });
      return;
    }
    if (e is UrlExpiredException) {
      _send('error', {
        'errorType': 'urlExpired',
        'errorMessage': e.message,
        'refreshAllMirrors': true,
      });
      return;
    }
    if (e is DioException) {
      _send('error', {
        'errorType': switch (e.type) {
          DioExceptionType.cancel => 'cancel',
          DioExceptionType.badResponse => 'badResponse',
          DioExceptionType.connectionTimeout => 'connectionTimeout',
          DioExceptionType.receiveTimeout => 'receiveTimeout',
          DioExceptionType.sendTimeout => 'sendTimeout',
          DioExceptionType.connectionError => 'connectionError',
          _ => 'uncaught',
        },
        'errorMessage': e.message ?? e.toString(),
        'errorStatus': e.response?.statusCode,
      });
      return;
    }
    _send('error', {'errorType': 'uncaught', 'errorMessage': e.toString()});
  }

  static bool _looksLikeDiskFull(String msg) {
    final m = msg.toLowerCase();
    return m.contains('enospc') || m.contains('no space left');
  }

  Timer? _hardTimeoutTimer;
  Timer? _progressWatchdogTimer;
  Timer? _stallWatchdogTimer;

  @visibleForTesting
  void registerWatchdogs() {
    final hardTimeoutDuration = _computeHardTimeout();
    void onHardTimeout() {
      requestCancel();
      _send('error', {
        'errorType': 'timeout',
        'errorMessage': 'Hard timeout exceeded: ${_formatDuration(hardTimeoutDuration)}',
      });
    }

    _hardTimeoutTimer = Timer(hardTimeoutDuration, onHardTimeout);

    _progressWatchdogTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      final st = _state;
      if (st == null) return;
      final nowBytes = st.downloadedBytes;
      final delta = nowBytes - _watchdogCheckpointBytes;
      _watchdogCheckpointBytes = nowBytes;
      if (delta > 60 * 1024 * 1024) {
        _hardTimeoutTimer?.cancel();
        _hardTimeoutTimer = Timer(hardTimeoutDuration, onHardTimeout);
      }
    });

    _stallWatchdogTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (_state == null || _stalledEmitted || _lastProgressTimeMs == 0) return;
      final elapsed = _stopwatch.elapsedMilliseconds - _lastProgressTimeMs;
      if (elapsed >= 5 * 60 * 1000) {
        _stalledEmitted = true;
        _emitProgress(_stopwatch.elapsedMilliseconds, statusMessage: 'Stalled');
      }
    });
  }

  @visibleForTesting
  void cancelWatchdogs() {
    _hardTimeoutTimer?.cancel();
    _hardTimeoutTimer = null;
    _progressWatchdogTimer?.cancel();
    _progressWatchdogTimer = null;
    _stallWatchdogTimer?.cancel();
    _stallWatchdogTimer = null;
  }

  @visibleForTesting
  Future<TransferState> loadAndReconcileState(Dio dio) async {
    final load = await StateStore.loadOrCreate(
      cmd.tempFilePath,
      url: cmd.url,
      threadCount: cmd.threadCount,
      knownFileSize: cmd.knownFileSize,
    );
    _state = load.state;
    _watchdogCheckpointBytes = _state!.downloadedBytes;
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
              ? (oc.end >= 0 ? oc.end + 1 : oc.start + oc.size)
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
        '[FIX-4/H-R1] Redistributed $savedBytes bytes from '
        '${load.state.chunks.length} → ${cmd.threadCount} chunks with range-overlap mapping',
      );
    }
    if (_state!.totalSize <= 0 && cmd.knownFileSize > 0) {
      _state!.totalSize = cmd.knownFileSize;
    }
    _state!.status = DmxStateStatus.active;
    await StateStore.save(cmd.tempFilePath, _state!);

    // Task 3.2: Skip the identity probe round-trip when backgrounded.
    // The LRU cache ensures we still validate on the first foreground resume.
    if (_state!.downloadedBytes > 0 && cmd.supportsResume && !DownloadEngine.isInBackground) {
      await _verifyServerIdentity(dio);
    }
    return _state!;
  }

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
      _send('done');
    } finally {
      cancelWatchdogs();
      if (!_stateSavedInCatch && _state != null) {
        try {
          await StateStore.save(cmd.tempFilePath, _state!);
        } catch (_) {} // coverage:ignore-line
      }
      dio.close(force: true);
    }
  }

  /// Hard timeout scales with file size: 100 KB/s baseline, min 30 min, max 24h.
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

  static final TimestampedLruMap<String, bool> _serverIdentityCache =
      TimestampedLruMap<String, bool>(maxCapacity: 25);
  static int probeSkipCount = 0;
  static int probeRunCount = 0;

  static void invalidateIdentityCacheForUrl(String url) {
    for (final key in List<String>.from(_serverIdentityCache.keys)) {
      if (key.startsWith('$url|')) {
        _serverIdentityCache.remove(key);
      }
    }
  }

  static void clearIdentityCache() {
    for (final key in List<String>.from(_serverIdentityCache.keys)) {
      _serverIdentityCache.remove(key);
    }
  }

  Future<void> _verifyServerIdentity(Dio dio) async {
    final cacheKey =
        '${cmd.punyUrl}|${_state!.etag}|${_state!.lastModified}|${_state!.totalSize}';
    _serverIdentityCache.removeStale(const Duration(minutes: 10));
    if (_serverIdentityCache.containsKey(cacheKey)) {
      probeSkipCount++;
      debugPrint(
        '[DMX-Job] _verifyServerIdentity cache hit (skips: $probeSkipCount, runs: $probeRunCount)',
      );
      return;
    }
    probeRunCount++;

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
      if (response.statusCode == 206 || response.statusCode == 200) {
        final contentRange = response.headers.value('content-range');
        int? serverTotal;
        if (contentRange != null) {
          serverTotal = int.tryParse(
              _contentRangeTotalRegex.firstMatch(contentRange)?.group(1) ?? '');
        }
        serverTotal ??= int.tryParse(
            response.headers.value(Headers.contentLengthHeader) ?? '');
        final newEtag = response.headers.value('etag');
        final newLm = response.headers.value('last-modified');
        await response.data?.stream.listen((_) {}).cancel();
        if (serverTotal != null && serverTotal > 0 && _state!.totalSize > 0) {
          final tolerance =
              (_state!.totalSize * 0.001).clamp(2048.0, 10 * 1024 * 1024);
          if ((serverTotal - _state!.totalSize).abs() > tolerance) {
            for (var i = 0; i < _state!.chunks.length; i++) {
              _state!.chunks[i] = ChunkState(
                  start: _state!.chunks[i].start, end: _state!.chunks[i].end);
            }
            try {
              final f = File(cmd.tempFilePath);
              if (await f.exists()) await f.delete();
            } catch (_) {} // coverage:ignore-line
            await StateStore.save(cmd.tempFilePath, _state!);
            throw FileChangedOnServerException();
          }
        }
        final oldIdentity = firstNonEmpty(_state!.etag, _state!.lastModified);
        final newIdentity = firstNonEmpty(newEtag, newLm);
        if (oldIdentity != null &&
            newIdentity != null &&
            oldIdentity != newIdentity) {
          debugPrint('[DMX-Job] resource identity changed — restarting');
          for (final c in _state!.chunks) {
            c.downloaded = 0;
          }
          try {
            final f = File(cmd.tempFilePath);
            if (await f.exists()) await f.delete();
          } catch (_) {} // coverage:ignore-line
          _state!.etag = newEtag;
          _state!.lastModified = newLm;
          _state!.migrationNote =
              '${_state!.migrationNote ?? ''} identity_restart'.trim();
          await StateStore.save(cmd.tempFilePath, _state!);
          _emitProgress(0,
              statusMessage: 'Source changed on server — restarting');
        } else {
          _state!.etag ??= newEtag;
          _state!.lastModified ??= newLm;
        }
        _serverIdentityCache.put(cacheKey, true);
      }
    } on FileChangedOnServerException {
      _serverIdentityCache.remove(cacheKey);
      rethrow;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final host = Uri.tryParse(cmd.punyUrl)?.host.toLowerCase() ?? '';
      final isYtOrSigned = host.endsWith('.googlevideo.com') ||
          host.contains('youtube.com') ||
          host.contains('youtu.be') ||
          cmd.url.contains('expire=') ||
          cmd.url.contains('signature=');
      if (isYtOrSigned && (status == 401 || status == 403)) {
        _serverIdentityCache.remove(cacheKey);
        _emitProgress(0, statusMessage: 'Updating links (URL expired)…');
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
    for (final c in st.chunks) {
      c.downloaded = 0;
    }
    st.chunks = ChunkScheduler.singleStream(st.totalSize);
    st.threadCount = 1;
    try {
      final f = File(cmd.tempFilePath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {} // coverage:ignore-line

    try {
      StateStore.remove(cmd.tempFilePath);
    } catch (_) {} // coverage:ignore-line
    try {
      final journal = File('${cmd.tempFilePath}.journal');
      if (journal.existsSync()) journal.deleteSync();
    } catch (_) {} // coverage:ignore-line
  }

  Future<void> _runMultiThreaded(Dio dio) async {
    final st = _state!;
    if (st.chunks.isEmpty) {
      st.chunks = ChunkScheduler.plan(
          totalSize: st.totalSize, threadCount: cmd.threadCount);
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
    final work = <(int, ChunkState)>[
      for (var i = 0; i < st.chunks.length; i++)
        if (!st.chunks[i].isComplete) (i, st.chunks[i]),
    ];
    try {
      final results = await Future.wait<ChunkResult>(
        work.map((entry) async {
          final (chunkIndex, chunk) = entry;
          var attempts = 0;
          const maxAttempts = 3;
          Object? lastError;
          StackTrace? lastSt;

          while (attempts < maxAttempts) {
            attempts++;
            try {
              await _runChunk(
                dio: dio,
                chunk: chunk,
                chunkIndex: chunkIndex,
                writer: writer,
                governor: governor,
                failover: failover,
              );
              return ChunkResult(
                chunk: chunk,
                success: true,
                attempts: attempts,
              );
            } catch (e, st) {
              lastError = e;
              lastSt = st;
              if (e is DioException && e.type == DioExceptionType.cancel) {
                return ChunkResult(
                  chunk: chunk,
                  success: false,
                  error: e,
                  stackTrace: st,
                  attempts: attempts,
                );
              }
              if (e is RangeUnsupportedException ||
                  e is PositionalFileWriterException) {
                return ChunkResult(
                  chunk: chunk,
                  success: false,
                  error: e,
                  stackTrace: st,
                  attempts: attempts,
                );
              }
              if (attempts < maxAttempts) {
                await _cancellableDelay(
                  Duration(milliseconds: 200 * (1 << attempts)),
                );
              }
            }
          }
          return ChunkResult(
            chunk: chunk,
            success: false,
            error: lastError,
            stackTrace: lastSt,
            attempts: attempts,
          );
        }),
        eagerError: false,
      );

      final failed = results.where((r) => !r.success).toList();
      if (failed.isNotEmpty) {
        final firstError = failed.first.error ??
            const DownloadIntegrityException(
                'Chunk download failed permanently');
        throw firstError;
      }

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
        _emitProgress(0, statusMessage: 'Paused');
      } else if (e is! RangeUnsupportedException) {
        final anyProven = st.chunks.any((c) => c.downloaded > 0);
        st.status = DmxStateStatus.failed;
        st.migrationNote =
            '${st.migrationNote ?? ''} ${anyProven ? 'resumable' : 'restartRequired'}'
                .trim();
        _emitProgress(0, statusMessage: 'Failed');
      }
      try {
        await writer.flushAll();
        _stateSavedInCatch = true;
        await StateStore.save(cmd.tempFilePath, st, durable: true);
      } catch (_) {} // coverage:ignore-line
      rethrow;
    } finally {
      governor.removeTaskLimit(cmd.taskId);
      governor.unregisterConsumer();
      governor.dispose();
      await writer.close();
    }
  }

  Future<void> _runChunk({
    required Dio dio,
    required ChunkState chunk,
    required int chunkIndex,
    required PositionalFileWriter writer,
    required BandwidthGovernor governor,
    required MirrorFailover failover,
  }) async {
    var attempts = 0;
    var totalMirrorAttempts = 0;
    const maxAttempts = 3;
    final maxTotalAttempts = (failover.hasAlternatives ? failover.remainingAlternatives + 1 : 1) * maxAttempts;
    
    var activeUrl = failover.activeUrl;
    while (!chunk.isComplete) {
      _throwIfCancelled();
      attempts++;
      totalMirrorAttempts++;

      if (totalMirrorAttempts > maxTotalAttempts) {
        throw DownloadIntegrityException('Max total mirror attempts ($maxTotalAttempts) exceeded for chunk $chunkIndex');
      }

      try {
        final resumeFrom = chunk.downloaded;
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
              await StateStore.remove(cmd.tempFilePath);
            } catch (_) {} // coverage:ignore-line
            throw DioException(
              requestOptions: response.requestOptions,
              type: DioExceptionType.badResponse,
              response: response,
              message: 'Server rejected resume: expected HTTP 206. Got 200.',
            );
          }
          throw RangeUnsupportedException();
        }
        if (response.statusCode == 416) {
          await response.data?.stream.listen((_) {}).cancel();
          if (chunk.downloaded >= chunk.size) {
            chunk.downloaded = chunk.size;
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
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            response: response,
            message: 'Server returned ${response.statusCode} instead of 206.',
          );
        }
        final contentType =
            response.headers.value('content-type')?.toLowerCase() ?? '';
        if (contentType.contains('text/html') ||
            contentType.contains('application/xhtml')) {
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            response: response,
            message: 'HTML_INSTEAD_OF_MEDIA',
          );
        }
        validateContentRange(
          response.headers.value('content-range'),
          expectedStart: absStart,
          expectedEnd: chunk.end,
          expectedTotal: _state!.totalSize,
          allowUnknown: chunk.downloaded == 0 && absStart == 0,
          url: cmd.punyUrl,
        );
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
          if (remainingInChunk <= 0) break;
          final toWrite = remainingInChunk < piece.length
              ? Uint8List.sublistView(piece, 0, remainingInChunk)
              : piece;
          await writer.write(chunkIndex, pos, toWrite);
          sessionBytes += toWrite.length;
          chunk.downloaded = resumeFrom + sessionBytes;
          _bytesSinceSave += toWrite.length;
          await _throttledSaveAndReport(writer);
          if (chunk.size >= 0 && (resumeFrom + sessionBytes) >= chunk.size) {
            break;
          }
        }
        failover.reportSuccess();
        attempts = 0;
        if (chunk.isComplete) {
          try {
            await writer.flushAll();
            await StateStore.save(cmd.tempFilePath, _state!);
          } catch (e) {
            debugPrint('[DMX] H-2: chunk-boundary save failed: $e');
            try {
              await StateStore.save(cmd.tempFilePath, _state!);
            } catch (_) {} // coverage:ignore-line
          }
        }
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        if (e.message == 'HTML_INSTEAD_OF_MEDIA') rethrow;
        if (e.message?.startsWith('Server rejected resume') == true) rethrow;
        final status = e.response?.statusCode;
        if (status == 401 || status == 403) {
          final bodyText = (e.response?.data?.toString() ?? '').toLowerCase();
          final host = Uri.tryParse(cmd.punyUrl)?.host.toLowerCase() ?? '';
          final isLikelyExpired = host.endsWith('.googlevideo.com') ||
              host.contains('youtube.com') ||
              host.contains('youtu.be') ||
              bodyText.contains('expired') ||
              bodyText.contains('token') ||
              bodyText.contains('signature') ||
              bodyText.contains('forbidden') ||
              cmd.url.contains('expire=') ||
              cmd.url.contains('signature=');
          if (isLikelyExpired) {
            _emitProgress(0, statusMessage: 'Updating links (URL expired)…');
            throw UrlExpiredException(
              'Download URL expired (HTTP $status). Refresh required.',
              refreshAllMirrors: true,
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
            debugPrint('[DMX-Job] failing over to mirror: $next');
            _emitProgress(_stopwatch.elapsedMilliseconds,
                statusMessage: 'Retrying (mirror failover)…');
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
      } catch (e) {
        if (attempts >= maxAttempts) rethrow;
        await _cancellableDelay(Duration(seconds: attempts * 2));
      }
    }
  }

  @visibleForTesting
  Future<void> spotCheckResumedBytes(
      Dio dio, TransferState st, PositionalFileWriter writer) async {
    const sampleSize = 64 * 1024;
    for (final chunk in st.chunks) {
      if (chunk.downloaded <= 0 || chunk.isComplete) continue;
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
          continue;
        }
        final builder = BytesBuilder(copy: false);
        await for (final b in response.data!.stream) {
          builder.add(b);
        }
        final netBytes = builder.takeBytes();
        if (netBytes.length != diskBytes.length ||
            !listEquals(netBytes, diskBytes)) {
          chunk.downloaded = 0;
          debugPrint('[DMX-Job] spot-check mismatch → chunk reset');
        }
      } catch (_) {} // coverage:ignore-line
    }
  }

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
            '[DMX-Job] FIX-1: temp file full but state unusable — restarting single-stream');
        chunk.downloaded = 0;
        await tempFile.delete();
        try {
          await StateStore.remove(cmd.tempFilePath);
        } catch (_) {} // coverage:ignore-line
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
          if (response.statusCode == 206 && response.data == null) {
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
              } catch (_) {} // coverage:ignore-line
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
    const maxAttempts = 3;
    final maxTotalAttempts = (failover.hasAlternatives ? failover.remainingAlternatives + 1 : 1) * maxAttempts;

    var activeUrl = failover.activeUrl;
    while (!st.isComplete || st.totalSize <= 0) {
      _throwIfCancelled();
      attempts++;
      totalMirrorAttempts++;

      if (totalMirrorAttempts > maxTotalAttempts) {
        throw DownloadIntegrityException('Max total mirror attempts ($maxTotalAttempts) exceeded for single-stream job');
      }

      IOSink? sink;
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
          if (st.totalSize > 0 && chunk.downloaded >= st.totalSize) break;
          chunk.downloaded = 0;
          if (await tempFile.exists()) await tempFile.delete();
          continue;
        }
        if (response.statusCode == 200 && resumeFrom > 0) {
          await response.data?.stream.listen((_) {}).cancel();
          for (final p in [
            '${cmd.tempFilePath}.dmxstate',
            '${cmd.tempFilePath}.dmxstate.tmp',
          ]) {
            try {
              final f = File(p);
              if (await f.exists()) await f.delete();
            } catch (_) {} // coverage:ignore-line
          }
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            response: response,
            message: 'Server rejected resume: expected HTTP 206. Got 200.',
          );
        }
        if (response.statusCode != 200 && response.statusCode != 206) {
          await response.data?.stream.listen((_) {}).cancel();
          throw DioException(
            requestOptions: response.requestOptions,
            type: DioExceptionType.badResponse,
            response: response,
            message: 'Server returned status code ${response.statusCode}',
          );
        }
        final contentType =
            response.headers.value('content-type')?.toLowerCase() ?? '';
        if (contentType.contains('text/html') ||
            contentType.contains('application/xhtml')) {
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
            validateContentRange(
              contentRange,
              expectedStart: chunk.downloaded,
              expectedEnd: st.totalSize > 0 ? st.totalSize - 1 : -1,
              expectedTotal: st.totalSize,
              allowUnknown: chunk.downloaded == 0,
              url: cmd.punyUrl,
            );
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
        sink = tempFile.openWrite(
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
            sink.add(piece);
            chunk.downloaded += piece.length;
            _bytesSinceSave += piece.length;
            await _throttledSaveAndReport(
              null,
              preSaveFlush: () async {
                await sink?.flush();
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
          await sink.flush();
          await sink.close();
        } catch (_) {}
        sink = null;
        failover.reportSuccess();
        attempts = 0;
        if (st.totalSize <= 0) {
          st.totalSize = chunk.downloaded;
          chunk.end = chunk.downloaded - 1;
        }
        break;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          _state!.status = DmxStateStatus.paused;
          _emitProgress(0, statusMessage: 'Paused');
          rethrow;
        }
        if (e.message == 'HTML_INSTEAD_OF_MEDIA') {
          _state!.status = DmxStateStatus.failed;
          _emitProgress(0, statusMessage: 'Failed');
          rethrow;
        }
        if (e.message?.startsWith('Server rejected resume') == true) {
          _state!.status = DmxStateStatus.failed;
          _emitProgress(0, statusMessage: 'Failed');
          rethrow;
        }
        final status = e.response?.statusCode;

        if (status == 401 || status == 403 || status == 404 || status == 410) {
          _state!.status = DmxStateStatus.failed;
          _emitProgress(0, statusMessage: 'Failed');
          rethrow;
        }

        if (status != null &&
            status >= 400 &&
            status < 500 &&
            status != 408 &&
            status != 429) {
          _state!.status = DmxStateStatus.failed;
          _emitProgress(0, statusMessage: 'Failed');
          rethrow;
        }
        if (attempts >= maxAttempts) {
          _state!.status = DmxStateStatus.failed;
          final next = failover.advance();
          if (next != null) {
            activeUrl = next;
            attempts = 0;
            _state!.status = DmxStateStatus.active;
            _emitProgress(_stopwatch.elapsedMilliseconds,
                statusMessage: 'Retrying (mirror failover)…');
            continue;
          }
          _emitProgress(0, statusMessage: 'Failed');
          rethrow;
        }
        _emitProgress(_stopwatch.elapsedMilliseconds,
            statusMessage: 'Retrying…');
        await _cancellableDelay(
            Duration(seconds: (attempts * attempts * 2) + _rng.nextInt(3)));
      } finally {
        try {
          await sink?.flush();
          await sink?.close();
        } catch (_) {} // coverage:ignore-line
        try {
          await StateStore.save(cmd.tempFilePath, _state!, durable: true);
        } catch (_) {} // coverage:ignore-line
      }
    }

    final actualLen = await tempFile.length();
    if (st.totalSize > 0 && actualLen != st.totalSize) {
      if (actualLen > st.totalSize) {
        final raf = await tempFile.open(mode: FileMode.writeOnly);
        await raf.truncate(st.totalSize);
        await raf.close();
      } else {
        st.status = DmxStateStatus.failed;
        await StateStore.save(cmd.tempFilePath, st, durable: true);
        _emitProgress(0, statusMessage: 'Failed');
        throw DownloadIntegrityException(
            'expected ${st.totalSize} bytes, got $actualLen');
      }
    }
    governor.removeTaskLimit(cmd.taskId);
    governor.unregisterConsumer();
    governor.dispose();
  }

  Future<void> _finalize(Dio dio) async {
    final st = _state!;
    if (cmd.tempFilePath != cmd.localFilePath) {
      final tempExists = await File(cmd.tempFilePath).exists();
      if (!tempExists) {
        st.status = DmxStateStatus.failed;
        await StateStore.save(cmd.tempFilePath, st, durable: true);
        _emitProgress(0, statusMessage: 'Failed');
        throw DownloadIntegrityException(
            'Temporary download file missing: ${cmd.tempFilePath}');
      }
      final finalFile = File(cmd.localFilePath);
      await finalFile.parent.create(recursive: true);
      if (await finalFile.exists()) await finalFile.delete();
      try {
        await File(cmd.tempFilePath).rename(cmd.localFilePath);
      } catch (e) {
        await File(cmd.tempFilePath).copy(cmd.localFilePath);
        final copiedLen = await File(cmd.localFilePath).length();
        final origLen = await File(cmd.tempFilePath).length();
        if (copiedLen == origLen) {
          await File(cmd.tempFilePath).delete();
        } else {
          throw const DownloadIntegrityException(
              'File copy verification failed on rename fallback.');
        }
      }
    } else {
      final localExists = await File(cmd.localFilePath).exists();
      if (!localExists) {
        st.status = DmxStateStatus.failed;
        await StateStore.save(cmd.tempFilePath, st, durable: true);
        _emitProgress(0, statusMessage: 'Failed');
        throw DownloadIntegrityException(
            'Download output file missing: ${cmd.localFilePath}');
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

  Future<void> _cancellableDelay(Duration duration) async {
    if (_cancelRequested || _cancelToken.isCancelled) return;
    final completer = Completer<void>();
    _pendingDelayCompleters.add(completer);
    final timer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete();
    });
    _pendingDelayTimers.add(timer);
    try {
      await completer.future;
    } finally {
      timer.cancel();
      _pendingDelayTimers.remove(timer);
      _pendingDelayCompleters.remove(completer);
    }
  }

  Future<void> _throttledSaveAndReport(
    PositionalFileWriter? writer, {
    Future<void> Function()? preSaveFlush,
  }) async {
    final nowMs = _stopwatch.elapsedMilliseconds;
    final st = _state!;

    final isBackground =
        DownloadEngine.isInBackground || PowerMonitor.screenOff;
    final saveInterval = isBackground
        ? const Duration(seconds: 120).inMilliseconds
        : const Duration(seconds: 15).inMilliseconds;
    final saveByteThreshold = isBackground
        ? 128 * 1024 * 1024
        : 32 * 1024 * 1024;

    final dueSave = nowMs - _lastStateSaveMs >= saveInterval ||
        _bytesSinceSave >= saveByteThreshold;

    final reportInterval = isBackground ? 15000 : 750;
    final dueReport = nowMs - _lastReportMs >= reportInterval;

    if (dueSave && !_stateSavePending) {
      _stateSavePending = true;
      _lastStateSaveMs = nowMs;
      _bytesSinceSave = 0;
      scheduleMicrotask(() async {
        try {
          if (preSaveFlush != null) await preSaveFlush();
          if (writer != null) await writer.flushBuffers();
          await StateStore.save(cmd.tempFilePath, st,
              screenOff: PowerMonitor.screenOff);
        } catch (e) {
          debugPrint('[DMX-Job] state save failed: $e');
        } finally {
          _stateSavePending = false;
        }
      });
    }

    if (dueReport && !PowerMonitor.screenOff) {
      _lastReportMs = nowMs;
      _emitProgress(nowMs, writer: writer);
    }
  }

  List<Map<String, dynamic>>? _getChunkDetails(TransferState st) {
    if (st.chunks.isEmpty) return null;
    final chunkHash =
        st.chunks.fold<int>(0, (h, c) => h ^ c.downloaded.hashCode);
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

  void _emitProgress(int nowMs,
      {String? statusMessage, PositionalFileWriter? writer}) {
    final st = _state!;
    final downloaded = st.downloadedBytes;
    final total = st.totalSize;
    if (downloaded != _lastProgressBytes) {
      _lastProgressBytes = downloaded;
      _lastProgressTimeMs = _stopwatch.elapsedMilliseconds;
      _stalledEmitted = false;
    }
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
    if (writer != null) {
      if (_currentWriterBufferSize == 256 * 1024 && speed > 60 * 1024 * 1024) {
        _currentWriterBufferSize = 512 * 1024;
        writer.setBufferSize(512 * 1024);
      } else if (_currentWriterBufferSize == 512 * 1024 && speed < 30 * 1024 * 1024) {
        _currentWriterBufferSize = 256 * 1024;
        writer.setBufferSize(256 * 1024);
      }
    }
    int? eta;
    final remaining = total - downloaded;
    if (speed.isFinite && speed > 0 && remaining > 0) {
      final raw = (remaining / speed).round().clamp(0, 86400 * 365);
      eta = _lastEta == null ? raw : ((_lastEta! * 0.7) + (raw * 0.3)).round();
      _lastEta = eta;
    } else {
      _lastEta = null;
    }
    final chunkDetails = _getChunkDetails(st);
    final totalChunks = st.chunks.isNotEmpty ? st.chunks.length : null;
    final completedChunks = st.chunks.isNotEmpty
        ? st.chunks.where((c) => c.isComplete).length
        : null;
    final cycleState = _deriveCycleState(statusMessage, st.status);
    final isCycleStateChanged = cycleState != _lastEmittedCycleState;

    final fingerprint = Object.hash(
      downloaded,
      total,
      (speed / 1024).round(),
      eta,
      cycleState,
      statusMessage,
      chunkDetails?.length,
      completedChunks,
    );

    if (!isCycleStateChanged && fingerprint == _lastProgressFingerprint) {
      return;
    }
    _lastProgressFingerprint = fingerprint;
    _lastEmittedCycleState = cycleState;

    final ytLiveCounterpartBytes = cmd.ytCounterpartDownloadedBytes;
    _send('progress', {
      'downloadedBytes': downloaded,
      'fileSize': total,
      'speed': speed,
      'eta': eta,
      'chunks': st.chunks.isNotEmpty ? st.chunkRatios : null,
      'chunkDetails': chunkDetails,
      'fileName': cmd.resolvedFileName,
      'supportsResume': cmd.supportsResume,
      if (cmd.ytStreamKind != null) 'ytStreamKind': cmd.ytStreamKind!.name,
      if (cmd.ytCounterpartSize != null)
        'ytCounterpartSize': cmd.ytCounterpartSize,
      if (ytLiveCounterpartBytes != null)
        'ytCounterpartDownloadedBytes': ytLiveCounterpartBytes,
      'ytDownloadedBytes': downloaded,
      'statusMessage': statusMessage,
      'cycleState': cycleState,
      if (totalChunks != null) 'totalChunks': totalChunks,
      if (completedChunks != null) 'completedChunks': completedChunks,
    });
  }

  static String _deriveCycleState(
      String? statusMessage, DmxStateStatus status) {
    switch (status) {
      case DmxStateStatus.complete:
        return 'completed';
      case DmxStateStatus.failed:
        return 'failed';
      case DmxStateStatus.paused:
        return 'paused';
      case DmxStateStatus.active:
        final msg = statusMessage?.toLowerCase() ?? '';
        if (msg.contains('stalled')) return 'stalled';
        if (msg.contains('updating links')) return 'updating_links';
        if (msg.contains('retrying')) return 'retrying';
        if (msg.contains('restarting') || msg.contains('source changed')) {
          return 'retrying';
        }
        if (msg.contains('checking') || msg.contains('verifying')) {
          return 'checking';
        }
        if (msg.contains('seeding')) return 'seeding';
        if (msg.contains('completed')) return 'completed';
        if (msg.contains('starting') ||
            msg.contains('allocating') ||
            msg.contains('preparing')) {
          return 'starting';
        }
        if (msg.contains('resuming')) return 'resuming';
        if (msg.contains('fetching metadata')) return 'fetching_metadata';
        return 'downloading';
    }
  }

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
}
