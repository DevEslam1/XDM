import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/di/injection.dart';
import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/engine/engine_exceptions.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:dmx/core/services/torrent_resume_store.dart';
import 'package:dmx/core/services/torrent_service_stub.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the torrent-engine fix batch (B1, B9, B15, B16, B19).
///
/// The mock service extends [TorrentServiceStub] (unlike the real FFI bridge
/// it can be scripted), which lets these tests exercise the handler logic in
/// isolation — including the degraded-resume path that libtorrent_flutter
/// 1.9.2 forces (its native save/loadResumeData return null/false).
class _FixBatchMockService extends TorrentServiceStub {
  final StreamController<Map<int, TorrentUpdateInfo>> controller;
  _FixBatchMockService(this.controller);

  List<TorrentFileItem> mockFiles = [];
  final List<Duration> capturedMetadataTimeouts = [];
  final List<int> addedIds = [];
  final List<int> recheckCalls = [];
  final List<int> removeTorrentCalls = [];
  final List<List<int>> setPriorityCalls = [];
  Map<String, dynamic>? pieceProgressResult;
  int nextId = 100;

  @override
  Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates => controller.stream;

  @override
  bool isTorrentAlive(int id) => true;

  @override
  int addMagnet(String magnetUri, String savePath, {List<int>? resumeData}) {
    final id = nextId++;
    addedIds.add(id);
    return id;
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
    capturedMetadataTimeouts.add(timeout);
    final id = nextId++;
    addedIds.add(id);
    return id;
  }

  @override
  int addTorrentFile(String filePath, String savePath,
      {String? sourceKey, List<int>? resumeData}) {
    final id = nextId++;
    addedIds.add(id);
    return id;
  }

  @override
  List<TorrentFileItem> getFiles(int id) => mockFiles;

  @override
  void setFilePriorities(int id, List<int> priorities) {
    setPriorityCalls.add(priorities);
  }

