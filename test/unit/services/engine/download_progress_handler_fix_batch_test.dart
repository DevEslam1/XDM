import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/download_progress_handler.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the HTTP-engine fix batch (H6).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DownloadProgressHandler buildHandler(
    List<DownloadProgress> emitted,
    CancelToken cancelToken,
  ) =>
      DownloadProgressHandler(
        taskId: 'fix-batch-task',
        onProgress: emitted.add,
        cancelToken: cancelToken,
        resolvedFileName: 'test.bin',
        resolvedSupportsResume: true,
        ytStreamKind: null,
        ytCounterpartSize: null,
        ytCounterpartDownloadedBytes: null,
        isTorrent: false,
        getEffectiveIntervalMs: () => 10000,
        lastDownloadedBytes: 0,
        lastFileSize: 0,
      );

  group('H6 — progress handler', () {
    test('F20: worker\u0027s final Paused progress survives a cancelled token',
        () async {
      final emitted = <DownloadProgress>[];
      final cancelToken = CancelToken();
      final handler = buildHandler(emitted, cancelToken);

      // The engine cancels the token when the user pauses; the worker's
      // LAST progress message (with the final byte counts) arrives after
      // the cancellation. Pre-fix it was dropped at the entry guard.
      cancelToken.cancel();

      await handler.handleWorkerProgress({
        'downloadedBytes': 123456,
        'fileSize': 999999,
        'statusMessage': 'Paused',
      });

      expect(emitted.length, equals(1));
      expect(emitted.first.cycleState, equals(CycleState.paused));
      expect(emitted.first.downloadedBytes, equals(123456));
      expect(emitted.first.fileSize, equals(999999));

      handler.dispose();
    });

    test('F20: non-paused emissions stay suppressed after cancellation',
        () async {
      final emitted = <DownloadProgress>[];
      final cancelToken = CancelToken();
      final handler = buildHandler(emitted, cancelToken);

      cancelToken.cancel();

      await handler.handleWorkerProgress({
        'downloadedBytes': 500,
        'fileSize': 999999,
        'statusMessage': 'Downloading…',
      });

      // The message is classified as paused (not dropped)...
      expect(emitted.length, equals(1));
      expect(emitted.first.cycleState, equals(CycleState.paused));

      // ...while a direct non-paused emit is still suppressed.
      handler.emit(const DownloadProgress(
        downloadedBytes: 600,
        fileSize: 999999,
        speed: 0,
        eta: null,
        cycleState: CycleState.downloading,
      ));
      expect(emitted.length, equals(1));

      handler.dispose();
    });

    test('F22: indeterminate chunk with progress counts as a done part',
        () async {
      final emitted = <DownloadProgress>[];
      final cancelToken = CancelToken();
      final handler = buildHandler(emitted, cancelToken);

      await handler.handleWorkerProgress({
        'downloadedBytes': 500,
        'fileSize': 0,
        'speed': 10.0,
        'chunkDetails': [
          {
            'index': 0,
            'start': 0,
            'end': -1,
            'downloaded': 500,
            'size': -1,
            'ratio': -1.0,
          },
        ],
        'totalChunks': 1,
      });

      expect(emitted, isNotEmpty);
      // `isIndeterminate && size >= 0` was impossible (indeterminate means
      // size < 0), so an indeterminate chunk actively downloading never
      // contributed to completedChunks.
      expect(emitted.last.completedChunks, equals(1));
      expect(emitted.last.totalChunks, equals(1));

      handler.dispose();
    });

    test('F22: indeterminate chunk without progress is not a done part',
        () async {
      final emitted = <DownloadProgress>[];
      final cancelToken = CancelToken();
      final handler = buildHandler(emitted, cancelToken);

      await handler.handleWorkerProgress({
        'downloadedBytes': 0,
        'fileSize': 0,
        'speed': 0.0,
        'chunkDetails': [
          {
            'index': 0,
            'start': 0,
            'end': -1,
            'downloaded': 0,
            'size': -1,
            'ratio': -1.0,
          },
        ],
        'totalChunks': 1,
      });

      expect(emitted.last.completedChunks, equals(0));

      handler.dispose();
    });

    test('F21 decoupling regression: due report emitted while save is pending',
        () async {
      final receivePort = ReceivePort();
      final messages = <dynamic>[];
      receivePort.listen(messages.add);
      const cmd = DownloadCommand(
        taskId: 'fix-batch-f21',
        url: 'https://example.com/test.bin',
        punyUrl: 'https://example.com/test.bin',
        tempFilePath: 'build/f21.tmp',
        localFilePath: 'build/f21.bin',
        threadCount: 1,
        knownFileSize: 1000,
        supportsResume: true,
      );
      final job = HttpTransferJob(cmd, receivePort.sendPort);
      job.stateForTesting = TransferState(
        totalSize: 1000,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 999, downloaded: 500)],
      );
      job.startStopwatchForTesting();
      job.stateSavePendingForTesting = true;

      // Pre-fix the pending-save guard returned before emitting any due
      // progress report, freezing UI progress for the whole save duration.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await job.throttledSaveAndReportForTesting();
      // _send() queues the message on the port — yield so the listener runs.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(job.stateSavePendingForTesting, isTrue);
      expect(
          messages
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .any((m) => m['type'] == 'progress'),
          isTrue);
      receivePort.close();
    });
  });
}
