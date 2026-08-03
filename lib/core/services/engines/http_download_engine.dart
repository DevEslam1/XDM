import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import '../../../features/downloads/models/download_task.dart';
import '../bandwidth_governor.dart';
import '../connection_manager.dart';
import '../download_journal.dart';
import '../positional_file_writer.dart';

class HttpDownloadEngine {
  static final _log = Logger('HttpDownloadEngine');

  final ConnectionManager connectionManager;
  final BandwidthGovernor bandwidthGovernor;
  final DownloadJournal Function(String path) journalFactory;

  Timer? _adaptiveThreadTimer;
  int _currentThreads = 4;
  final List<double> _throughputHistory = [];

  HttpDownloadEngine({
    ConnectionManager? connectionManager,
    BandwidthGovernor? bandwidthGovernor,
    DownloadJournal Function(String path)? journalFactory,
  })  : connectionManager = connectionManager ?? ConnectionManager(),
        bandwidthGovernor = bandwidthGovernor ?? BandwidthGovernor(0),
        journalFactory = journalFactory ?? ((path) => DownloadJournal(path));

  int get currentThreads => _currentThreads;

  void startAdaptiveThreadMonitor(DownloadTask task) {
    _adaptiveThreadTimer?.cancel();
    _currentThreads = task.threadCount;
    _throughputHistory.clear();

    _adaptiveThreadTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _evaluateThreadAdjustment(task);
    });
  }

  double _emaSpeed = 0.0;

  void _evaluateThreadAdjustment(DownloadTask task) {
    final currentSpeed = task.speed;
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
        '[AdaptiveThreads] Reducing threads to $_currentThreads (EMA trend: ${(trend * 100).toStringAsFixed(1)}%)',
      );
    } else if (trend > 0.15 &&
        _currentThreads < task.threadCount &&
        _currentThreads < 16) {
      _currentThreads++;
      _log.info(
        '[AdaptiveThreads] Increasing threads to $_currentThreads (EMA trend: ${(trend * 100).toStringAsFixed(1)}%)',
      );
    }
  }

  void stopAdaptiveThreadMonitor() {
    _adaptiveThreadTimer?.cancel();
    _adaptiveThreadTimer = null;
    _throughputHistory.clear();
  }

  Future<bool> verifyAndRepair({
    required DownloadTask task,
    required PositionalFileWriter writer,
    required String expectedSha256,
    required CancelToken cancelToken,
  }) async {
    final file = File(task.localFilePath);
    if (!await file.exists()) return false;

    final bytes = await file.readAsBytes();
    final actualHash = sha256.convert(bytes).toString().toLowerCase();

    if (actualHash == expectedSha256.toLowerCase()) {
      _log.info('[Verify] SHA-256 matched successfully: $actualHash');
      return true;
    }

    _log.warning(
      '[Verify] SHA-256 mismatch ($actualHash vs $expectedSha256). Attempting chunk repair...',
    );
    final chunkSize = (task.fileSize / task.threadCount).ceil();
    final corruptedChunks = <int>[];

    for (var i = 0; i < task.threadCount; i++) {
      if (cancelToken.isCancelled) return false;
      final start = i * chunkSize;
      final end = (i == task.threadCount - 1)
          ? task.fileSize - 1
          : start + chunkSize - 1;

      try {
        final dio = Dio();
        final response = await dio.get<List<int>>(
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

    if (corruptedChunks.isEmpty) {
      _log.warning('[Verify] No corrupted chunk found during repair check.');
      return false;
    }

    await writer.flushAll();
    final repairedBytes = await file.readAsBytes();
    final repairedHash = sha256.convert(repairedBytes).toString().toLowerCase();

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

  Future<void> download({
    required DownloadTask task,
    required CancelToken cancelToken,
    required void Function(double progress, int downloadedBytes, int speedBps)
        onProgress,
    required PositionalFileWriter writer,
    int threadCountOverride = 0, // ← NEW
  }) async {
    final int effectiveThreads =
        threadCountOverride > 0 ? threadCountOverride : task.threadCount;
    if (threadCountOverride > 0) {
      task = task.copyWith(threadCount: effectiveThreads);
    }
    startAdaptiveThreadMonitor(
        task); // Note: monitor still uses task.threadCount for trend logic, but we can pass effectiveThreads if needed
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
        followRedirects: true,
        validateStatus: (_) => true,
      ),
    );
    final offset = task.downloadedBytes.clamp(
      0,
      task.fileSize > 0 ? task.fileSize : task.downloadedBytes,
    );
    var total = task.fileSize;

    try {
      final headers = <String, dynamic>{};
      if (offset > 0) headers['Range'] = 'bytes=$offset-';
      final response = await dio.get<ResponseBody>(
        task.url,
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.stream, headers: headers),
      );

      if (response.statusCode != 200 && response.statusCode != 206) {
        throw DioException.badResponse(
          statusCode: response.statusCode ?? 0,
          requestOptions: response.requestOptions,
          response: response,
        );
      }

      // reject HTML responses (expired YouTube stream → error page)
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

      if (offset > 0 && response.statusCode != 206) {
        throw StateError('Server rejected resume: expected HTTP 206.');
      }

      final contentLength = int.tryParse(
            response.headers.value(Headers.contentLengthHeader) ?? '',
          ) ??
          0;
      if (total <= 0 && contentLength > 0) {
        total = offset + contentLength;
      }

      var downloaded = offset;
      final stopwatch = Stopwatch()..start();
      await for (final chunk in response.data!.stream) {
        if (cancelToken.isCancelled) {
          throw DioException.requestCancelled(
            requestOptions: response.requestOptions,
            reason: 'Download cancelled.',
          );
        }
        final data = Uint8List.fromList(chunk);
        await writer.write(0, downloaded, data);
        downloaded += data.length;
        final speed = stopwatch.elapsedMilliseconds > 0
            ? (downloaded - offset) * 1000 ~/ stopwatch.elapsedMilliseconds
            : 0;
        onProgress(
          total > 0 ? (downloaded / total).clamp(0.0, 1.0) : 0.0,
          downloaded,
          speed,
        );
      }
      await writer.flushAll();
      if (total > 0 && downloaded != total) {
        throw StateError(
          'Download ended early: expected $total bytes, got $downloaded.',
        );
      }
    } finally {
      stopAdaptiveThreadMonitor();
      dio.close(force: true);
    }
  }
}
