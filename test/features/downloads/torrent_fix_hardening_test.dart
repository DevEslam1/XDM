import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/engine/download_progress_handler.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal fake ITorrentService. `noSuchMethod` satisfies the rest of the
/// (large) interface; only members exercised by the tests are implemented.
class _FakeTorrentService implements ITorrentService {
  final Set<int> _alive = {};
  final Map<int, TorrentUpdateInfo> _stats = {};
  int pauseCalls = 0;
  bool autoRemoveOnPause = true;

  void addAlive(int id) => _alive.add(id);

  void setStats(int id, TorrentUpdateInfo info) => _stats[id] = info;

  @override
  bool get isSupported => true;
  @override
  bool get isInitialized => true;
  @override
  Future<void> get ready async {}
  @override
  ValueNotifier<bool> get isAvailable => ValueNotifier<bool>(true);
  @override
  Set<int> get activeTorrentIds => Set.unmodifiable(_alive);
  @override
  Map<int, TorrentUpdateInfo> get latestStats => Map.unmodifiable(_stats);

  @override
  bool isTorrentAlive(int id) => _alive.contains(id);

  @override
  Future<void> pauseTorrent(int id) async {
    pauseCalls++;
    if (autoRemoveOnPause) {
      _alive.remove(id);
    }
  }

  @override
  Future<void> forceStopTorrent(int id) async {
    pauseCalls++;
    if (autoRemoveOnPause) {
      _alive.remove(id);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TorrentSubscriptionRegistry.instance.clear();
  });

  tearDown(() {
    TorrentSubscriptionRegistry.instance.clear();
    DownloadEngine.isInBackground = false;
  });

  group('FIX-A: TorrentSubscriptionRegistry hard-stop on dispose', () {
    test('dispose cancels the subscription AND halts the native torrent', () {
      fakeAsync((async) {
        final controller = StreamController<int>();
        final sub = controller.stream.listen((_) {});
        final fake = _FakeTorrentService()..addAlive(7);
        final handler = TorrentDownloadHandler(torrentService: fake);

        TorrentSubscriptionRegistry.instance.register(7, handler, sub);
        expect(TorrentSubscriptionRegistry.instance.getSubscription(7),
            equals(sub));
        expect(TorrentSubscriptionRegistry.instance.activeCountForTesting,
            equals(1));

        TorrentSubscriptionRegistry.instance.dispose(7);
        async.flushMicrotasks();

        expect(TorrentSubscriptionRegistry.instance.getSubscription(7), isNull);
        expect(TorrentSubscriptionRegistry.instance.activeCountForTesting,
            equals(0));
        expect(fake.pauseCalls, greaterThanOrEqualTo(1));
        expect(fake.isTorrentAlive(7), isFalse);
      });
    });

    test('registry holds handler strongly (no WeakReference cleanup race)', () {
      final controller = StreamController<int>();
      final sub = controller.stream.listen((_) {});
      final handler =
          TorrentDownloadHandler(torrentService: _FakeTorrentService());

      TorrentSubscriptionRegistry.instance.register(101, handler, sub);
      expect(TorrentSubscriptionRegistry.instance.activeCountForTesting,
          equals(1));

      TorrentSubscriptionRegistry.instance.unregister(101, handler);
      expect(TorrentSubscriptionRegistry.instance.getSubscription(101), isNull);
      expect(TorrentSubscriptionRegistry.instance.activeCountForTesting,
          equals(0));

      sub.cancel();
      controller.close();
    });
  });

  group('FIX-A: haltTorrent verifies the native engine stopped', () {
    test('confirms pause and releases the handle on success', () async {
      final fake = _FakeTorrentService()..addAlive(5);
      final handler = TorrentDownloadHandler(torrentService: fake);

      await handler.haltTorrent(5);

      expect(fake.pauseCalls, greaterThanOrEqualTo(1));
      expect(fake.isTorrentAlive(5), isFalse);
      expect(handler.activeTorrentIds.contains(5), isFalse);
    });

    test(
        'retries up to 3 attempts, then releases the handle even if the '
        'engine never confirms', () async {
      final fake = _FakeTorrentService()..addAlive(9);
      fake.autoRemoveOnPause = false; // pause never stops the engine
      // Engine keeps "transmitting" so the pause verification never passes.
      fake.setStats(
        9,
        TorrentUpdateInfo(
          id: 9,
          name: 'stubborn.torrent',
          progress: 0.5,
          downloadRate: 100,
          uploadRate: 0,
          totalDone: 1024,
          totalWanted: 2048,
          totalWantedDone: 1024,
          hasMetadata: true,
          stateLabel: 'downloading',
        ),
      );
      final handler = TorrentDownloadHandler(torrentService: fake);

      await handler.haltTorrent(9);

      expect(fake.pauseCalls, greaterThanOrEqualTo(3));
      expect(fake.isTorrentAlive(9), isTrue);
      expect(handler.activeTorrentIds.contains(9), isFalse);
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('FIX-B: torrent progress delta trigger', () {
    test('emits on >=1MiB delta even inside the interval window', () async {
      DownloadEngine.isInBackground = true; // widen interval to 3s
      final emissions = <DownloadProgress>[];
      final handler = DownloadProgressHandler(
        taskId: 't1',
        onProgress: emissions.add,
        cancelToken: CancelToken(),
        resolvedFileName: 'file.bin',
        resolvedSupportsResume: true,
        ytStreamKind: null,
        ytCounterpartSize: null,
        ytCounterpartDownloadedBytes: null,
        isTorrent: true,
        getEffectiveIntervalMs: () => 500,
        lastDownloadedBytes: 0,
        lastFileSize: 10 * 1024 * 1024,
      );

      Map<String, dynamic> p(int done, [String? sm]) => {
            'downloadedBytes': done,
            'fileSize': 10 * 1024 * 1024,
            'speed': 1024.0,
            'statusMessage': sm ?? 'downloading',
            'cycleState': CycleState.downloading,
          };

      // Baseline: first call always emits.
      await handler.handleWorkerProgress(p(0));
      expect(emissions.length, equals(1));

      // Tiny delta within the window: throttled, no immediate emit.
      await handler.handleWorkerProgress(p(1000));
      expect(emissions.length, equals(1));

      // >=1MiB delta: emitted immediately despite the window.
      await handler.handleWorkerProgress(p(1024 * 1024 + 1));
      expect(emissions.length, equals(2));

      // State-label change also forces an emit.
      await handler
          .handleWorkerProgress(p(1024 * 1024 + 1, 'fetching metadata'));
      expect(emissions.length, equals(3));

      handler.dispose();
    });
  });
}
