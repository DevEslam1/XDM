import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/domain/cycle_state.dart';
import 'package:dmx/core/domain/engine_types.dart';
import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../test/helpers/fake_torrent_service.dart';

class _MockPayloadAdapter implements HttpClientAdapter {
  final List<int> payload;
  _MockPayloadAdapter(this.payload);

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

class ScriptableFakeTorrentService extends FakeITorrentService {
  final Map<int, bool> loadResumeResults = {};
  final List<int> recheckedIds = [];
  final List<int> removedIds = [];
  final List<int> forceStoppedIds = [];
  final Map<int, String> stateLabels = {};
  bool throwOnMetadataWait = false;
  Duration metadataDelay = Duration.zero;

  @override
  bool isTorrentAlive(int id) => !removedIds.contains(id);

  @override
  bool loadResumeData(int id, List<int> data) {
    return loadResumeResults[id] ?? true;
  }

  @override
  void recheckTorrent(int id) {
    recheckedIds.add(id);
  }

  @override
  void removeTorrent(int id,
      {bool deleteFiles = false, bool deleteResumeData = false}) {
    removedIds.add(id);
  }

  @override
  Future<void> forceStopTorrent(int id) async {
    forceStoppedIds.add(id);
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
    if (throwOnMetadataWait) {
      throw TimeoutException('Metadata wait timed out', timeout);
    }
    if (metadataDelay > Duration.zero) {
      await Future.delayed(metadataDelay);
    }
    return 100;
  }

