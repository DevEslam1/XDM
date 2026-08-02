import 'dart:async';
import 'dart:io';
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

  void _evaluateThreadAdjustment(DownloadTask task) {
    final currentSpeed = task.speed;
    _throughputHistory.add(currentSpeed);
    if (_throughputHistory.length > 6) _throughputHistory.removeAt(0);
    if (_throughputHistory.length < 3) return;

    final recent = _throughputHistory.sublist(_throughputHistory.length - 3);
    final older = _throughputHistory.sublist(0, _throughputHistory.length - 3);
    final recentAvg = recent.reduce((a, b) => a + b) / recent.length;
    final olderAvg = older.isEmpty ? recentAvg : older.reduce((a, b) => a + b) / older.length;

    final trend = olderAvg > 0 ? (recentAvg - olderAvg) / olderAvg : 0.0;

    if (trend < -0.15 && _currentThreads > 2) {
      _currentThreads--;
      _log.info('[AdaptiveThreads] Reducing threads to $_currentThreads (trend: ${(trend * 100).toStringAsFixed(1)}%)');
    } else if (trend > -0.05 && _currentThreads < task.threadCount && _currentThreads < 16) {
      _currentThreads++;
      _log.info('[AdaptiveThreads] Increasing threads to $_currentThreads (trend: ${(trend * 100).toStringAsFixed(1)}%)');
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

    _log.warning('[Verify] SHA-256 mismatch ($actualHash vs $expectedSha256). Attempting chunk repair...');
    final chunkSize = (task.fileSize / task.threadCount).ceil();
    final corruptedChunks = <int>[];

    for (var i = 0; i < task.threadCount; i++) {
      if (cancelToken.isCancelled) return false;
      final start = i * chunkSize;
      final end = (i == task.threadCount - 1) ? task.fileSize - 1 : start + chunkSize - 1;

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
      _log.info('[Verify] Successfully repaired ${corruptedChunks.length} corrupted chunks!');
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
    required void Function(double progress, int downloadedBytes, int speedBps) onProgress,
    required PositionalFileWriter writer,
  }) async {
    startAdaptiveThreadMonitor(task);
  }
}
