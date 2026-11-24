import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/domain/engine_types.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/fake_torrent_service.dart';

class _PayloadAdapter implements HttpClientAdapter {
  _PayloadAdapter(this.payload);
  final List<int> payload;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream<Uint8List>.fromIterable([Uint8List.fromList(payload)]),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/x-bittorrent'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ReturningFakeService extends FakeITorrentService {
  _ReturningFakeService(this.idToReturn);
  final int idToReturn;

  @override
  Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
    List<int>? resumeData,
  }) async =>
      idToReturn;

  @override
  bool isTorrentAlive(int id) => id == idToReturn;
}

Future<void> waitForSubscription(TorrentDownloadHandler handler) async {
  for (var i = 0; i < 300 && handler.activeSubsForTesting.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dmx_torrent_extra');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async => tmp.path,
    );
    TorrentSubscriptionRegistry.instance.clear();
  });

  tearDown(() async {
    TorrentSubscriptionRegistry.instance.clear();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('TorrentFileSnapshot', () {
    test('computeHash handles null/empty and is order-independent-ish', () {
      expect(TorrentFileSnapshot.computeHash(null), 0);
      expect(TorrentFileSnapshot.computeHash([]), 0);
      final h = TorrentFileSnapshot.computeHash([
        {'name': 'a', 'length': 1},
      ]);
      expect(h, isNot(0));
    });

    test('defensively copies and compares by content', () {
      final source = [
        {'name': 'a', 'length': 1, 'downloadedBytes': 0},
      ];
      final snap = TorrentFileSnapshot(source);
      source[0]['downloadedBytes'] = 99;
      source.add({'name': 'b'});
      expect(snap.files, hasLength(1));
      expect(snap.files[0]['downloadedBytes'], 0);

      final same = TorrentFileSnapshot(const [
        {'name': 'a', 'length': 1, 'downloadedBytes': 0},
      ]);
      expect(snap == same, isTrue);
      expect(snap.hashCode, same.hashCode);

      final different = TorrentFileSnapshot(const [
        {'name': 'a', 'length': 2, 'downloadedBytes': 0},
      ]);
      expect(snap == different, isFalse);
    });
  });

  group('TorrentRuntime', () {
    test('close marks closed and completes guards with an error', () {
      final rt = TorrentRuntime();
      final completion = Completer<void>()..future.catchError((_) {});
      final pause = Completer<void>()..future.catchError((_) {});
      rt.completionGuard = completion;
      rt.pauseCompleter = pause;

      rt.close();
      expect(rt.isClosed, isTrue);
      expect(completion.isCompleted, isTrue);
      expect(pause.isCompleted, isTrue);
      rt.close(); // idempotent
    });
  });

  group('TorrentSubscriptionRegistry', () {
    test('register/get/unregister lifecycle', () {
      final handler =
          TorrentDownloadHandler(torrentService: FakeITorrentService());
      addTearDown(handler.dispose);
      final ctrl = StreamController<int>();
      addTearDown(ctrl.close);
      final sub = ctrl.stream.listen((_) {});

      final registry = TorrentSubscriptionRegistry.instance;
      registry.register(1, handler, sub);
      expect(registry.getSubscription(1), same(sub));
      expect(registry.activeCountForTesting, 1);
      expect(registry.subsForHandler(handler), contains(1));

      registry.unregister(1, handler);
      expect(registry.getSubscription(1), isNull);
    });

    test('re-registration cancels the previous subscription', () async {
      final handler =
          TorrentDownloadHandler(torrentService: FakeITorrentService());
      addTearDown(handler.dispose);
      final ctrl1 = StreamController<int>();
      final ctrl2 = StreamController<int>();
      final sub1 = ctrl1.stream.listen((_) {});
      final sub2 = ctrl2.stream.listen((_) {});

      final registry = TorrentSubscriptionRegistry.instance;
      registry.register(5, handler, sub1);
      registry.register(5, handler, sub2);
      await Future<void>.delayed(Duration.zero);
      expect(registry.getSubscription(5), same(sub2));

      await ctrl1.close();
      await ctrl2.close();
      registry.clear();
    });

    test('cancelCurrentFor removes and cancels only the owning handler',
        () async {
      final handlerA =
          TorrentDownloadHandler(torrentService: FakeITorrentService());
      final handlerB =
          TorrentDownloadHandler(torrentService: FakeITorrentService());
      addTearDown(handlerA.dispose);
      addTearDown(handlerB.dispose);
      final ctrl = StreamController<int>();
      addTearDown(ctrl.close);
      final sub = ctrl.stream.listen((_) {});

      final registry = TorrentSubscriptionRegistry.instance;
      registry.register(7, handlerA, sub);
      await registry.cancelCurrentFor(7, handlerB);
      expect(registry.getSubscription(7), same(sub), reason: 'wrong owner');
      await registry.cancelCurrentFor(7, handlerA);
      expect(registry.getSubscription(7), isNull);
    });

    test('cleanupStale removes ids not in the active set', () {
      final handler =
          TorrentDownloadHandler(torrentService: FakeITorrentService());
      addTearDown(handler.dispose);
      final ctrl = StreamController<int>();
      addTearDown(ctrl.close);
      final sub = ctrl.stream.listen((_) {});

      final registry = TorrentSubscriptionRegistry.instance;
      registry.register(11, handler, sub);
      registry.cleanupStale(<int>{});
      expect(registry.getSubscription(11), isNull);
    });

    test('disposeAsync and dispose remove the entry', () async {
      final handler =
          TorrentDownloadHandler(torrentService: FakeITorrentService());
      addTearDown(handler.dispose);
      final registry = TorrentSubscriptionRegistry.instance;

      final ctrl1 = StreamController<int>();
      addTearDown(ctrl1.close);
      registry.register(21, handler, ctrl1.stream.listen((_) {}));
      await registry.disposeAsync(21);
      expect(registry.getSubscription(21), isNull);

      final ctrl2 = StreamController<int>();
      addTearDown(ctrl2.close);
      registry.register(22, handler, ctrl2.stream.listen((_) {}));
      registry.dispose(22);
      expect(registry.getSubscription(22), isNull);
    });

    test('unregisterAll removes every subscription for a handler', () {
      final handler =
          TorrentDownloadHandler(torrentService: FakeITorrentService());
      addTearDown(handler.dispose);
      final registry = TorrentSubscriptionRegistry.instance;
      final ctrl1 = StreamController<int>();
      final ctrl2 = StreamController<int>();
      addTearDown(ctrl1.close);
      addTearDown(ctrl2.close);
      registry.register(31, handler, ctrl1.stream.listen((_) {}));
      registry.register(32, handler, ctrl2.stream.listen((_) {}));
      registry.unregisterAll(handler);
      expect(registry.activeCountForTesting, 0);
    });

    test('evicts oldest entries once capacity is exceeded', () {
      final handler =
          TorrentDownloadHandler(torrentService: FakeITorrentService());
      addTearDown(handler.dispose);
      final registry = TorrentSubscriptionRegistry.instance;
      final controllers = <StreamController<int>>[];
      for (var i = 0; i < 105; i++) {
        final c = StreamController<int>();
        controllers.add(c);
        registry.register(i, handler, c.stream.listen((_) {}));
      }
      expect(registry.activeCountForTesting, lessThanOrEqualTo(100));
      for (final c in controllers) {
        c.close();
      }
      registry.clear();
    });
  });

  group('static helpers', () {
    test('inferPauseReasonForTesting returns explicit reason', () {
      expect(
          TorrentDownloadHandler.inferPauseReasonForTesting(
              PauseReason.diskFull),
          PauseReason.diskFull);
    });

    test('inferPauseReasonForTesting defaults to userRequested', () {
      expect(TorrentDownloadHandler.inferPauseReasonForTesting(),
          PauseReason.userRequested);
    });

    test('computeAdaptiveSyncInterval covers every band', () {
      expect(TorrentDownloadHandler.computeAdaptiveSyncInterval(10),
          const Duration(seconds: 5));
      expect(TorrentDownloadHandler.computeAdaptiveSyncInterval(200),
          const Duration(seconds: 15));
      expect(TorrentDownloadHandler.computeAdaptiveSyncInterval(2000),
          const Duration(seconds: 30));
      expect(TorrentDownloadHandler.computeAdaptiveSyncInterval(6000),
          const Duration(seconds: 45));
      expect(TorrentDownloadHandler.computeAdaptiveSyncInterval(20000),
          const Duration(seconds: 120));

      expect(
          TorrentDownloadHandler.computeAdaptiveSyncInterval(10,
              inBackground: true),
          const Duration(seconds: 90));
      expect(
          TorrentDownloadHandler.computeAdaptiveSyncInterval(2000,
              inBackground: true),
          const Duration(minutes: 3));
      expect(
          TorrentDownloadHandler.computeAdaptiveSyncInterval(6000,
              inBackground: true),
          const Duration(minutes: 5));
    });

    test('shouldSkipPerFileSync only skips huge background sets', () {
      expect(TorrentDownloadHandler.shouldSkipPerFileSync(100), isFalse);
      expect(
          TorrentDownloadHandler.shouldSkipPerFileSync(6000,
              inBackground: true),
          isTrue);
      expect(
          TorrentDownloadHandler.shouldSkipPerFileSync(6000,
              inBackground: false),
          isFalse);
    });

    test('normalizeTorrentFile/selected/normalizeTorrentFiles delegate', () {
      final file = TorrentDownloadHandler.normalizeTorrentFile(
          {'name': 'a', 'length': 10, 'downloadedBytes': 5});
      expect(file['name'], 'a');
      expect(TorrentDownloadHandler.isTorrentFileSelected({'selected': false}),
          isFalse);

      final summary = TorrentDownloadHandler.normalizeTorrentFiles([
        {'name': 'a', 'length': 10, 'downloadedBytes': 10},
      ]);
      expect(summary.total, 1);
      expect(summary.done, 1);
      expect(summary.bytes, 10);
      expect(summary.downloaded, 10);
    });

    test('file progress estimators update rows', () {
      final files = [
        {'name': 'a', 'length': 100, 'downloadedBytes': 0},
        {'name': 'b', 'length': 100, 'downloadedBytes': 0},
      ];
      TorrentDownloadHandler.updateFilesWithNativeProgress(files, 0.5, 100);
      expect(files, isNotEmpty);

      TorrentDownloadHandler.distributeEstimatedBytesSequential(files, 100);
      TorrentDownloadHandler.distributeEstimatedBytes(files, 100);
    });
  });

  group('haltTorrent', () {
    test('no-metadata torrent is force stopped', () async {
      final service = FakeITorrentService();
      service.seedTorrent(id: 5, name: 'x', totalWanted: 0, hasMetadata: false);
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);

      await handler.haltTorrent(5);
      expect(service.forceStoppedTorrents, contains(5));
    });

    test('already-dead torrent is removed from active ids', () async {
      final service = FakeITorrentService();
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);
      await handler.haltTorrent(999);
      expect(handler.activeTorrentIds, isNot(contains(999)));
    });

    test('metadata present + paused confirms graceful pause', () async {
      final service = FakeITorrentService();
      service.seedTorrent(id: 6, name: 'x', totalWanted: 100, isPaused: true);
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);

      await handler.haltTorrent(6);
      expect(service.forceStoppedTorrents, isNot(contains(6)));
    });
  });

  group('handleTorrentDownload', () {
    test('unsupported scheme throws TorrentSourceException', () async {
      final service = FakeITorrentService();
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);

      await expectLater(
        handler.handleTorrentDownload(
          taskId: 't',
          url: 'weird://x',
          currentLocalFilePath: '${tmp.path}/out.bin',
          knownFileSize: 10,
          cancelToken: CancelToken(),
          onProgress: (_) {},
          clientBuilder: (_) => Dio(),
          clientReleaser: (_) {},
        ),
        throwsA(isA<TorrentSourceException>()),
      );
    });

    test('rejected torrent id emits failure and throws', () async {
      final service = _ReturningFakeService(-1);
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);
      final progress = <DownloadProgress>[];

      await expectLater(
        handler.handleTorrentDownload(
          taskId: 't',
          url: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
          currentLocalFilePath: '${tmp.path}/out.bin',
          knownFileSize: 10,
          cancelToken: CancelToken(),
          onProgress: progress.add,
          clientBuilder: (_) => Dio(),
          clientReleaser: (_) {},
        ),
        throwsA(isA<DioException>()),
      );
      expect(progress.any((p) => p.cycleState == CycleState.failed), isTrue);
    });

    test('magnet download pauses cleanly when cancelled', () async {
      final service = _ReturningFakeService(100);
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);
      final cancel = CancelToken();
      final progress = <DownloadProgress>[];

      final future = handler.handleTorrentDownload(
        taskId: 't',
        url: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        currentLocalFilePath: '${tmp.path}/out.bin',
        knownFileSize: 10,
        cancelToken: cancel,
        onProgress: progress.add,
        clientBuilder: (_) => Dio(),
        clientReleaser: (_) {},
        pauseReason: PauseReason.userRequested,
      );

      await waitForSubscription(handler);
      cancel.cancel('pause:user');

      await expectLater(future, throwsA(isA<DioException>()));
      for (var i = 0;
          i < 100 && !progress.any((p) => p.cycleState == CycleState.paused);
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(progress.any((p) => p.cycleState == CycleState.paused), isTrue);
    });

    test('stale handle is re-added then pauses on cancel', () async {
      final service = _ReturningFakeService(200);
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);
      final cancel = CancelToken();

      final future = handler.handleTorrentDownload(
        taskId: 't',
        url: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        currentLocalFilePath: '${tmp.path}/out.bin',
        knownFileSize: 10,
        torrentId: 999,
        cancelToken: cancel,
        onProgress: (_) {},
        clientBuilder: (_) => Dio(),
        clientReleaser: (_) {},
        pauseReason: PauseReason.userRequested,
      );

      await waitForSubscription(handler);
      cancel.cancel('pause:user');
      await expectLater(future, throwsA(isA<DioException>()));
    });

    test('valid bencoded http torrent is added then paused', () async {
      final service = _ReturningFakeService(300);
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);
      final cancel = CancelToken();
      final payload = utf8.encode('d4:infod4:name4:teste4:name4:testee');

      final future = handler.handleTorrentDownload(
        taskId: 't',
        url: 'http://example.com/good.torrent',
        currentLocalFilePath: '${tmp.path}/out.bin',
        knownFileSize: 10,
        cancelToken: cancel,
        onProgress: (_) {},
        clientBuilder: (_) {
          final dio = Dio();
          dio.httpClientAdapter = _PayloadAdapter(payload);
          return dio;
        },
        clientReleaser: (_) {},
        pauseReason: PauseReason.userRequested,
      );

      await waitForSubscription(handler);
      cancel.cancel('pause:user');
      await expectLater(future, throwsA(isA<DioException>()));
    });
  });

  group('listenForCompletion', () {
    test('completes when the torrent reports finished', () async {
      final service = FakeITorrentService();
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);

      final future = handler.listenForCompletionForTesting(
        1,
        'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        '${tmp.path}/out.bin',
        CancelToken(),
        (_) {},
        getTorrentFiles: () => [
          {'name': 'a', 'length': 1000, 'downloadedBytes': 1000},
        ],
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      service.seedTorrent(
        id: 1,
        name: 'x',
        totalWanted: 1000,
        totalWantedDone: 1000,
        progress: 1.0,
        isFinished: true,
      );

      await future.timeout(const Duration(seconds: 3));
    });

    test('cancellation rejects the completion future', () async {
      final service = FakeITorrentService();
      service.seedTorrent(id: 2, name: 'x', totalWanted: 1000);
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);
      final cancel = CancelToken();

      final future = handler.listenForCompletionForTesting(
        2,
        'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        '${tmp.path}/out.bin',
        cancel,
        (_) {},
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancel.cancel('pause:user');
      await expectLater(future, throwsA(isA<DioException>()));
    });

    test('removeActiveTorrent closes the runtime', () async {
      final service = FakeITorrentService();
      service.seedTorrent(id: 3, name: 'x', totalWanted: 1000);
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);

      final future = handler.listenForCompletionForTesting(
        3,
        'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        '${tmp.path}/out.bin',
        CancelToken(),
        (_) {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(handler.getRuntimeForTesting(3), isNotNull);
      handler.removeActiveTorrent(3);
      expect(handler.getRuntimeForTesting(3), isNull);
      await future.timeout(const Duration(seconds: 2));
    });
  });
}
