import 'package:dio/dio.dart';
import 'package:dmx/core/services/engine/download_progress_handler.dart';
import 'package:dmx/core/services/engine/engine_exceptions.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:dmx/core/services/engines/http_download_engine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadProgressHandler buildHandler({
  ValueChangedProgress? onProgress,
  CancelToken? cancelToken,
  bool isTorrent = false,
  YtStreamKind? ytStreamKind,
  int? ytCounterpartSize,
  int? ytCounterpartDownloadedBytes,
  int Function()? interval,
  int lastDownloadedBytes = 0,
  int lastFileSize = 0,
  List<Map<String, dynamic>>? Function()? getTorrentFiles,
}) {
  return DownloadProgressHandler(
    taskId: 'task-1',
    onProgress: onProgress ?? (_) {},
    cancelToken: cancelToken ?? CancelToken(),
    resolvedFileName: 'file.bin',
    resolvedSupportsResume: true,
    ytStreamKind: ytStreamKind,
    ytCounterpartSize: ytCounterpartSize,
    ytCounterpartDownloadedBytes: ytCounterpartDownloadedBytes,
    isTorrent: isTorrent,
    getEffectiveIntervalMs: interval ?? () => 0,
    lastDownloadedBytes: lastDownloadedBytes,
    lastFileSize: lastFileSize,
    getTorrentFiles: getTorrentFiles,
  );
}

