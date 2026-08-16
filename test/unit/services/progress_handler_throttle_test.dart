import 'package:dio/dio.dart';
import 'package:dmx/core/services/engine/download_progress_handler.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadProgressHandler Tests', () {
    test('bypasses throttle immediately for terminal cycle states', () async {
      final emittedEvents = <DownloadProgress>[];
      final cancelToken = CancelToken();

      final handler = DownloadProgressHandler(
        taskId: 'test_task_1',
        onProgress: (p) => emittedEvents.add(p),
        cancelToken: cancelToken,
        resolvedFileName: 'test.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: null,
        ytCounterpartSize: null,
        ytCounterpartDownloadedBytes: null,
        isTorrent: false,
        getEffectiveIntervalMs: () => 10000, // 10s throttle
        lastDownloadedBytes: 0,
        lastFileSize: 1000,
      );

      // Emit initial progress event
      await handler.handleWorkerProgress({
        'downloadedBytes': 100,
        'fileSize': 1000,
        'statusMessage': 'Downloading',
        'cycleState': CycleState.downloading,
      });

      expect(emittedEvents.length, 1);
      expect(emittedEvents.first.cycleState, CycleState.downloading);

      // Subsequent non-terminal progress is throttled
      await handler.handleWorkerProgress({
        'downloadedBytes': 200,
        'fileSize': 1000,
        'statusMessage': 'Downloading',
        'cycleState': CycleState.downloading,
      });
      expect(emittedEvents.length, 1);

      // Terminal state (failed) bypasses throttle immediately
      await handler.handleWorkerProgress({
        'downloadedBytes': 200,
        'fileSize': 1000,
        'statusMessage': 'Error encountered',
        'cycleState': CycleState.failed,
      });
      expect(emittedEvents.length, 2);
      expect(emittedEvents.last.cycleState, CycleState.failed);

      // Terminal state (paused) bypasses throttle immediately
      await handler.handleWorkerProgress({
        'downloadedBytes': 200,
        'fileSize': 1000,
        'statusMessage': 'Paused',
        'cycleState': CycleState.paused,
      });
      expect(emittedEvents.length, 3);
      expect(emittedEvents.last.cycleState, CycleState.paused);

      // Terminal state (completed) bypasses throttle immediately
      await handler.handleWorkerProgress({
        'downloadedBytes': 1000,
        'fileSize': 1000,
        'statusMessage': 'Completed',
        'cycleState': CycleState.completed,
      });
      expect(emittedEvents.length, 4);
      expect(emittedEvents.last.cycleState, CycleState.completed);

      handler.dispose();
    });

    test('overrides cycleState to starting when YT counterpart is unregistered',
        () async {
      final emittedEvents = <DownloadProgress>[];
      final cancelToken = CancelToken();

      final handler = DownloadProgressHandler(
        taskId: 'yt_video_task',
        onProgress: (p) => emittedEvents.add(p),
        cancelToken: cancelToken,
        resolvedFileName: 'yt_video.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 5000,
        ytCounterpartDownloadedBytes: 0,
        isTorrent: false,
        getEffectiveIntervalMs: () => 50,
        lastDownloadedBytes: 0,
        lastFileSize: 10000,
      );

      final counterpartTaskIds =
          TimestampedLruMap<String, String>(maxCapacity: 10);
      final counterpartLiveBytes =
          TimestampedLruMap<String, int>(maxCapacity: 10);

      // Handle progress when cpId is NOT yet in counterpartTaskIds
      await handler.handleProgress(
        {
          'downloadedBytes': 0,
          'fileSize': 10000,
          'statusMessage': 'Downloading',
          'cycleState': CycleState.downloading,
        },
        ytCounterpartTaskIds: counterpartTaskIds,
        ytLiveBytes: counterpartLiveBytes,
      );

      expect(emittedEvents.isNotEmpty, true);
      expect(emittedEvents.last.cycleState, CycleState.starting);
      expect(
          emittedEvents.last.statusMessage, 'Waiting for counterpart stream…');

      handler.dispose();
    });
  });
}
