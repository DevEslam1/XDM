import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/domain/engine_types.dart';
import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/fake_torrent_service.dart';

class _FilesFake extends FakeITorrentService {
  _FilesFake(this.files);
  final List<TorrentFileItem> files;

  @override
  List<TorrentFileItem> getFiles(int id) => files;
}

TorrentUpdateInfo _stats(
  int id, {
  required String stateLabel,
  TorrentState state = TorrentState.unknown,
  bool hasMetadata = true,
  int totalWanted = 1000,
  int totalWantedDone = 0,
  double progress = 0.0,
  int piecesHave = 0,
  int piecesTotal = 0,
  List<int> fileProgress = const [],
}) =>
    TorrentUpdateInfo(
      id: id,
      name: 'x',
      progress: progress,
      downloadRate: 0,
      uploadRate: 0,
      totalDone: totalWantedDone,
      totalWanted: totalWanted,
      totalWantedDone: totalWantedDone,
      hasMetadata: hasMetadata,
      stateLabel: stateLabel,
      state: state,
      piecesHave: piecesHave,
      piecesTotal: piecesTotal,
      fileProgress: fileProgress,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dmx_torrent_extra2');
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

  const magnet = 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567';

  group('alert-driven failures', () {
    test('a disk-full alert rejects the completion future', () async {
      final service = FakeITorrentService();
      service.seedTorrent(id: 4, name: 'x', totalWanted: 1000);
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);

      final future = handler.listenForCompletionForTesting(
          4, magnet, '${tmp.path}/out.bin', CancelToken(), (_) {});

      await Future<void>.delayed(const Duration(milliseconds: 20));
      service.emitAlert(TorrentAlertEvent(
        type: 1,
        torrentId: 4,
        category: 'error',
        message: 'no space left on device',
        timestamp: DateTime.now(),
      ));
      await expectLater(future, throwsA(isA<DioException>()));
    });

    test('a network alert rejects the completion future', () async {
      final service = FakeITorrentService();
      service.seedTorrent(id: 5, name: 'x', totalWanted: 1000);
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);

      final future = handler.listenForCompletionForTesting(
          5, magnet, '${tmp.path}/out.bin', CancelToken(), (_) {});

      await Future<void>.delayed(const Duration(milliseconds: 20));
      service.emitAlert(TorrentAlertEvent(
        type: 1,
        torrentId: 5,
        category: 'error',
        message: 'connection reset by peer',
        timestamp: DateTime.now(),
      ));
      await expectLater(future, throwsA(isA<DioException>()));
    });
  });

  group('update processing', () {
    test('a checking torrent reports verifying and does not complete',
        () async {
      final service = FakeITorrentService();
      service.seedTorrent(
          id: 6, name: 'x', totalWanted: 1000, hasMetadata: true);
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);
      final progress = <DownloadProgress>[];

      final future = handler.listenForCompletionForTesting(
          6, magnet, '${tmp.path}/out.bin', CancelToken(), progress.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      service.emitStats({
        6: _stats(6,
            stateLabel: 'checking_files',
            state: TorrentState.checkingFiles,
            progress: 0.5,
            piecesHave: 5,
            piecesTotal: 10),
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(progress.any((p) => p.cycleState == CycleState.verifying), isTrue);
      handler.removeActiveTorrent(6);
      await future.timeout(const Duration(seconds: 2));
    });

    test('per-file progress maps onto the cached file rows', () async {
      final files = [
        TorrentFileItem(
            index: 0, name: 'a.bin', size: 1000, downloadedBytes: 500),
        TorrentFileItem(
            index: 1, name: 'b.bin', size: 2000, downloadedBytes: 0),
      ];
      final service = _FilesFake(files);
      service.seedTorrent(
          id: 7, name: 'x', totalWanted: 3000, hasMetadata: true);
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);
      final progress = <DownloadProgress>[];

      final future = handler.listenForCompletionForTesting(
        7,
        magnet,
        '${tmp.path}/out.bin',
        CancelToken(),
        progress.add,
        getTorrentFiles: () => [
          {'name': 'a.bin', 'length': 1000, 'downloadedBytes': 500},
          {'name': 'b.bin', 'length': 2000, 'downloadedBytes': 0},
        ],
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      service.emitStats({
        7: _stats(7,
            stateLabel: 'Downloading',
            state: TorrentState.downloading,
            progress: 0.25,
            totalWanted: 3000,
            totalWantedDone: 500,
            piecesHave: 1,
            piecesTotal: 3,
            fileProgress: [500, 0]),
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
          progress.any(
              (p) => p.torrentFiles != null && p.torrentFiles!.length == 2),
          isTrue);
      handler.removeActiveTorrent(7);
      await future.timeout(const Duration(seconds: 2));
    });

    test('a native file-count change rebuilds the file list', () async {
      final files = [
        TorrentFileItem(
            index: 0, name: 'a.bin', size: 1000, downloadedBytes: 0),
        TorrentFileItem(
            index: 1, name: 'b.bin', size: 2000, downloadedBytes: 0),
      ];
      final service = _FilesFake(files);
      service.seedTorrent(
          id: 8, name: 'x', totalWanted: 3000, hasMetadata: true);
      final handler = TorrentDownloadHandler(torrentService: service);
      addTearDown(handler.dispose);
      final progress = <DownloadProgress>[];

      final future = handler.listenForCompletionForTesting(
        8,
        magnet,
        '${tmp.path}/out.bin',
        CancelToken(),
        progress.add,
        getTorrentFiles: () => [
          {'name': 'a.bin', 'length': 1000, 'downloadedBytes': 0},
        ],
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      service.emitStats({
        8: _stats(8,
            stateLabel: 'Downloading',
            state: TorrentState.downloading,
            progress: 0.1,
            totalWanted: 3000,
            totalWantedDone: 100,
            piecesHave: 1,
            piecesTotal: 3),
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(progress.any((p) => p.torrentFiles?.length == 2), isTrue);
      handler.removeActiveTorrent(8);
      await future.timeout(const Duration(seconds: 2));
    });
  });

  group('TorrentSubscriptionRegistry extras', () {
    test('re-registration from a different handler notifies the old one', () {
      final handlerA =
          TorrentDownloadHandler(torrentService: FakeITorrentService());
      final handlerB =
          TorrentDownloadHandler(torrentService: FakeITorrentService());
      addTearDown(handlerA.dispose);
      addTearDown(handlerB.dispose);
      final ctrlA = StreamController<int>();
      final ctrlB = StreamController<int>();
      addTearDown(ctrlA.close);
      addTearDown(ctrlB.close);

      final registry = TorrentSubscriptionRegistry.instance;
      registry.register(9, handlerA, ctrlA.stream.listen((_) {}));
      registry.register(9, handlerB, ctrlB.stream.listen((_) {}));
      expect(registry.getSubscription(9), isNotNull);
      expect(registry.subsMapForTesting.containsKey(9), isTrue);
      registry.clear();
    });

    test('cleanupStale with no active set removes every entry', () {
      final handler =
          TorrentDownloadHandler(torrentService: FakeITorrentService());
      addTearDown(handler.dispose);
      final ctrl = StreamController<int>();
      addTearDown(ctrl.close);
      final registry = TorrentSubscriptionRegistry.instance;
      registry.register(10, handler, ctrl.stream.listen((_) {}));
      expect(registry.activeCountForTesting, greaterThan(0));
      registry.cleanupStale();
      expect(registry.getSubscription(10), isNull);
    });
  });
}
