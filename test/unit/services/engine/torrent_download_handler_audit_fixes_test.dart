import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/di/injection.dart';
import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:dmx/core/services/torrent_service_stub.dart';
import 'package:flutter_test/flutter_test.dart';

class AuditMockTorrentService extends TorrentServiceStub {
  final StreamController<Map<int, TorrentUpdateInfo>> controller =
      StreamController<Map<int, TorrentUpdateInfo>>.broadcast();

  final List<int> removedTorrents = [];
  final List<int> forceStoppedTorrents = [];
  final List<int> pausedTorrents = [];
  final Map<String, int> sourceIdMap = {};
  bool alive = true;
  bool supportsResume = true;
  Completer<int>? pendingMetadataCompleter;

  @override
  Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates => controller.stream;

  @override
  bool isTorrentAlive(int id) => alive;

  @override
  int? idForSource(String source) => sourceIdMap[source];

  @override
  bool get resumeDataSupported => supportsResume;

  @override
  void removeTorrent(int id,
      {bool deleteFiles = false, bool deleteResumeData = false}) {
    removedTorrents.add(id);
    alive = false;
  }

  @override
  int addMagnet(String magnetUri, String savePath, {List<int>? resumeData}) {
    sourceIdMap[magnetUri] = 101;
    return 101;
  }

