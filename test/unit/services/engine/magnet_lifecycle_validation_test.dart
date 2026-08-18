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

class MockMagnetValidationTorrentService extends TorrentServiceStub {
  final StreamController<Map<int, TorrentUpdateInfo>> _controller;
  List<TorrentFileItem> mockFiles = [];

  MockMagnetValidationTorrentService(this._controller);

  bool _isAlive = true;

  @override
  Stream<Map<int, TorrentUpdateInfo>> get torrentUpdates => _controller.stream;

  @override
  bool isTorrentAlive(int id) => _isAlive;

  @override
  int addMagnet(String magnetUri, String savePath) {
    _isAlive = true;
    return 101;
  }

  @override
  void removeTorrent(int id,
      {bool deleteFiles = false, bool deleteResumeData = false}) {
    _isAlive = false;
  }

  @override
  Future<void> pauseTorrent(int id) async {
    _isAlive = false;
  }

  @override
  Future<int> addMagnetWithMetadataTimeout(
    String magnetUri,
    String savePath, {
    Duration timeout = const Duration(seconds: 300),
    void Function(String message)? onStatusUpdate,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 10),
  }) async {
    onStatusUpdate?.call('Fetching metadata... (1s elapsed)');
    return 101;
  }

  @override
  List<TorrentFileItem> getFiles(int torrentId) => mockFiles;

  @override
  int getFileCount(int torrentId) => mockFiles.length;

  @override
  Future<List<TorrentFileProgress>> getAccurateFileProgress(
    int torrentId,
    String savePath,
  ) async {
    return mockFiles
        .map((f) => TorrentFileProgress(
              index: f.index,
              name: f.name,
              size: f.size,
              downloadedBytes: f.downloadedBytes < 0 ? 0 : f.downloadedBytes,
              progress: f.size > 0
                  ? (f.downloadedBytes / f.size).clamp(0.0, 1.0)
                  : 0.0,
              exists: true,
              isComplete: f.size > 0 && f.downloadedBytes >= f.size,
            ))
        .toList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const testMagnetUrl =
      'magnet:?xt=urn:btih:32839ADF115A66B50469C461A71ABCBE0DC8B3D1&dn=Feed.2026.1080p.WEB.H264-CinemaCity&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce';

  late StreamController<Map<int, TorrentUpdateInfo>> controller;
  late MockMagnetValidationTorrentService mockService;
  late TorrentDownloadHandler handler;

  setUp(() {
    controller = StreamController<Map<int, TorrentUpdateInfo>>.broadcast();
    mockService = MockMagnetValidationTorrentService(controller);
    handler = TorrentDownloadHandler(torrentService: mockService);
    if (getIt.isRegistered<ITorrentService>()) {
      getIt.unregister<ITorrentService>();
    }
    getIt.registerSingleton<ITorrentService>(mockService);
  });

  tearDown(() async {
    TorrentSubscriptionRegistry.instance.clear();
    await controller.close();
    if (getIt.isRegistered<ITorrentService>()) {
      await getIt.unregister<ITorrentService>();
    }
  });

  group('Magnet Full Lifecycle Validation', () {
    test(
        '1. Magnet Start & Metadata Phase: clean initial emissions and metadata resolution',
        () async {
      final emitted = <DownloadProgress>[];
      final cancel = CancelToken();

      final downloadFuture = handler.handleTorrentDownload(
        taskId: 'task-feed-magnet',
        torrentId: 101,
        url: testMagnetUrl,
        currentLocalFilePath:
            '${Directory.systemTemp.path}/Feed.2026.1080p.WEB.H264-CinemaCity.mkv',
        knownFileSize: 0,
        cancelToken: cancel,
        clientBuilder: (u) => Dio(),
        clientReleaser: (d) => d.close(force: true),
        onProgress: (p) => emitted.add(p),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 1. Initial emission must be starting/fetching metadata with 0 bytes and no false 100%
      expect(emitted, isNotEmpty);
      expect(emitted.first.cycleState, CycleState.starting);
      expect(emitted.first.downloadedBytes, 0);
      expect(emitted.first.fileSize, 0);

      // 2. Libtorrent emits initial state before metadata is parsed
      controller.add({
        101: TorrentUpdateInfo(
          id: 101,
          name: 'Feed.2026.1080p.WEB.H264-CinemaCity',
          progress: 0.0,
          downloadRate: 65,
          uploadRate: 1500,
          totalDone: 818700, // protocol handshake data
          totalWanted: 0, // not ready yet
          totalWantedDone: 0,
          hasMetadata: false,
          stateLabel: 'downloading_metadata',
          downloadPayloadRate: 65,
          uploadPayloadRate: 1500,
          numPeers: 15,
          numSeeds: 5,
        )
      });

      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Must remain in metadata fetching without corrupted completion
      final metaProgress = emitted.last;
      expect(metaProgress.cycleState, CycleState.fetchingMetadata);
      expect(metaProgress.fileSize, 0);
      expect(metaProgress.downloadedBytes, 0);
      expect(metaProgress.speed, 65.0);
      expect(metaProgress.numPeers, 15);
      expect(metaProgress.numSeeds, 5);

      // 3. Metadata arrives: libtorrent resolves file list of 2.1 GB
      const totalMovieSize = 2254857830; // ~2.1 GB
      mockService.mockFiles = [
        TorrentFileItem(
          index: 0,
          name: 'Feed.2026.1080p.WEB.H264-CinemaCity.mkv',
          size: totalMovieSize,
          downloadedBytes: 0,
          priority: 4,
          selected: true,
        )
      ];

      controller.add({
        101: TorrentUpdateInfo(
          id: 101,
          name: 'Feed.2026.1080p.WEB.H264-CinemaCity',
          progress: 0.0,
          downloadRate: 1500000, // 1.5 MB/s
          uploadRate: 50000,
          totalDone: 0,
          totalWanted: totalMovieSize,
          totalWantedDone: 0,
          hasMetadata: true,
          stateLabel: 'downloading',
          downloadPayloadRate: 1500000,
          uploadPayloadRate: 50000,
          numPeers: 25,
          numSeeds: 10,
          piecesHave: 0,
          piecesTotal: 2150,
        )
      });

      await Future<void>.delayed(const Duration(milliseconds: 30));

      final activeProgress = emitted.last;
      expect(activeProgress.cycleState, CycleState.downloading);
      expect(activeProgress.fileSize, totalMovieSize);
      expect(activeProgress.downloadedBytes, 0);
      expect(activeProgress.speed, 1500000.0);
      expect(activeProgress.torrentFiles, isNotNull);
      expect(activeProgress.torrentFiles!.length, 1);
      expect(activeProgress.torrentFiles!.first['length'], totalMovieSize);
      expect(activeProgress.torrentFiles!.first['isComplete'], isFalse);

      // Cancel and finish cleanly
      cancel.cancel();
      try {
        await downloadFuture;
      } catch (_) {}
    });

    test(
        '2. Incremental Download & Speed & No Data Loss / False Jumps to 100%',
        () async {
      final emitted = <DownloadProgress>[];
      final cancel = CancelToken();
      const totalMovieSize = 2000000000; // 2 GB

      mockService.mockFiles = [
        TorrentFileItem(
          index: 0,
          name: 'Feed.2026.1080p.WEB.H264-CinemaCity.mkv',
          size: totalMovieSize,
          downloadedBytes: 0,
          priority: 4,
          selected: true,
        )
      ];

      final downloadFuture = handler.handleTorrentDownload(
        taskId: 'task-feed-magnet-2',
        torrentId: 102,
        url: testMagnetUrl,
        currentLocalFilePath:
            '${Directory.systemTemp.path}/Feed.2026.1080p.WEB.H264-CinemaCity.mkv',
        knownFileSize: totalMovieSize,
        cancelToken: cancel,
        clientBuilder: (u) => Dio(),
        clientReleaser: (d) => d.close(force: true),
        onProgress: (p) => emitted.add(p),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Emit 10% progress (200 MB)
      const dl10 = 200000000;
      mockService.mockFiles[0] = TorrentFileItem(
        index: 0,
        name: 'Feed.2026.1080p.WEB.H264-CinemaCity.mkv',
        size: totalMovieSize,
        downloadedBytes: dl10,
        priority: 4,
        selected: true,
      );

      controller.add({
        102: TorrentUpdateInfo(
          id: 102,
          name: 'Feed.2026.1080p.WEB.H264-CinemaCity',
          progress: 0.10,
          downloadRate: 2500000, // 2.5 MB/s
          uploadRate: 150000,
          totalDone: dl10,
          totalWanted: totalMovieSize,
          totalWantedDone: dl10,
          hasMetadata: true,
          stateLabel: 'downloading',
          downloadPayloadRate: 2500000,
          uploadPayloadRate: 150000,
          numPeers: 30,
          numSeeds: 12,
          piecesHave: 200,
          piecesTotal: 2000,
        )
      });

      await Future<void>.delayed(const Duration(milliseconds: 30));

      final p1 = emitted.last;
      expect(p1.downloadedBytes, dl10);
      expect(p1.fileSize, totalMovieSize);
      expect(p1.speed, 2500000.0);
      expect(p1.cycleState, CycleState.downloading);
      expect(p1.torrentFiles!.first['downloadedBytes'], dl10);
      expect(p1.torrentFiles!.first['isComplete'], isFalse);

      // Emit full 100% completion
      mockService.mockFiles[0] = TorrentFileItem(
        index: 0,
        name: 'Feed.2026.1080p.WEB.H264-CinemaCity.mkv',
        size: totalMovieSize,
        downloadedBytes: totalMovieSize,
        priority: 4,
        selected: true,
      );

      controller.add({
        102: TorrentUpdateInfo(
          id: 102,
          name: 'Feed.2026.1080p.WEB.H264-CinemaCity',
          progress: 1.0,
          downloadRate: 0,
          uploadRate: 50000,
          totalDone: totalMovieSize,
          totalWanted: totalMovieSize,
          totalWantedDone: totalMovieSize,
          hasMetadata: true,
          stateLabel: 'seeding',
          downloadPayloadRate: 0,
          uploadPayloadRate: 50000,
          numPeers: 15,
          numSeeds: 15,
          piecesHave: 2000,
          piecesTotal: 2000,
        )
      });

      await downloadFuture.timeout(const Duration(seconds: 5));

      final finalProgress = emitted.last;
      expect(
        finalProgress.cycleState,
        isIn([CycleState.completed, CycleState.seeding]),
      );
      expect(finalProgress.downloadedBytes, totalMovieSize);
      expect(finalProgress.fileSize, totalMovieSize);
      expect(finalProgress.torrentFiles!.first['isComplete'], isTrue);
    });
  });
}