void main() {
  group('DownloadProgressHandler basics', () {
    test('emits a non-torrent progress update', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(onProgress: emitted.add);
      addTearDown(handler.dispose);

      await handler.handleWorkerProgress({
        'downloadedBytes': 100,
        'fileSize': 1000,
        'speed': 12.5,
        'eta': 30,
        'statusMessage': 'Downloading',
        'supportsResume': false,
      });

      expect(emitted, isNotEmpty);
      final last = emitted.last;
      expect(last.downloadedBytes, 100);
      expect(last.fileSize, 1000);
      expect(last.speed, 12.5);
      expect(last.eta, 30);
      expect(last.cycleState, CycleState.downloading);
      expect(last.supportsResume, isFalse);
      expect(last.fileName, 'file.bin');
    });

    test('cancel token forces paused cycle and paused emission passes through',
        () async {
      final emitted = <DownloadProgress>[];
      final token = CancelToken()..cancel('user');
      final handler = buildHandler(onProgress: emitted.add, cancelToken: token);
      addTearDown(handler.dispose);

      await handler.handleWorkerProgress({
        'downloadedBytes': 10,
        'fileSize': 100,
        'statusMessage': 'Downloading',
      });
      expect(emitted.last.cycleState, CycleState.paused);
    });

    test('emit suppresses non-paused progress when cancelled', () {
      final emitted = <DownloadProgress>[];
      final token = CancelToken()..cancel('user');
      final handler = buildHandler(onProgress: emitted.add, cancelToken: token);
      addTearDown(handler.dispose);

      handler.emit(const DownloadProgress(
        downloadedBytes: 1,
        fileSize: 10,
        speed: 0,
        eta: null,
        cycleState: CycleState.downloading,
      ));
      expect(emitted, isEmpty);

      handler.emit(const DownloadProgress(
        downloadedBytes: 1,
        fileSize: 10,
        speed: 0,
        eta: null,
        cycleState: CycleState.paused,
      ));
      expect(emitted, hasLength(1));
    });

    test('markDone and handleEngineMessage set the finalized flag', () {
      final handler = buildHandler();
      addTearDown(handler.dispose);
      handler.markDone();
      expect(handler.selfActuallyFinalizedForTesting, isTrue);

      final handler2 = buildHandler();
      addTearDown(handler2.dispose);
      handler2.handleEngineMessage(EngineMessageType.done);
      expect(handler2.selfActuallyFinalizedForTesting, isTrue);
      handler2.handleEngineMessage(EngineMessageType.progress);
      expect(handler2.selfActuallyFinalizedForTesting, isTrue);
    });

    test('deriveCycleState delegates to the resolver', () {
      expect(DownloadProgressHandler.deriveCycleState('seeding', false, false),
          CycleState.seeding);
      expect(DownloadProgressHandler.deriveCycleState(null, true, false),
          CycleState.paused);
    });

    test('dispose is idempotent', () {
      final handler = buildHandler();
      handler.dispose();
      handler.dispose();
    });
  });

  group('cycle-state sources and flags', () {
    test('accepts a CycleState instance and a String name', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(onProgress: emitted.add);
      addTearDown(handler.dispose);

      await handler.handleWorkerProgress({
        'downloadedBytes': 1,
        'fileSize': 10,
        'cycleState': CycleState.verifying,
      });
      expect(emitted.last.cycleState, CycleState.verifying);

      await handler.handleWorkerProgress({
        'downloadedBytes': 2,
        'fileSize': 10,
        'cycleState': 'completed',
      });
      expect(emitted.last.cycleState, CycleState.completed);
      expect(handler.selfActuallyFinalizedForTesting, isTrue);
    });

    test('done / isDone / selfActuallyFinalized flags are honored', () async {
      final handler = buildHandler();
      addTearDown(handler.dispose);
      await handler.handleWorkerProgress({
        'downloadedBytes': 1,
        'fileSize': 10,
        'statusMessage': 'Downloading',
        'done': true,
      });
      expect(handler.selfActuallyFinalizedForTesting, isTrue);
    });

    test('pauseReason string and enum are parsed', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(onProgress: emitted.add);
      addTearDown(handler.dispose);

      await handler.handleWorkerProgress({
        'downloadedBytes': 1,
        'fileSize': 10,
        'statusMessage': 'Paused',
        'pauseReason': 'batterySaver',
      });
      expect(emitted.last.pauseReason, PauseReason.batterySaver);

      await handler.handleWorkerProgress({
        'downloadedBytes': 2,
        'fileSize': 10,
        'statusMessage': 'Paused',
        'pauseReason': PauseReason.diskFull,
      });
      expect(emitted.last.pauseReason, PauseReason.diskFull);
    });
  });

  group('chunk details', () {
    test('parses chunkDetails and changes the fingerprint', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(onProgress: emitted.add);
      addTearDown(handler.dispose);

      await handler.handleWorkerProgress({
        'downloadedBytes': 50,
        'fileSize': 100,
        'statusMessage': 'Downloading',
        'totalChunks': 2,
        'completedChunks': 1,
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
            'downloaded': 0,
            'size': 50,
            'ratio': 0.0
          },
        ],
      });

      expect(emitted.last.chunkDetails, isNotNull);
      expect(emitted.last.totalChunks, 2);
      expect(emitted.last.completedChunks, 1);
      expect(handler.chunkFingerprint, isNot(0));
    });

    test('unchanged chunk hash suppresses re-emitting chunk details', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(onProgress: emitted.add);
      addTearDown(handler.dispose);

      final chunks = [
        {
          'index': 0,
          'start': 0,
          'end': 49,
          'downloaded': 50,
          'size': 50,
          'ratio': 1.0
        },
      ];
      await handler.handleWorkerProgress({
        'downloadedBytes': 50,
        'fileSize': 100,
        'statusMessage': 'Downloading',
        'chunkDetails': chunks,
      });
      expect(emitted.last.chunkDetails, isNotNull);

      await handler.handleWorkerProgress({
        'downloadedBytes': 51,
        'fileSize': 100,
        'statusMessage': 'Downloading',
        'chunkDetails': chunks,
      });
      expect(emitted.last.chunkDetails, isNull);
    });
  });

  group('torrent progress', () {
    test('uses totalWanted/totalWantedDone and normalizes files', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(
        onProgress: emitted.add,
        isTorrent: true,
        getTorrentFiles: () => [
          {'name': 'a.bin', 'length': 1000, 'downloadedBytes': 500},
        ],
      );
      addTearDown(handler.dispose);

      await handler.handleWorkerProgress({
        'downloadedBytes': 1,
        'fileSize': 1,
        'totalWanted': 1000,
        'totalWantedDone': 500,
        'statusMessage': 'Downloading',
        'torrentFiles': [
          {'name': 'a.bin', 'length': 1000, 'downloadedBytes': 500},
        ],
      });

      final last = emitted.last;
      expect(last.fileSize, 1000);
      expect(last.downloadedBytes, 500);
      expect(last.torrentFiles, isNotNull);
      expect(last.totalFiles, 1);
      expect(last.completedFiles, 0);
    });

    test('empty-but-invalid torrent files keep prior state', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(onProgress: emitted.add, isTorrent: true);
      addTearDown(handler.dispose);

      await handler.handleWorkerProgress({
        'downloadedBytes': 0,
        'fileSize': 0,
        'totalWanted': 0,
        'statusMessage': 'Downloading',
        'torrentFiles': ['not-a-map'],
      });
      expect(emitted.last.torrentFiles, isNull);
    });
  });

  group('throttling', () {
    test('pending progress is emitted on dispose', () async {
      final emitted = <DownloadProgress>[];
      final handler =
          buildHandler(onProgress: emitted.add, interval: () => 100000);
      await handler.handleWorkerProgress({
        'downloadedBytes': 100,
        'fileSize': 1000,
        'statusMessage': 'Downloading',
      });
      expect(emitted, hasLength(1));

      await handler.handleWorkerProgress({
        'downloadedBytes': 200,
        'fileSize': 1000,
        'statusMessage': 'Downloading',
      });
      expect(emitted, hasLength(1), reason: 'throttled');

      handler.dispose();
      expect(emitted, hasLength(2));
      expect(emitted.last.downloadedBytes, 200);
    });

    test('throttle timer eventually flushes the pending progress', () {
      fakeAsync((async) {
        final emitted = <DownloadProgress>[];
        final handler =
            buildHandler(onProgress: emitted.add, interval: () => 1000);

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
        expect(emitted, hasLength(1));

        async.elapse(const Duration(milliseconds: 1100));
        async.flushMicrotasks();
        expect(emitted, hasLength(2));
        expect(emitted.last.downloadedBytes, 200);
        handler.dispose();
      });
    });
  });

  group('URL expiration', () {
    test('first two expirations are recoverable, third is terminal', () {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(onProgress: emitted.add);
      addTearDown(handler.dispose);

      handler.handleUrlExpired();
      expect(handler.urlExpireCountForTesting, 1);
      handler.handleUrlExpired();
      expect(handler.urlExpireCountForTesting, 2);

      expect(() => handler.handleUrlExpired(),
          throwsA(isA<DownloadIntegrityException>()));
      expect(emitted.last.cycleState, CycleState.failed);
    });

    test('a stale window resets the counter', () {
      final handler = buildHandler();
      addTearDown(handler.dispose);
      handler.urlExpireCountForTesting = 2;
      handler.urlExpireWindowStartForTesting =
          DateTime.now().subtract(const Duration(minutes: 10));
      handler.handleUrlExpired();
      expect(handler.urlExpireCountForTesting, 1);
    });
  });

  group('YouTube counterpart coordination', () {
    test('counterpart wait exceeding the budget emits updatingLinks', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(
        onProgress: emitted.add,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 100,
        ytCounterpartDownloadedBytes: 0,
      );
      addTearDown(handler.dispose);
      handler.counterpartWaitStartForTesting =
          DateTime.now().subtract(const Duration(minutes: 6));

      await expectLater(
        handler.handleWorkerProgress(
          {
            'downloadedBytes': 10,
            'fileSize': 100,
            'statusMessage': 'Downloading',
          },
          isCounterpartUnregistered: true,
        ),
        throwsA(isA<UrlExpiredException>()),
      );
      expect(
          emitted.any((p) => p.cycleState == CycleState.updatingLinks), isTrue);
    });

    test('counterpart done with self done transitions to merging', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(
        onProgress: emitted.add,
        ytStreamKind: YtStreamKind.video,
        lastDownloadedBytes: 100,
        lastFileSize: 100,
      );
      addTearDown(handler.dispose);

      await handler.handleWorkerProgress(
        {
          'downloadedBytes': 100,
          'fileSize': 100,
          'ytCounterpartSize': 100,
          'ytCounterpartDownloadedBytes': 100,
          'statusMessage': 'Downloading',
        },
        isCounterpartUnregistered: true,
      );
      expect(emitted.last.cycleState, CycleState.merging);
    });

    test('completion gate blocks completion until counterpart is done',
        () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(
        onProgress: emitted.add,
        ytStreamKind: YtStreamKind.video,
      );
      addTearDown(handler.dispose);

      await handler.handleWorkerProgress({
        'downloadedBytes': 100,
        'fileSize': 100,
        'cycleState': 'completed',
        'ytCounterpartSize': 100,
        'ytCounterpartDownloadedBytes': 50,
      });
      expect(emitted.last.cycleState, isNot(CycleState.completed));
    });

    test('counterpart override from live byte maps is applied', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(onProgress: emitted.add);
      addTearDown(handler.dispose);

      final taskIds = TimestampedLruMap<String, String>()..['task-1'] = 'cp-1';
      final live = TimestampedLruMap<String, int>()..['cp-1'] = 42;

      await handler.handleProgress(
        {
          'downloadedBytes': 10,
          'fileSize': 100,
          'statusMessage': 'Downloading'
        },
        ytCounterpartTaskIds: taskIds,
        ytLiveBytes: live,
      );
      expect(emitted.last.ytCounterpartDownloadedBytes, 42);
    });
  });

  group('adaptive threads', () {
    test('records a speed sample when enabled', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(onProgress: emitted.add);
      addTearDown(handler.dispose);
      final engine = HttpDownloadEngine();

      await handler.handleWorkerProgress(
        {
          'downloadedBytes': 100,
          'fileSize': 1000,
          'speed': 5.0,
          'statusMessage': 'Downloading',
        },
        adaptiveThreads: true,
        effectiveThreadCount: 4,
        httpEngine: engine,
      );
      expect(emitted, isNotEmpty);
    });
  });

  group('disposed guard', () {
    test('post-dispose worker progress is dropped', () async {
      final emitted = <DownloadProgress>[];
      final handler = buildHandler(onProgress: emitted.add);
      handler.dispose();
      await handler.handleWorkerProgress({
        'downloadedBytes': 1,
        'fileSize': 10,
        'statusMessage': 'Downloading',
      });
      expect(emitted, isEmpty);
    });
  });
}