  @override
  Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
    List<int>? resumeData,
  }) async {
    sourceIdMap[magnetUri] = 101;
    if (pendingMetadataCompleter != null) {
      return pendingMetadataCompleter!.future;
    }
    return 101;
  }

  @override
  int addTorrentFile(String filePath, String savePath,
      {String? sourceKey, List<int>? resumeData}) {
    sourceIdMap[filePath] = 202;
    if (sourceKey != null) sourceIdMap[sourceKey] = 202;
    return 202;
  }

  @override
  Future<void> pauseTorrent(int id) async {
    pausedTorrents.add(id);
  }

  @override
  Future<void> forceStopTorrent(int id) async {
    forceStoppedTorrents.add(id);
    alive = false;
  }

  @override
  List<TorrentFileItem> getFiles(int torrentId) => [
        TorrentFileItem(index: 0, name: 'f1', size: 100, priority: 4),
      ];

  @override
  Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  ) async =>
      [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AuditMockTorrentService mockService;
  late TorrentDownloadHandler handler;

  setUp(() {
    mockService = AuditMockTorrentService();
    handler = TorrentDownloadHandler(torrentService: mockService);
    if (getIt.isRegistered<ITorrentService>()) {
      getIt.unregister<ITorrentService>();
    }
    getIt.registerSingleton<ITorrentService>(mockService);
  });

  tearDown(() async {
    TorrentSubscriptionRegistry.instance.clear();
    await mockService.controller.close();
    if (getIt.isRegistered<ITorrentService>()) {
      await getIt.unregister<ITorrentService>();
    }
  });

  group('Torrent Audit Fixes (C1 - C4)', () {
    test(
        'C1: Magnet cancel race removes assigned torrent handle via idForSource',
        () async {
      mockService.pendingMetadataCompleter = Completer<int>();
      final cancelToken = CancelToken();
      const url =
          'magnet:?xt=urn:btih:audit1010101010101010101010101010101010101';

      final downloadFuture = handler.handleTorrentDownload(
        taskId: 'task-c1',
        url: url,
        currentLocalFilePath: '${Directory.systemTemp.path}/dmx_audit/file.bin',
        knownFileSize: 0,
        cancelToken: cancelToken,
        clientBuilder: (u) => Dio(),
        clientReleaser: (d) => d.close(force: true),
        onProgress: (_) {},
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancelToken.cancel('User cancelled magnet fetch');

      await expectLater(
        downloadFuture,
        throwsA(isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        )),
      );

      // Verify safe cleanup was invoked with the ID assigned for source
      expect(mockService.removedTorrents, contains(101));
    });

    test(
        'C1: Reverse race - metadata resolves after cancelToken fired cleans up handle',
        () async {
      final completer = Completer<int>();
      mockService.pendingMetadataCompleter = completer;
      final cancelToken = CancelToken();
      const url =
          'magnet:?xt=urn:btih:audit_rev101010101010101010101010101010101';

      final downloadFuture = handler.handleTorrentDownload(
        taskId: 'task-c1-rev',
        url: url,
        currentLocalFilePath: '${Directory.systemTemp.path}/dmx_audit/file.bin',
        knownFileSize: 0,
        cancelToken: cancelToken,
        clientBuilder: (u) => Dio(),
        clientReleaser: (d) => d.close(force: true),
        onProgress: (_) {},
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancelToken.cancel('User cancelled');

      // Now resolve metadata after cancel already won
      completer.complete(101);

      await expectLater(downloadFuture, throwsA(isA<DioException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(mockService.removedTorrents, contains(101));
    });

    test(
        'C2: Post-add exception removes torrent from engine and emits failed progress',
        () async {
      final cancelToken = CancelToken();
      final emittedProgress = <DownloadProgress>[];
      final url = 'file://${Directory.systemTemp.path}/dmx_audit/test.torrent';

      int callCount = 0;
      final downloadFuture = handler.handleTorrentDownload(
        taskId: 'task-c2',
        url: url,
        currentLocalFilePath: '${Directory.systemTemp.path}/dmx_audit/file.bin',
        knownFileSize: 1000,
        cancelToken: cancelToken,
        getTorrentFiles: () {
          callCount++;
          if (callCount > 1) {
            throw StateError(
                'Simulated crash during post-add files resolution');
          }
          return [
            {'name': 'f1', 'length': 100, 'selected': true, 'priority': 4}
          ];
        },
        clientBuilder: (u) => Dio(),
        clientReleaser: (d) => d.close(force: true),
        onProgress: (p) => emittedProgress.add(p),
      );

      await expectLater(downloadFuture, throwsA(isA<StateError>()));
      expect(mockService.removedTorrents, contains(202));
      expect(
        emittedProgress.any((p) => p.cycleState == CycleState.failed),
        isTrue,
      );
    });

    test(
        'C3: haltTorrent is bounded by single deadline and calls forceStopTorrent',
        () async {
      // Mock alive but never transitioning to paused in stats
      mockService.alive = true;
      final stopwatch = Stopwatch()..start();

      await handler.haltTorrent(101, budget: const Duration(milliseconds: 400));
      stopwatch.stop();

      expect(mockService.forceStoppedTorrents, contains(101));
      expect(stopwatch.elapsedMilliseconds, lessThan(2000));
      expect(handler.activeTorrentIds, isNot(contains(101)));
    });

    test(
        'C4: TorrentRuntime.close completes guard and pause completers without hanging',
        () async {
      final rt = TorrentRuntime();
      final guard = Completer<void>();
      final pause = Completer<void>();
      rt.completionGuard = guard;
      rt.pauseCompleter = pause;

      expect(rt.isClosed, isFalse);
      rt.close();
      expect(rt.isClosed, isTrue);

      expect(guard.isCompleted, isTrue);
      expect(pause.isCompleted, isTrue);

      await expectLater(guard.future, throwsA(isA<StateError>()));
      await expectLater(pause.future, throwsA(isA<StateError>()));
    });
  });

  group('Torrent Audit Fixes (H1 - H4, Minor Issues)', () {
    test(
        'H1: TorrentSubscriptionRegistry disowns previous handler on re-registration',
        () async {
      final handlerA = TorrentDownloadHandler(torrentService: mockService);
      final handlerB = TorrentDownloadHandler(torrentService: mockService);

      final sub1 = const Stream<void>.empty().listen((_) {});
      final sub2 = const Stream<void>.empty().listen((_) {});

      TorrentSubscriptionRegistry.instance.register(55, handlerA, sub1);
      expect(
        TorrentSubscriptionRegistry.instance
            .subsForHandler(handlerA)
            .containsKey(55),
        isTrue,
      );

      TorrentSubscriptionRegistry.instance.register(55, handlerB, sub2);
      expect(
        TorrentSubscriptionRegistry.instance
            .subsForHandler(handlerA)
            .containsKey(55),
        isFalse,
      );
      expect(
        TorrentSubscriptionRegistry.instance
            .subsForHandler(handlerB)
            .containsKey(55),
        isTrue,
      );
    });

    test('H4: TorrentAlertType mapped accurately from native codes', () {
      expect(
        TorrentAlertType.fromNativeType(38),
        equals(TorrentAlertType.metadataReceived),
      );
      expect(
        TorrentAlertType.fromNativeType(34),
        equals(TorrentAlertType.torrentPaused),
      );
      expect(
        TorrentAlertType.fromNativeType(35),
        equals(TorrentAlertType.torrentResumed),
      );
      expect(
        TorrentAlertType.fromNativeType(26),
        equals(TorrentAlertType.pieceFinished),
      );
      expect(
        TorrentAlertType.fromNativeType(30),
        equals(TorrentAlertType.saveResumeDataCompleted),
      );
      expect(
        TorrentAlertType.fromNativeType(64),
        equals(TorrentAlertType.torrentError),
      );
    });

    test('TorrentFileSnapshot hash & differ equality parity', () {
      final listA = [
        {
          'name': 'a.mp4',
          'length': 100,
          'downloadedBytes': 50,
          'selected': true,
          'priority': 4,
          'isComplete': false,
        }
      ];
      final listB = [
        {
          'name': 'a.mp4',
          'length': 100,
          'downloadedBytes': 50,
          'selected': true,
          'priority': 4,
          'isComplete': true, // Changed isComplete
        }
      ];

      final snapA = TorrentFileSnapshot(listA);
      final snapB = TorrentFileSnapshot(listB);

      expect(snapA == snapB, isFalse);
      expect(snapA.hash == snapB.hash, isFalse);
    });
  });
}
