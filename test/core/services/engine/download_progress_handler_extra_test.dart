import 'package:dio/dio.dart';
import 'package:dmx/core/domain/engine_types.dart';
import 'package:dmx/core/services/engine/download_progress_handler.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadProgressHandler buildHandler({
  ValueChangedProgress? onProgress,
  CancelToken? cancelToken,
  bool isTorrent = false,
  YtStreamKind? ytStreamKind,
  int? ytCounterpartSize,
  int Function()? interval,
  int lastDownloadedBytes = 0,
  int lastFileSize = 0,
}) {
  return DownloadProgressHandler(
    taskId: 'task-1',
    onProgress: onProgress ?? (_) {},
    cancelToken: cancelToken ?? CancelToken(),
    resolvedFileName: 'file.bin',
    resolvedSupportsResume: true,
    ytStreamKind: ytStreamKind,
    ytCounterpartSize: ytCounterpartSize,
    ytCounterpartDownloadedBytes: null,
    isTorrent: isTorrent,
    getEffectiveIntervalMs: interval ?? () => 0,
    lastDownloadedBytes: lastDownloadedBytes,
    lastFileSize: lastFileSize,
  );
}

void main() {
  group('visible-for-testing accessors', () {
    test('counterpart wait start round-trips', () {
      final handler = buildHandler();
      addTearDown(handler.dispose);
      expect(handler.counterpartWaitStartForTesting, isNull);
      final when = DateTime(2024);
      handler.counterpartWaitStartForTesting = when;
      expect(handler.counterpartWaitStartForTesting, when);
    });
  });

  group('handleProgress counterpart registration', () {
    test('flags an unregistered counterpart when the stream kind is set',
        () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(
          onProgress: emitted.add, ytStreamKind: YtStreamKind.video);
      addTearDown(handler.dispose);

      final taskIds = TimestampedLruMap<String, String>();
      final live = TimestampedLruMap<String, int>();
      await handler.handleProgress(
        {'downloadedBytes': 1, 'fileSize': 100, 'statusMessage': 'Downloading'},
        ytCounterpartTaskIds: taskIds,
        ytLiveBytes: live,
      );
      expect(emitted, isNotEmpty);
    });
  });

  group('counterpart wait window', () {
    test('between 30s and 5min the state becomes retrying', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(
        onProgress: emitted.add,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 100,
      );
      addTearDown(handler.dispose);
      handler.counterpartWaitStartForTesting =
          DateTime.now().subtract(const Duration(seconds: 40));

      await handler.handleWorkerProgress(
        {'downloadedBytes': 1, 'fileSize': 100, 'statusMessage': 'Downloading'},
        isCounterpartUnregistered: true,
      );
      expect(emitted.last.cycleState, CycleState.retrying);
    });

    test('the third expiration is caught and returns cleanly', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(
        onProgress: emitted.add,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 100,
      );
      addTearDown(handler.dispose);

      for (var i = 0; i < 3; i++) {
        handler.counterpartWaitStartForTesting =
            DateTime.now().subtract(const Duration(minutes: 6));
        try {
          await handler.handleWorkerProgress(
            {
              'downloadedBytes': 1,
              'fileSize': 100,
              'statusMessage': 'Downloading',
            },
            isCounterpartUnregistered: true,
          );
        } catch (_) {}
      }
      expect(emitted.any((p) => p.cycleState == CycleState.failed), isTrue);
    });
  });

  group('completion gate byte-count fallback', () {
    test('implicit completed state is gated by the self byte count', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(
        onProgress: emitted.add,
        ytStreamKind: YtStreamKind.video,
        lastDownloadedBytes: 100,
        lastFileSize: 100,
      );
      addTearDown(handler.dispose);

      await handler.handleWorkerProgress({
        'downloadedBytes': 100,
        'fileSize': 100,
        'statusMessage': 'completed',
        'ytCounterpartSize': 100,
        'ytCounterpartDownloadedBytes': 50,
      });
      expect(emitted.last.cycleState, isNot(CycleState.completed));
    });
  });

  group('chunk aggregation on completion', () {
    test('completed cycle marks every chunk done', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(onProgress: emitted.add);
      addTearDown(handler.dispose);

      await handler.handleWorkerProgress({
        'downloadedBytes': 100,
        'fileSize': 100,
        'cycleState': 'completed',
        'chunkDetails': [
          {
            'index': 0,
            'start': 0,
            'end': 49,
            'downloaded': 50,
            'size': 50,
            'ratio': 1.0
          },
          {
            'index': 1,
            'start': 50,
            'end': 99,
            'downloaded': 50,
            'size': 50,
            'ratio': 1.0
          },
        ],
      });
      expect(emitted.last.completedChunks, 2);
    });
  });

  group('torrent substantial-delta triggers', () {
    test('peer, seed and file-count changes force emission', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(
          onProgress: emitted.add, isTorrent: true, interval: () => 100000);
      addTearDown(handler.dispose);

      Map<String, dynamic> p({
        int peers = 0,
        int seeds = 0,
        List<Map<String, dynamic>>? files,
      }) =>
          {
            'downloadedBytes': 500,
            'fileSize': 1000,
            'totalWanted': 1000,
            'totalWantedDone': 500,
            'statusMessage': 'Downloading',
            'numPeers': peers,
            'numSeeds': seeds,
            if (files != null) 'torrentFiles': files,
          };

      await handler.handleWorkerProgress(p(files: [
        {'name': 'a', 'length': 1000, 'downloadedBytes': 500},
      ]));
      expect(emitted, hasLength(1));

      await handler.handleWorkerProgress(p(peers: 1));
      expect(emitted, hasLength(2));

      await handler.handleWorkerProgress(p(peers: 1, seeds: 1));
      expect(emitted, hasLength(3));
    });
  });

  group('throttle timer with cancellation', () {
    test('a cancelled pending progress is dropped by the timer', () {
      fakeAsync((async) {
        final emitted = <DownloadProgress>[];
        final token = CancelToken();
        final handler = buildHandler(
          onProgress: emitted.add,
          cancelToken: token,
          interval: () => 1000,
        );

        handler.handleWorkerProgress({
          'downloadedBytes': 100,
          'fileSize': 1000,
          'statusMessage': 'Downloading',
        });
        async.flushMicrotasks();
        expect(emitted, hasLength(1));

        handler.handleWorkerProgress({
          'downloadedBytes': 200,
          'fileSize': 1000,
          'statusMessage': 'Downloading',
        });
        async.flushMicrotasks();
        token.cancel('user');

        async.elapse(const Duration(milliseconds: 1100));
        async.flushMicrotasks();
        expect(emitted, hasLength(1));
        handler.dispose();
      });
    });
  });
}