  @override
  Map<int, TorrentUpdateInfo> get latestStats {
    return stateLabels.map((id, label) => MapEntry(
          id,
          TorrentUpdateInfo(
            id: id,
            name: 'test.iso',
            progress: 0.5,
            downloadRate: 0,
            uploadRate: 0,
            totalDone: 500,
            totalWanted: 1000,
            totalWantedDone: 500,
            hasMetadata: true,
            stateLabel: label,
          ),
        ));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScriptableFakeTorrentService fakeService;
  late TorrentDownloadHandler handler;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        return Directory.systemTemp.path;
      },
    );
    TorrentSubscriptionRegistry.instance.clear();
    fakeService = ScriptableFakeTorrentService();
    handler = TorrentDownloadHandler(torrentService: fakeService);
  });

  tearDown(() {
    handler.dispose();
    TorrentSubscriptionRegistry.instance.clear();
  });

  // Regression: C1
  group('C1: Per-torrent Runtime Isolation', () {
    test('removing one torrent leaves sibling watchdog and cached files intact',
        () async {
      final cancel1 = CancelToken();
      final cancel2 = CancelToken();

      unawaited(handler
          .listenForCompletionForTesting(
            1,
            'magnet:?xt=urn:btih:1111111111111111111111111111111111111111',
            '${Directory.systemTemp.path}/f1',
            cancel1,
            (_) {},
            getTorrentFiles: () => [
              {'name': 'f1.bin', 'length': 1000, 'downloadedBytes': 500}
            ],
          )
          .catchError((_) {}));

      unawaited(handler
          .listenForCompletionForTesting(
            2,
            'magnet:?xt=urn:btih:2222222222222222222222222222222222222222',
            '${Directory.systemTemp.path}/f2',
            cancel2,
            (_) {},
            getTorrentFiles: () => [
              {'name': 'f2.bin', 'length': 2000, 'downloadedBytes': 1000}
            ],
          )
          .catchError((_) {}));

      await Future<void>.delayed(const Duration(milliseconds: 20));

      final rt1 = handler.getRuntimeForTesting(1);
      final rt2 = handler.getRuntimeForTesting(2);
      expect(rt1, isNotNull);
      expect(rt2, isNotNull);
      expect(rt2!.stallWatchdog, isNotNull);

      // Remove torrent 1
      handler.removeActiveTorrent(1);

      expect(handler.getRuntimeForTesting(1), isNull);
      expect(handler.getRuntimeForTesting(2), isNotNull);
      expect(rt2.stallWatchdog, isNotNull);

      // Clean up torrent 2
      handler.removeActiveTorrent(2);
      expect(handler.getRuntimeForTesting(2), isNull);
    });
  });

  // Regression: C2
  group('C2: Cancellation and Handle Leak Prevention', () {
    test('cancel before start throws cancel and does not add torrent', () async {
      final cancelToken = CancelToken()..cancel('Immediate cancellation');

      expect(
        () => handler.handleTorrentDownload(
          taskId: 't-cancel-early',
          url: 'magnet:?xt=urn:btih:abcdef1234567890abcdef1234567890abcdef12',
          currentLocalFilePath: '${Directory.systemTemp.path}/out.bin',
          knownFileSize: 1000,
          cancelToken: cancelToken,
          onProgress: (_) {},
          clientBuilder: (u) => Dio(),
          clientReleaser: (d) => d.close(),
        ),
        throwsA(isA<DioException>().having(
            (e) => e.type, 'type', equals(DioExceptionType.cancel))),
      );
    });

    test('non-bencoded torrent content throws TorrentSourceException',
        () async {
      final cancelToken = CancelToken();

      expect(
        () => handler.handleTorrentDownload(
          taskId: 't-bad-torrent',
          url: 'http://example.com/bad.torrent',
          currentLocalFilePath: '${Directory.systemTemp.path}/out.bin',
          knownFileSize: 1000,
          cancelToken: cancelToken,
          onProgress: (_) {},
          clientBuilder: (u) {
            final mockDio = Dio();
            mockDio.httpClientAdapter = _MockPayloadAdapter(
              utf8.encode('<html><body>404 Not Found</body></html>'),
            );
            return mockDio;
          },
          clientReleaser: (_) {},
        ),
        throwsA(isA<TorrentSourceException>()),
      );
    });
  });

  // Regression: C3
  group('C3: haltTorrent Verification Matrix', () {
    test('fake in paused state verified on attempt 1 without force stop',
        () async {
      fakeService.stateLabels[42] = 'paused';

      await handler.haltTorrent(42);

      expect(fakeService.forceStoppedIds.contains(42), isFalse);
    });

    test('fake stuck in checking_files exhausts attempts and calls forceStop',
        () async {
      fakeService.stateLabels[99] = 'checking_files';

      await handler.haltTorrent(99);

      expect(fakeService.forceStoppedIds.contains(99), isTrue);
    });
  });

  // Regression: C4
  group('C4: Injected Service Call and loadResumeData false Recheck', () {
    test('loadResumeData returning false triggers recheckTorrent', () async {
      fakeService.loadResumeResults[100] = false;

      const url = 'magnet:?xt=urn:btih:3333333333333333333333333333333333333333';
      await TorrentResumeStore.saveAndWait(
        torrentId: 100,
        sourceUrl: url,
        fetchResumeData: () => Uint8List.fromList([1, 2, 3, 4]),
      );

      final cancelToken = CancelToken();
      unawaited(handler.handleTorrentDownload(
        taskId: 't-recheck',
        url: url,
        currentLocalFilePath: '${Directory.systemTemp.path}/f100',
        knownFileSize: 1000,
        cancelToken: cancelToken,
        onProgress: (_) {},
        clientBuilder: (u) => Dio(),
        clientReleaser: (_) {},
      ).catchError((_) {}));

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(fakeService.recheckedIds.contains(100), isTrue);
      cancelToken.cancel();
    });
  });

  // Regression: C5
  group('C5: TorrentFileSnapshot Mutability Contract', () {
    test('mutating source list after construction preserves snapshot hash and equality',
        () {
      final source = [
        {'name': 'video.mp4', 'length': 1000, 'downloadedBytes': 0, 'selected': true, 'priority': 4, 'isComplete': false}
      ];

      final snapshot = TorrentFileSnapshot(source);
      final initialHash = snapshot.hash;

      source[0]['downloadedBytes'] = 999;
      source.add({'name': 'extra.txt', 'length': 500});

      expect(snapshot.hash, equals(initialHash));
      expect(snapshot.files.length, equals(1));
      expect(snapshot.files[0]['downloadedBytes'], equals(0));
    });
  });

  // Regression: C6
  group('C6: Resume Save Hard 8-Second Budget', () {
    test('saveResumeDataBeforePause completes within 8 seconds', () async {
      final stopwatch = Stopwatch()..start();

      await handler.haltTorrent(500);

      stopwatch.stop();
      expect(stopwatch.elapsed.inSeconds, lessThanOrEqualTo(8));
    });
  });
}
