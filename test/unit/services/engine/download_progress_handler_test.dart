import 'package:dio/dio.dart';
import 'package:dmx/core/services/engine/download_progress_handler.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadProgressHandler Tests', () {
    test(
        'Immediate emission on first progress report and throttled subsequently',
        () async {
      final emitted = <DownloadProgress>[];
      final cancelToken = CancelToken();

      final handler = DownloadProgressHandler(
        taskId: 'task_1',
        onProgress: emitted.add,
        cancelToken: cancelToken,
        resolvedFileName: 'test.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: null,
        ytCounterpartSize: null,
        ytCounterpartDownloadedBytes: null,
        isTorrent: false,
        getEffectiveIntervalMs: () => 100,
        lastDownloadedBytes: 0,
        lastFileSize: 1000,
      );

      // First progress report should emit immediately
      await handler.handleProgress({
        'downloadedBytes': 100,
        'fileSize': 1000,
        'speed': 500.0,
      });

      expect(emitted.length, 1);
      expect(emitted.first.downloadedBytes, 100);

      // Second progress report within 100ms interval should be throttled (queued)
      await handler.handleProgress({
        'downloadedBytes': 200,
        'fileSize': 1000,
        'speed': 600.0,
      });

      expect(emitted.length, 1);

      // Wait for throttle timer to fire
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(emitted.length, 2);
      expect(emitted.last.downloadedBytes, 200);

      handler.dispose();
    });

    test('Cancellation prevents queued throttle emission and suppresses emits',
        () async {
      final emitted = <DownloadProgress>[];
      final cancelToken = CancelToken();

      final handler = DownloadProgressHandler(
        taskId: 'task_2',
        onProgress: emitted.add,
        cancelToken: cancelToken,
        resolvedFileName: 'test.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: null,
        ytCounterpartSize: null,
        ytCounterpartDownloadedBytes: null,
        isTorrent: false,
        getEffectiveIntervalMs: () => 100,
        lastDownloadedBytes: 0,
        lastFileSize: 1000,
      );

      // First emit
      await handler.handleProgress({'downloadedBytes': 100, 'fileSize': 1000});
      expect(emitted.length, 1);

      // Queue second emit
      await handler.handleProgress({'downloadedBytes': 200, 'fileSize': 1000});
      expect(emitted.length, 1);

      // Cancel token
      cancelToken.cancel();

      // Wait for timer
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // No second emission should have occurred
      expect(emitted.length, 1);

      handler.dispose();
    });

    test('Torrent file diffing and progress aggregation calculations',
        () async {
      final emitted = <DownloadProgress>[];
      final cancelToken = CancelToken();

      final handler = DownloadProgressHandler(
        taskId: 'torrent_1',
        onProgress: emitted.add,
        cancelToken: cancelToken,
        resolvedFileName: 'archive.torrent',
        resolvedSupportsResume: true,
        ytStreamKind: null,
        ytCounterpartSize: null,
        ytCounterpartDownloadedBytes: null,
        isTorrent: true,
        getEffectiveIntervalMs: () => 50,
        lastDownloadedBytes: 0,
        lastFileSize: 0,
      );

      final torrentFiles = [
        {
          'name': 'file1.txt',
          'length': 1000,
          'downloadedBytes': 500,
          'selected': true,
        },
        {
          'name': 'file2.txt',
          'length': 2000,
          'downloadedBytes': 2000,
          'selected': true,
        },
        {
          'name': 'unselected.txt',
          'length': 5000,
          'downloadedBytes': 0,
          'selected': false,
        },
      ];

      await handler.handleProgress({
        'downloadedBytes': 2500,
        'fileSize': 3000,
        'torrentFiles': torrentFiles,
        'statusMessage': 'downloading',
      });

      expect(emitted.length, 1);
      final p = emitted.first;
      expect(p.totalFiles, 2); // 2 selected files
      expect(p.completedFiles, 1); // file2 is complete (2000/2000)
      expect(p.totalFileBytes, 3000); // 1000 + 2000
      expect(p.downloadedFileBytes, 2500); // 500 + 2000

      handler.dispose();
    });
  });
}
