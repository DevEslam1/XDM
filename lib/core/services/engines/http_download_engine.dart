import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';

import '../bandwidth_governor.dart';
import '../checksum_service.dart';
import '../download_journal.dart';
import '../positional_file_writer.dart';

class HttpDownloadEngine {
  final Logger _log = Logger('HttpDownloadEngine');

  // Adaptive thread monitor
  Timer? _adaptiveThreadTimer;
  int _currentThreads = 0;
  double _emaSpeed = 0.0;
  final List<double> _throughputHistory = [];

  void startAdaptiveThreadMonitor(DownloadTask task) {
    _currentThreads = task.threadCount;
    _emaSpeed = 0.0;
    _throughputHistory.clear();
    _adaptiveThreadTimer?.cancel();
    _adaptiveThreadTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _evaluateThreadAdjustment(task),
    );
  }

  void startAdaptiveMonitorIfEnabled(DownloadTask task, bool enabled) {
    if (enabled) {
      startAdaptiveThreadMonitor(task);
    }
  }

  void stopAdaptiveThreadMonitor() {
    _adaptiveThreadTimer?.cancel();
    _adaptiveThreadTimer = null;
    _throughputHistory.clear();
  }

  void _evaluateThreadAdjustment(DownloadTask task) {
    final currentSpeed = task.speed.toDouble();
    if (_emaSpeed == 0.0) {
      _emaSpeed = currentSpeed;
    } else {
      _emaSpeed = 0.3 * currentSpeed + 0.7 * _emaSpeed;
    }
    _throughputHistory.add(currentSpeed);
    if (_throughputHistory.length > 8) _throughputHistory.removeAt(0);
    if (_throughputHistory.length < 4) return;

    final recentAvg = _emaSpeed;
    final olderAvg = _throughputHistory.first;
    final trend = olderAvg > 0 ? (recentAvg - olderAvg) / olderAvg : 0.0;

    // 15% hysteresis barrier to prevent oscillation
    if (trend < -0.15 && _currentThreads > 2) {
      _currentThreads--;
      _log.info(
        '[AdaptiveThreads] Reducing threads to $_currentThreads '
        '(EMA trend: ${(trend * 100).toStringAsFixed(1)}%)',
      );
    } else if (trend > 0.15 &&
        _currentThreads < task.threadCount &&
        _currentThreads < 16) {
      _currentThreads++;
      _log.info(
        '[AdaptiveThreads] Increasing threads to $_currentThreads '
        '(EMA trend: ${(trend * 100).toStringAsFixed(1)}%)',
      );
    }
  }

  // ============================================================
  // FIXED: verifyAndRepair — streaming SHA-256 + single Dio + finally close
  // ============================================================

  Future<bool> verifyAndRepair({
    required DownloadTask task,
    required PositionalFileWriter writer,
    required String expectedSha256,
    required CancelToken cancelToken,
  }) async {
    final file = File(task.localFilePath);
    if (!await file.exists()) return false;

    // FIX(BUG-2): Streaming SHA-256 — constant memory usage regardless of file size
    // Previously used file.readAsBytes() which caused OOM on multi-GB files
    final actualHash =
        (await ChecksumService.sha256File(task.localFilePath)).toLowerCase();

    if (actualHash == expectedSha256.toLowerCase()) {
      _log.info('[Verify] SHA-256 matched successfully: $actualHash');
      return true;
    }

    _log.warning(
      '[Verify] SHA-256 mismatch ($actualHash vs $expectedSha256). '
      'Attempting chunk repair...',
    );

    final chunkSize = (task.fileSize / task.threadCount).ceil();
    final corruptedChunks = <int>[];

    // FIX(BUG-3): Single Dio instance created OUTSIDE the loop, closed in finally
    // Previously created a new Dio() per chunk iteration, leaking connections
    final repairDio = Dio();
    try {
      for (var i = 0; i < task.threadCount; i++) {
        if (cancelToken.isCancelled) return false;
        final start = i * chunkSize;
        final end = (i == task.threadCount - 1)
            ? task.fileSize - 1
            : start + chunkSize - 1;
        try {
          final response = await repairDio.get<List<int>>(
            task.url,
            options: Options(
              headers: {'Range': 'bytes=$start-$end'},
              responseType: ResponseType.bytes,
            ),
            cancelToken: cancelToken,
          );
          if (response.data != null) {
            final freshData = response.data!;
            final existing = await writer.readRange(start, freshData.length);
            if (!_bytesEqual(freshData, existing)) {
              corruptedChunks.add(i);
              await writer.writeAt(start, freshData);
            }
          }
        } catch (e) {
          _log.warning('[Verify] Range request failed for chunk $i: $e');
        }
      }
    } finally {
      repairDio.close(); // FIX: Always closed, even on cancel/exception
    }

    if (corruptedChunks.isEmpty) {
      _log.warning('[Verify] No corrupted chunk found during repair check.');
      return false;
    }

    await writer.flushAll();

    // FIX(BUG-2): Streaming SHA-256 re-verification to prevent OOM
    // Previously used file.readAsBytes() which caused OOM on multi-GB files
    final repairedHash =
        (await ChecksumService.sha256File(task.localFilePath)).toLowerCase();

    if (repairedHash == expectedSha256.toLowerCase()) {
      _log.info(
        '[Verify] Successfully repaired ${corruptedChunks.length} corrupted chunks!',
      );
      return true;
    }
    return false;
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ============================================================
  // FIXED: _cancellableDelay — used for governor sleep and retry backoff
  // ============================================================

  /// A delay that completes immediately if [cancelToken] is cancelled.
  /// Prevents the engine from being stuck in a sleep when the user
  /// cancels or deletes a download.
  static Future<void> _cancellableDelay(
    Duration duration, {
    required CancelToken cancelToken,
  }) async {
    if (cancelToken.isCancelled) return;
    final completer = Completer<void>();
    final timer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete();
    });
    final sub = cancelToken.whenCancel.then((_) {
      timer.cancel();
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    await sub;
  }

  // ============================================================
  // _validateContentRange — FIX(16)
  // ============================================================

  void _validateContentRange(
    String? value, {
    required int expectedStart,
    required int expectedEnd,
    required int expectedTotal,
    required String punyUrl,
    bool allowUnknown = false,
  }) {
    if (value == null || value.trim().isEmpty) {
      // FIX(16): on a fresh (non-resume) start a missing header is fine —
      // some CDNs omit it. Only enforce on resume.
      if (allowUnknown) return;
      throw DioException(
        requestOptions: RequestOptions(path: punyUrl),
        type: DioExceptionType.badResponse,
        message: 'Invalid Content-Range: missing header on resume.',
      );
    }

    final match = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+|\*)').firstMatch(value);
    if (match == null) {
      throw DioException(
        requestOptions: RequestOptions(path: punyUrl),
        type: DioExceptionType.badResponse,
        message: 'Invalid Content-Range: unparseable "$value".',
      );
    }

    final serverStart = int.parse(match.group(1)!);
    final serverEnd = int.parse(match.group(2)!);
    final serverTotalStr = match.group(3)!;
    final serverTotal = serverTotalStr == '*' ? -1 : int.parse(serverTotalStr);

    if (serverStart != expectedStart || serverEnd != expectedEnd) {
      throw DioException(
        requestOptions: RequestOptions(path: punyUrl),
        type: DioExceptionType.badResponse,
        message: 'Invalid Content-Range: expected $expectedStart-$expectedEnd, '
            'got $serverStart-$serverEnd.',
      );
    }

    if (serverTotal > 0 && expectedTotal > 0 && serverTotal != expectedTotal) {
      throw DioException(
        requestOptions: RequestOptions(path: punyUrl),
        type: DioExceptionType.badResponse,
        message: 'Invalid Content-Range: total size mismatch. '
            'Expected $expectedTotal, got $serverTotal.',
      );
    }
  }

  // ============================================================
  // Multi-threaded download with FIX(2-B): single cancel listener
  // ============================================================

  // ignore: unused_element
  Future<void> _doMultiThreadedDownload({
    required String punyUrl,
    required String currentTempFilePath,
    required int totalSize,
    required int threadCount,
    required List<int> chunkProgress,
    required CancelToken cancelToken,
    required List<CancelToken> chunkCancelTokens,
    required BandwidthGovernor governor,
    required Dio isolatedDio,
    required DownloadJournal journal,
    required Lock journalLock,
    required Lock progressLock,
    required Lock stateFileLock,
    required File stateFile,
    required ValueChangedProgress onProgress,
    required String? savedEtag,
    required String? savedLastModified,
    required Stopwatch stopwatch,
    required Queue<_SpeedSample> speedSamples,
    required int Function() speedLimitBytesPerSecond,
    required int Function() activeDownloadCount,
  }) async {
    final futures = <Future<void>>[];
    final partSize = (totalSize / threadCount).floor();

    // FIX(2-B): Register cancel listener ONCE outside the for loop.
    // Previously registered threadCount identical listeners inside the loop.
    cancelToken.whenCancel.then((_) {
      for (final ct in chunkCancelTokens) {
        if (!ct.isCancelled) ct.cancel();
      }
    });

    try {
      for (int i = 0; i < threadCount; i++) {
        final idx = i;
        final start = idx * partSize;
        final end =
            (idx == threadCount - 1) ? (totalSize - 1) : (start + partSize - 1);

        futures.add(() async {
          var resumeFrom = chunkProgress[idx];
          if (resumeFrom >= (end - start + 1)) return;

          int attempts = 0;
          const maxAttempts = 3;

          while (attempts < maxAttempts) {
            attempts++;
            try {
              resumeFrom = chunkProgress[idx];
              if (resumeFrom >= (end - start + 1)) break;

              final headers = <String, dynamic>{};
              headers['Range'] = 'bytes=${start + resumeFrom}-$end';

              if (resumeFrom > 0) {
                final ifRange = await progressLock.synchronized<String?>(
                  () => _firstNonEmpty(savedEtag, savedLastModified),
                );
                if (ifRange != null) {
                  headers['If-Range'] = ifRange;
                }
              }

              final chunkResponse = await isolatedDio.get<ResponseBody>(
                punyUrl,
                cancelToken: chunkCancelTokens[idx],
                options: Options(
                  responseType: ResponseType.stream,
                  followRedirects: true,
                  headers: headers,
                  validateStatus: (_) => true,
                ),
              );

              if (chunkResponse.statusCode == 200 && resumeFrom > 0) {
                debugPrint(
                  '[DownloadEngine] File changed on server during resume. '
                  'Restarting download from scratch.',
                );
                throw _FileChangedOnServerException();
              }

              // FIX(16): Validate Content-Range
              _validateContentRange(
                chunkResponse.headers.value('content-range'),
                expectedStart: start + resumeFrom,
                expectedEnd: end,
                expectedTotal: totalSize,
                punyUrl: punyUrl,
              );

              final stream = chunkResponse.data?.stream;
              if (stream == null) {
                throw DioException(
                  requestOptions: RequestOptions(path: punyUrl),
                  type: DioExceptionType.badResponse,
                  message: 'Server returned empty response body.',
                );
              }

              try {
                await for (final chunk in stream) {
                  if (cancelToken.isCancelled ||
                      chunkCancelTokens[idx].isCancelled) {
                    throw DioException(
                      requestOptions: RequestOptions(path: punyUrl),
                      type: DioExceptionType.cancel,
                      message: 'Download cancelled.',
                    );
                  }

                  _tryUpdateBandwidthGovernor(
                    governor,
                    _perTaskSpeedLimit(
                      speedLimitBytesPerSecond(),
                      activeDownloadCount(),
                    ),
                  );

                  // FIX: Use cancellable delay for governor sleep
                  final sleepMs = await governor.acquire(chunk.length);
                  if (sleepMs > 0) {
                    await _cancellableDelay(
                      Duration(milliseconds: sleepMs),
                      cancelToken: chunkCancelTokens[idx],
                    );
                    if (chunkCancelTokens[idx].isCancelled) {
                      throw DioException(
                        requestOptions: RequestOptions(path: punyUrl),
                        type: DioExceptionType.cancel,
                        message: 'Download cancelled.',
                      );
                    }
                  }

                  await progressLock.synchronized(() {
                    chunkProgress[idx] += chunk.length;
                  });
                }
              } catch (e) {
                if (e is _FileChangedOnServerException) rethrow;
                if (cancelToken.isCancelled ||
                    chunkCancelTokens[idx].isCancelled) {
                  rethrow;
                }
                if (attempts >= maxAttempts) {
                  for (final ct in chunkCancelTokens) {
                    if (!ct.isCancelled) ct.cancel();
                  }
                  rethrow;
                }
                // FIX: Use cancellable delay for retry backoff
                final delay = (attempts * attempts * 2) + Random().nextInt(3);
                await _cancellableDelay(
                  Duration(seconds: delay),
                  cancelToken: chunkCancelTokens[idx],
                );
                if (chunkCancelTokens[idx].isCancelled ||
                    cancelToken.isCancelled) {
                  throw DioException(
                    requestOptions: RequestOptions(path: punyUrl),
                    type: DioExceptionType.cancel,
                    message: 'Download cancelled.',
                  );
                }
                continue;
              }
              break;
            } catch (e) {
              if (e is _FileChangedOnServerException) rethrow;
              if (cancelToken.isCancelled ||
                  chunkCancelTokens[idx].isCancelled) {
                rethrow;
              }
              if (attempts >= maxAttempts) {
                for (final ct in chunkCancelTokens) {
                  if (!ct.isCancelled) ct.cancel();
                }
                rethrow;
              }
              // FIX: Use cancellable delay for retry backoff
              final delay = (attempts * attempts * 2) + Random().nextInt(3);
              await _cancellableDelay(
                Duration(seconds: delay),
                cancelToken: chunkCancelTokens[idx],
              );
            }
          }
        }());
      }

      await Future.wait(futures);
    } catch (e) {
      // FIX: Use the caught error directly — 'chunkError' was undefined
      final errorToCheck = e;

      bool isRangeRejection = false;
      if (errorToCheck is DioException &&
          errorToCheck.type == DioExceptionType.badResponse) {
        final status = errorToCheck.response?.statusCode;
        if (status == 200 || status == 416) {
          isRangeRejection = true;
        }
        if (errorToCheck.message?.startsWith('Invalid Content-Range') == true) {
          isRangeRejection = true;
        }
      }

      if (!isRangeRejection) {
        rethrow;
      }

      debugPrint(
        'Multi-threaded range request failed (Range Rejection): $e. '
        'Falling back to single-threaded safe restart.',
      );
    }
  }

  // ============================================================
  // Helper methods
  // ============================================================

  String? _firstNonEmpty(String? a, String? b) {
    if (a != null && a.isNotEmpty) return a;
    if (b != null && b.isNotEmpty) return b;
    return null;
  }

  void _tryUpdateBandwidthGovernor(BandwidthGovernor governor, int limit) {
    // FIX: BandwidthGovernor has no 'bytesPerSecond' getter; call updateLimit directly
    governor.updateLimit(limit);
  }

  int _perTaskSpeedLimit(int globalLimit, int activeCount) {
    if (globalLimit <= 0) return 0;
    final count = activeCount <= 0 ? 1 : activeCount;
    return (globalLimit / count).floor();
  }
}

class _FileChangedOnServerException implements Exception {
  @override
  String toString() => 'File changed on server. Restart required.';
}

typedef ValueChangedProgress = void Function(DownloadProgress progress);

class _SpeedSample {
  final int timestampMs;
  final int bytes;
  _SpeedSample(this.timestampMs, this.bytes);
}

