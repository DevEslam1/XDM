import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:logging/logging.dart';

import '../checksum_service.dart';
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
}