  @override
  Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath, {
    Map<int, int>? knownSizes,
  }) async =>
      [];

  @override
  Future<Map<String, dynamic>?> getPieceProgress(int torrentId) async =>
      pieceProgressResult;

  @override
  void recheckTorrent(int id) => recheckCalls.add(id);

  @override
  void removeTorrent(int id,
      {bool deleteFiles = false, bool deleteResumeData = false}) {
    removeTorrentCalls.add(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<int, TorrentUpdateInfo>> controller;
  late _FixBatchMockService mock;
  late TorrentDownloadHandler handler;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('torrent_fixbatch_');
    // path_provider mock so TorrentResumeStore can round-trip degraded
    // snapshots during the handler tests.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (methodCall) async => tempDir.path,
    );

    controller = StreamController<Map<int, TorrentUpdateInfo>>.broadcast();
    mock = _FixBatchMockService(controller);
    handler = TorrentDownloadHandler(torrentService: mock);
    getIt.registerSingleton<ITorrentService>(mock);
  });

  tearDown(() async {
    TorrentSubscriptionRegistry.instance.clear();
    await controller.close();
    if (getIt.isRegistered<ITorrentService>()) {
      await getIt.unregister<ITorrentService>();
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  TorrentUpdateInfo info(
    int id, {
    double progress = 0.0,
    int totalDone = 0,
    int totalWanted = 1000,
    int totalWantedDone = 0,
    bool hasMetadata = true,
    String stateLabel = 'downloading',
    TorrentState state = TorrentState.downloading,
    List<int> fileProgress = const [],
    int rate = 0,
    int numPeers = 0,
  }) =>
      TorrentUpdateInfo(
        id: id,
        name: 't.bin',
        progress: progress,
        downloadRate: rate,
        uploadRate: 0,
        totalDone: totalDone,
        totalWanted: totalWanted,
        totalWantedDone: totalWantedDone,
        hasMetadata: hasMetadata,
        stateLabel: stateLabel,
        state: state,
        fileProgress: fileProgress,
        numPeers: numPeers,
        downloadPayloadRate: rate,
      );

  Future<void> runTorrent(
    String url, {
    required void Function(DownloadProgress) onProgress,
    CancelToken? cancelToken,
    int? metadataTimeoutSeconds,
    List<Map<String, dynamic>>? torrentFileRows,
  }) {
    return handler.handleTorrentDownload(
      taskId: 'fixbatch-task',
      torrentId: null,
      url: url,
      currentLocalFilePath: '${Directory.systemTemp.path}/dmx_fixbatch/t.bin',
      knownFileSize: 1000,
      cancelToken: cancelToken ?? CancelToken(),
      clientBuilder: (_) => Dio(),
      clientReleaser: (client) => client.close(force: true),
      onProgress: onProgress,
      getTorrentFiles: torrentFileRows == null ? null : () => torrentFileRows,
      metadataTimeoutSeconds: metadataTimeoutSeconds,
    );
  }

  TorrentUpdateInfo seeding(int id) => info(
        id,
        progress: 1.0,
        totalDone: 1000,
        totalWantedDone: 1000,
        stateLabel: 'seeding',
        state: TorrentState.seeding,
      );

  group('B1: metadataTimeoutSeconds forwarding', () {
    test('user setting reaches addMagnetWithMetadataTimeout', () async {
      const url = 'magnet:?xt=urn:btih:b1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1';
      final future = runTorrent(url, onProgress: (_) {}, metadataTimeoutSeconds: 42);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final id = mock.addedIds.last;
      controller.add({id: seeding(id)});
      await future;
      expect(mock.capturedMetadataTimeouts.last, const Duration(seconds: 42));
    });

    test('omitted setting keeps the 300s service default', () async {
      const url = 'magnet:?xt=urn:btih:b1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2';
      final future = runTorrent(url, onProgress: (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final id = mock.addedIds.last;
      controller.add({id: seeding(id)});
      await future;
      expect(mock.capturedMetadataTimeouts.last, const Duration(seconds: 300));
    });
  });

  group('B15: degraded snapshot round-trip (no native blob, 1.9.2)', () {
    test('arms resumeExpectedBytes and fires one recovery recheck', () async {
      const url = 'magnet:?xt=urn:btih:b15bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1';
      mock.nextId = 33;

      // Pause-time degraded save: native blob is null (1.9.2), so only the
      // meta JSON with bitfield + files is persisted.
      final saved = await TorrentResumeStore.saveAndWait(
        torrentId: 33,
        sourceUrl: url,
        fetchResumeData: () async => null,
        files: [
          {
            'name': 'main.bin',
            'length': 1000,
            'downloadedBytes': 0,
            'selected': true,
            'priority': 4,
            'lengthKnown': true,
          },
          {
            'name': 'extra.bin',
            'length': 3000,
            'downloadedBytes': 0,
            'selected': false,
            'priority': 0,
          },
        ],
        pieceBitfield: [true, true, false, false],
        piecesTotal: 4,
        piecesDone: 2,
        degradedFallback: true,
      );
      expect(saved, isTrue);

      final token = CancelToken();
      final future = runTorrent(url, onProgress: (_) {}, cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // The degraded snapshot was consumed: expectation armed from the
      // bitfield-derived bytes (2/4 pieces of the 1000-byte selection).
      final rt = handler.runtimeFor(33);
      expect(rt, isNotNull);
      expect(rt!.resumeExpectedBytes, 500);

      // Engine reports 0 of the stored 500 → exactly one recovery recheck.
      mock.pieceProgressResult = {'piecesHave': 0, 'piecesTotal': 4};
      controller.add({33: info(33)});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(mock.recheckCalls, [33]);
      expect(rt.resumeRecheckIssued, isTrue);

      // Completing the torrent does not fire a second recheck.
      controller.add({33: seeding(33)});
      await future;
      expect(mock.recheckCalls, [33]);
    });
  });

  group('B16: deselected files must not inflate progress or complete early',
      () {
    test('emitted progress stays wanted-only', () async {
      const url = 'magnet:?xt=urn:btih:b16bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1';
      mock.nextId = 44;
      final rows = [
        {
          'name': 'main.bin',
          'length': 1000,
          'downloadedBytes': 0,
          'selected': true,
          'priority': 4,
        },
        {
          'name': 'extra.bin',
          'length': 3000,
          'downloadedBytes': 3000,
          'selected': false,
          'priority': 0,
        },
      ];
      final emits = <DownloadProgress>[];
      final future = runTorrent(url,
          onProgress: emits.add, torrentFileRows: rows);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // Deselected file fully on disk (totalDone 3000) but nothing of the
      // wanted selection downloaded. The old totalDone-based reporting made
      // this read 3000/1000.
      controller.add({44: info(44, totalDone: 3000, fileProgress: [0, 3000])});
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final ticks = emits
          .where((p) => p.cycleState == CycleState.downloading)
          .toList();
      expect(ticks, isNotEmpty);
      expect(ticks.last.downloadedBytes, 0,
          reason: 'deselected bytes must not be reported as download progress');
      expect(
          emits.where((p) =>
              p.cycleState == CycleState.completed ||
              p.cycleState == CycleState.seeding),
          isEmpty,
          reason: 'torrent with an incomplete selection must not complete');

      controller.add({44: seeding(44)});
      await future;
    });

    test(
        'completion requires per-file wanted bytes when a selection exists',
        () async {
      const url = 'magnet:?xt=urn:btih:b16bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2';
      mock.nextId = 45;
      final rows = [
        {
          'name': 'main.bin',
          'length': 1000,
          'downloadedBytes': 0,
          'selected': true,
          'priority': 4,
        },
        {
          'name': 'extra.bin',
          'length': 3000,
          'downloadedBytes': 3000,
          'selected': false,
          'priority': 0,
        },
      ];
      final emits = <DownloadProgress>[];
      final future = runTorrent(url,
          onProgress: emits.add, torrentFileRows: rows);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // Torrent-level totals look complete (progress 1.0, wanted done), but
      // the selected file is only at 400/1000 — completion must not bank.
      controller.add({45: info(45, progress: 1.0, totalDone: 4000, fileProgress: const [400, 3000])});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(emits.where((p) => p.cycleState == CycleState.completed), isEmpty,
          reason: 'selected file is still incomplete');

      // Selected file finished → completion is now legitimate (the terminal
      // emit is CycleState.seeding when seeding is enabled, completed when
      // it is not).
      controller.add({45: seeding(45)});
      await future;
      expect(
          emits.where((p) =>
              p.cycleState == CycleState.completed ||
              p.cycleState == CycleState.seeding),
          isNotEmpty);
    });
  });

  group('B19: replacement subscriptions must not leak', () {
    test('cleanup cancels the current (replaced) subscription', () async {
      const url = 'magnet:?xt=urn:btih:b19bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1';
      final token = CancelToken();
      final future = handler.listenForCompletionForTesting(
        55,
        url,
        '${Directory.systemTemp.path}/dmx_fixbatch/t.bin',
        token,
        (_) {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(handler.activeSubsForTesting.length, 1);
      expect(controller.hasListener, isTrue);

      // Stream error below the 3-miss limit → the handler replaces the
      // subscription instead of failing the download.
      controller.addError(StateError('transient stream error'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(handler.activeSubsForTesting.length, 1,
          reason: 'replacement subscription must be registered');
      expect(controller.hasListener, isTrue);

      // Completion → cleanup must cancel the CURRENT subscription, not just
      // the stale local one.
      controller.add({55: seeding(55)});
      await future;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(controller.hasListener, isFalse,
          reason: 'replaced subscription leaked: the stream listener was '
              'never cancelled after cleanup');
      expect(handler.activeSubsForTesting, isEmpty);
    });
  });

  group('B9: recoverable failures keep engine state', () {
    test('stall keeps the handle and the resume mapping', () async {
      const url = 'magnet:?xt=urn:btih:b09bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1';
      mock.nextId = 66;

      // A degraded snapshot + registration exists for this source; the fatal
      // path used to unregister it, destroying resume data for a transient
      // stall.
      await TorrentResumeStore.saveAndWait(
        torrentId: 66,
        sourceUrl: url,
        fetchResumeData: () async => null,
        files: [
          {
            'name': 'main.bin',
            'length': 1000,
            'downloadedBytes': 0,
            'selected': true,
            'priority': 4,
          }
        ],
        pieceBitfield: [true, false],
        piecesTotal: 2,
        piecesDone: 1,
        degradedFallback: true,
      );
      expect(TorrentResumeStore.isRegisteredForTesting(66), isTrue);

      final emits = <DownloadProgress>[];
      final future = runTorrent(url, onProgress: emits.add);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // Same error the 5-minute stall watchdog raises.
      final guard = handler.completionGuardForTesting;
      expect(guard, isNotNull);
      expect(guard!.isCompleted, isFalse);
      guard.completeError(const TorrentStallException(
        'Torrent download stalled for > 5 minutes with no updates',
      ));

      await expectLater(future, throwsA(isA<TorrentStallException>()));

      // Recoverable: engine handle untouched, resume mapping survives, and
      // the failure is surfaced with a retry hint.
      expect(mock.removeTorrentCalls, isEmpty,
          reason: 'a stalled torrent must keep its live engine handle');
      expect(TorrentResumeStore.isRegisteredForTesting(66), isTrue,
          reason: 'a stall must not unregister the resume mapping');
      expect(
        emits.any((p) =>
            p.cycleState == CycleState.failed &&
            (p.statusMessage?.contains('stalled') ?? false)),
        isTrue,
      );
    });
  });
}
