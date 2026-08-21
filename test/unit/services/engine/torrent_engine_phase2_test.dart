import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/di/injection.dart';
import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:dmx/core/services/torrent_models.dart';
import 'package:dmx/core/services/torrent_service_stub.dart';
import 'package:flutter_test/flutter_test.dart';

class MockPhase2TorrentService extends TorrentServiceStub {
  final StreamController<Map<int, TorrentUpdateInfo>> _controller;
  bool alive = true;
  bool forceStopped = false;

  MockPhase2TorrentService(this._controller);

  @override
  Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates => _controller.stream;

  @override
  bool isTorrentAlive(int id) => alive;

  @override
  Future<void> pauseTorrent(int id) async {}

  @override
  Future<void> resumeTorrent(int id) async {}

  @override
  Future<void> forceStopTorrent(int id) async {
    forceStopped = true;
    alive = false;
  }

  @override
  Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  ) async =>
      [];

  @override
  List<TorrentFileItem> getFiles(int torrentId) => [
        TorrentFileItem(
          index: 0,
          name: 'movie.mp4',
          size: 1000000,
          downloadedBytes: 500000,
        ),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<int, TorrentUpdateInfo>> controller;
  late MockPhase2TorrentService mock;
  late TorrentDownloadHandler handler;

  setUp(() {
    controller = StreamController<Map<int, TorrentUpdateInfo>>.broadcast();
    mock = MockPhase2TorrentService(controller);
    handler = TorrentDownloadHandler(torrentService: mock);
    if (!getIt.isRegistered<ITorrentService>()) {
      getIt.registerSingleton<ITorrentService>(mock);
    }
  });

  tearDown(() async {
    TorrentSubscriptionRegistry.instance.clear();
    await controller.close();
    if (getIt.isRegistered<ITorrentService>()) {
      await getIt.unregister<ITorrentService>();
    }
  });

  test('TorrentFileSnapshot computes deterministic hash and equality', () {
    final files1 = [
      {'name': 'f1.txt', 'length': 100, 'downloadedBytes': 50, 'selected': true, 'priority': 4, 'isComplete': false},
      {'name': 'f2.txt', 'length': 200, 'downloadedBytes': 200, 'selected': true, 'priority': 4, 'isComplete': true},
    ];
    final files2 = [
      {'name': 'f1.txt', 'length': 100, 'downloadedBytes': 50, 'selected': true, 'priority': 4, 'isComplete': false},
      {'name': 'f2.txt', 'length': 200, 'downloadedBytes': 200, 'selected': true, 'priority': 4, 'isComplete': true},
    ];
    final files3 = [
      {'name': 'f1.txt', 'length': 100, 'downloadedBytes': 70, 'selected': true, 'priority': 4, 'isComplete': false},
      {'name': 'f2.txt', 'length': 200, 'downloadedBytes': 200, 'selected': true, 'priority': 4, 'isComplete': true},
    ];

    final snap1 = TorrentFileSnapshot(files1);
    final snap2 = TorrentFileSnapshot(files2);
    final snap3 = TorrentFileSnapshot(files3);

    expect(snap1.hash, equals(snap2.hash));
    expect(snap1, equals(snap2));
    expect(snap1.hash, isNot(equals(snap3.hash)));
    expect(snap1, isNot(equals(snap3)));
  });

  test('Stalled -> recovery transition emits retrying state', () async {
    final progressEmissions = <DownloadProgress>[];
    final cancel = CancelToken();

    final future = handler.listenForCompletionForTesting(
      10,
      'magnet:?xt=urn:btih:dummy',
      '${Directory.systemTemp.path}/file.mkv',
      cancel,
      (p) => progressEmissions.add(p),
      knownFileSize: 1000000,
    );

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // Initial downloading update
    controller.add({
      10: TorrentUpdateInfo(
        id: 10,
        name: 'movie.mp4',
        progress: 0.5,
        downloadRate: 1000,
        uploadRate: 0,
        totalDone: 500000,
        totalWanted: 1000000,
        totalWantedDone: 500000,
        hasMetadata: true,
        stateLabel: 'downloading',
        downloadPayloadRate: 1000,
        piecesHave: 50,
        piecesTotal: 100,
      ),
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Stalled update
    handler.lastStateLabel = 'stalled';
    await Future<void>.delayed(const Duration(milliseconds: 600));

    // Recovery update
    controller.add({
      10: TorrentUpdateInfo(
        id: 10,
        name: 'movie.mp4',
        progress: 0.6,
        downloadRate: 2000,
        uploadRate: 0,
        totalDone: 600000,
        totalWanted: 1000000,
        totalWantedDone: 600000,
        hasMetadata: true,
        stateLabel: 'downloading',
        downloadPayloadRate: 2000,
        piecesHave: 60,
        piecesTotal: 100,
      ),
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final retryingEmissions = progressEmissions.where((p) => p.cycleState == CycleState.retrying);
    expect(retryingEmissions, isNotEmpty);

    // Complete
    controller.add({
      10: TorrentUpdateInfo(
        id: 10,
        name: 'movie.mp4',
        progress: 1.0,
        downloadRate: 0,
        uploadRate: 0,
        totalDone: 1000000,
        totalWanted: 1000000,
        totalWantedDone: 1000000,
        hasMetadata: true,
        stateLabel: 'seeding',
        downloadPayloadRate: 0,
        piecesHave: 100,
        piecesTotal: 100,
      ),
    });

    await future.timeout(const Duration(seconds: 5));
  });

  test('Aliveness loss mid-download terminates with DioException', () async {
    final cancel = CancelToken();

    final future = handler.listenForCompletionForTesting(
      20,
      'magnet:?xt=urn:btih:dummy2',
      '${Directory.systemTemp.path}/file2.mkv',
      cancel,
      (_) {},
      knownFileSize: 1000000,
    );

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // Initial update
    controller.add({
      20: TorrentUpdateInfo(
        id: 20,
        name: 'movie2.mp4',
        progress: 0.1,
        downloadRate: 1000,
        uploadRate: 0,
        totalDone: 100000,
        totalWanted: 1000000,
        totalWantedDone: 100000,
        hasMetadata: true,
        stateLabel: 'downloading',
        downloadPayloadRate: 1000,
      ),
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Torrent handle lost
    mock.alive = false;
    controller.add({}); // empty map

    await expectLater(
      future.timeout(const Duration(seconds: 5)),
      throwsA(isA<DioException>()),
    );
  });

  test('Pause under load handles 100 rapid concurrent updates gracefully', () async {
    final cancel = CancelToken();
    final emissions = <DownloadProgress>[];

    final future = handler.listenForCompletionForTesting(
      30,
      'magnet:?xt=urn:btih:dummy3',
      '${Directory.systemTemp.path}/file3.mkv',
      cancel,
      (p) => emissions.add(p),
      knownFileSize: 1000000,
    );

    await Future<void>.delayed(Duration.zero);

    // Flood with 100 rapid updates
    for (int i = 0; i < 100; i++) {
      controller.add({
        30: TorrentUpdateInfo(
          id: 30,
          name: 'movie3.mp4',
          progress: i / 100.0,
          downloadRate: 1000 + i * 10,
          uploadRate: 0,
          totalDone: i * 10000,
          totalWanted: 1000000,
          totalWantedDone: i * 10000,
          hasMetadata: true,
          stateLabel: 'downloading',
          downloadPayloadRate: 1000 + i * 10,
          piecesHave: i,
          piecesTotal: 100,
        ),
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Cancel while updates are firing
    cancel.cancel('pause');

    // Completer was cancelled
    try {
      await future.timeout(const Duration(seconds: 5));
    } catch (e) {
      expect(e, isA<DioException>());
    }

    expect(emissions, isNotEmpty);
  });
}
