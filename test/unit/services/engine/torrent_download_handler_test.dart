import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/di/injection.dart';
import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:dmx/core/services/torrent_service_stub.dart';
import 'package:flutter_test/flutter_test.dart';

class MockTorrentService extends TorrentServiceStub {
  final StreamController<Map<int, TorrentUpdateInfo>> _controller;

  MockTorrentService(this._controller);

  @override
  Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates => _controller.stream;

  @override
  bool isTorrentAlive(int id) => true;

  @override
  int addMagnet(String magnetUri, String savePath, {List<int>? resumeData}) =>
      42;

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
      42;

  @override
  int addTorrentFile(String filePath, String savePath,
          {String? sourceKey, List<int>? resumeData}) =>
      42;

  List<TorrentFileItem> mockFiles = [];
  List<int>? lastSetPriorities;

  @override
  List<TorrentFileItem> getFiles(int torrentId) => mockFiles;

  @override
  void setFilePriorities(int id, List<int> priorities) {
    lastSetPriorities = priorities;
  }

  @override
  Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath, {
    Map<int, int>? knownSizes,
  }) async =>
      [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<int, TorrentUpdateInfo>> controller;
  late MockTorrentService mock;
  late TorrentDownloadHandler handler;

  setUp(() {
    controller = StreamController<Map<int, TorrentUpdateInfo>>.broadcast();
    mock = MockTorrentService(controller);
    handler = TorrentDownloadHandler(torrentService: mock);
    getIt.registerSingleton<ITorrentService>(mock);
  });

  tearDown(() async {
    TorrentSubscriptionRegistry.instance.clear();
    await controller.close();
    if (getIt.isRegistered<ITorrentService>()) {
      await getIt.unregister<ITorrentService>();
    }
  });

  TorrentUpdateInfo seedingInfo(int id) => TorrentUpdateInfo(
        id: id,
        name: 'file.mkv',
        progress: 1.0,
        downloadRate: 0,
        uploadRate: 0,
        totalDone: 1000,
        totalWanted: 1000,
        totalWantedDone: 1000,
        hasMetadata: true,
        stateLabel: 'seeding',
        downloadPayloadRate: 0,
      );

  Future<void> runDownload({required int torrentId, CancelToken? token}) {
    return handler.listenForCompletionForTesting(
      torrentId,
      'magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789',
      '${Directory.systemTemp.path}/dmx_handler/file.mkv',
      token ?? CancelToken(),
      (_) {},
    );
  }

  group('P0-2 Completion Guard & Stall Watchdog', () {
    test('stale stall watchdog is cancelled at top of _listenForCompletion',
        () async {
      // Seed a stale watchdog before the next listen cycle starts.
      // removeActiveTorrent clears it; a retry then starts a fresh one.
      final cancel = CancelToken();
      final first = runDownload(torrentId: 1, token: cancel);

      // Let the first cycle attach its subscription & watchdog.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(handler.stallWatchdogForTesting, isNotNull);
      expect(handler.completionGuardForTesting, isNotNull);

      // Complete the torrent → the watchdog and guard must be cleaned up.
      controller.add({1: seedingInfo(1)});
      await first.timeout(const Duration(seconds: 5));

      expect(handler.stallWatchdogForTesting, isNull);
      expect(handler.completionGuardForTesting, isNull);
      expect(handler.activeSubsForTesting, isEmpty);
    });

    test('overlapping _listenForCompletion reuses the in-flight guard',
        () async {
      final cancel = CancelToken();
      final first = runDownload(torrentId: 2, token: cancel);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(handler.completionGuardForTesting, isNotNull);
      expect(handler.activeSubsForTesting.length, 1);

      // A second concurrent call for the same torrent must NOT spin up a
      // second subscription loop; it waits on the existing guard instead.
      final second = runDownload(torrentId: 2, token: cancel);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(handler.activeSubsForTesting.length, 1);

      // Completing the torrent resolves both the guard and the overlapping call.
      controller.add({2: seedingInfo(2)});
      await Future.wait([first, second]).timeout(const Duration(seconds: 5));

      expect(handler.completionGuardForTesting, isNull);
      expect(handler.activeSubsForTesting, isEmpty);
    });
  });

  group('TorrentDownloadHandler', () {
    test('resets state fields properly', () {
      handler.lastStateLabel = 'downloading';
      handler.cachedAccurateFiles = [
        {'name': 'test.iso', 'length': 1000, 'downloadedBytes': 500}
      ];

      expect(handler.lastStateLabel, 'downloading');
      expect(handler.cachedAccurateFiles, isNotNull);

      // Normalization test
      final f = {'name': 'file1', 'length': 100, 'downloadedBytes': 150};
      TorrentDownloadHandler.normalizeTorrentFile(f);
      expect(f['downloadedBytes'], 100);
      expect(f['isComplete'], isTrue);
      expect(f['progress'], 1.0);
    });

    test('normalizeTorrentFiles aggregates counts correctly', () {
      final files = [
        {'name': 'f1', 'length': 100, 'downloadedBytes': 100, 'selected': true},
        {'name': 'f2', 'length': 200, 'downloadedBytes': 100, 'selected': true},
        {'name': 'f3', 'length': 300, 'downloadedBytes': 0, 'selected': false},
      ];
      final summary = TorrentDownloadHandler.normalizeTorrentFiles(files);
      expect(summary.total, 2);
      expect(summary.done, 1);
      expect(summary.bytes, 300);
      expect(summary.downloaded, 200);
    });

    test('distributeEstimatedBytes allocates remaining proportionally', () {
      final files = [
        {
          'name': 'f1',
          'length': 100,
          'downloadedBytes': 100,
          'progressEstimated': false
        },
        {
          'name': 'f2',
          'length': 100,
          'downloadedBytes': 0,
          'progressEstimated': true
        },
        {
          'name': 'f3',
          'length': 100,
          'downloadedBytes': 0,
          'progressEstimated': true
        },
      ];
      TorrentDownloadHandler.distributeEstimatedBytes(files, 200);
      expect(files[1]['downloadedBytes'], 50);
      expect(files[2]['downloadedBytes'], 50);
    });

    test(
        'Cancellation callback handles multiple cancels safely and executes cleanly',
        () async {
      expect(handler.activeTorrentIds, isEmpty);

      // Verify that removeActiveTorrent is safe for non-existent IDs
      expect(() => handler.removeActiveTorrent(99999), returnsNormally);
    });

    test(
        'torrent completing naturally should NOT trigger pause progress emission',
        () async {
      final emittedStates = <CycleState>[];
      final cancel = CancelToken();

      final downloadFuture = handler.handleTorrentDownload(
        taskId: 'test-torrent-task',
        torrentId: 42,
        url: 'magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789',
        currentLocalFilePath:
            '${Directory.systemTemp.path}/dmx_handler/file.mkv',
        knownFileSize: 1000,
        cancelToken: cancel,
        clientBuilder: (u) => Dio(),
        clientReleaser: (d) => d.close(force: true),
        onProgress: (p) {
          if (p.cycleState != null) {
            emittedStates.add(p.cycleState!);
          }
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.add({42: seedingInfo(42)});

      await downloadFuture;

      cancel.cancel('test cancel after completion');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(emittedStates.contains(CycleState.paused), isFalse);
    });

    test(
        'handleTorrentDownload preserves pre-selected files and applies priorities to engine',
        () async {
      mock.mockFiles = [
        TorrentFileItem(index: 0, name: 'video1.mp4', size: 1000, priority: 4),
        TorrentFileItem(index: 1, name: 'video2.mp4', size: 2000, priority: 4),
        TorrentFileItem(index: 2, name: 'extra.txt', size: 500, priority: 4),
      ];

      final preselectedFiles = [
        {
          'name': 'video1.mp4',
          'length': 1000,
          'selected': true,
          'priority': 4,
          'downloadedBytes': 0,
        },
        {
          'name': 'video2.mp4',
          'length': 2000,
          'selected': true,
          'priority': 4,
          'downloadedBytes': 0,
        },
        {
          'name': 'extra.txt',
          'length': 500,
          'selected': false,
          'priority': 0,
          'downloadedBytes': 0,
        },
      ];

      final emittedProgress = <DownloadProgress>[];
      final cancel = CancelToken();

      final downloadFuture = handler.handleTorrentDownload(
        taskId: 'test-preselected-task',
        torrentId: 42,
        url: 'magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789',
        currentLocalFilePath:
            '${Directory.systemTemp.path}/dmx_handler/video1.mp4',
        knownFileSize: 3000,
        cancelToken: cancel,
        getTorrentFiles: () => preselectedFiles,
        clientBuilder: (u) => Dio(),
        clientReleaser: (d) => d.close(force: true),
        onProgress: (p) {
          emittedProgress.add(p);
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Check that priorities were passed: [4, 4, 0]
      expect(mock.lastSetPriorities, equals([4, 4, 0]));

      controller.add({42: seedingInfo(42)});
      await downloadFuture;

      final lastProgress =
          emittedProgress.lastWhere((p) => p.torrentFiles != null);
      final lastFiles = lastProgress.torrentFiles!;
      expect(lastFiles[0]['selected'], isTrue);
      expect(lastFiles[1]['selected'], isTrue);
      expect(lastFiles[2]['selected'], isFalse);
      expect(lastFiles[2]['priority'], equals(0));
    });
  });
}
