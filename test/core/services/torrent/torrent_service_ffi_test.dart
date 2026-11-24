import 'dart:async';
import 'dart:io';

import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/domain/torrent_session_settings.dart';
import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTorrentNative native;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('torrent_ffi_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (methodCall) async => tempDir.path,
    );
    native = FakeTorrentNative();
    TorrentService.setNativeForTesting(native);
  });

  tearDown(() async {
    await TorrentService.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  List<NativeFileInfo> files(int count) => List.generate(
        count,
        (i) => NativeFileInfo(
          index: i,
          name: 'file$i.bin',
          path: '${tempDir.path}/file$i.bin',
          size: 1000 * (i + 1),
          isStreamable: false,
        ),
      );

  Future<int> seed(int id, {int fileCount = 1}) async {
    native.seedTorrent(id: id, name: 'torrent_$id', files: files(fileCount));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    return id;
  }

  group('TorrentService (FFI) state and capabilities', () {
    test('setNativeForTesting brings the service online', () async {
      expect(TorrentService.isSupported, isTrue);
      expect(TorrentService.isInitialized, isTrue);
      expect(TorrentService.isPluginAvailable, isTrue);
      await TorrentService.ready;
    });

    test('capability flags mirror the pinned 1.9.2 bridge', () {
      expect(TorrentService.fileProgressSupported, isFalse);
      expect(TorrentService.resumeDataSupported, isFalse);
      expect(TorrentService.forceRecheckSupported, isTrue);
      expect(TorrentService.trackersSupported, isFalse);
      expect(TorrentService.sequentialDownloadSupported, isFalse);
      expect(TorrentService.webSeedsSupported, isFalse);
    });

    test('configureSession forwards a NativeBtConfig', () {
      TorrentService.configureSession();
      expect(native.lastConfig, isNotNull);
      TorrentService.reconfigureSession();
      expect(native.lastConfig, isNotNull);
      expect(TorrentService.sequentialDownloadSettingForTesting, isFalse);
    });
  });

  group('TorrentService (FFI) add and remove', () {
    test('addMagnet registers and reports the torrent', () async {
      const magnet = 'magnet:?xt=urn:btih:aaaabbbbccccddddeeeeffff00001111';
      final id = TorrentService.addMagnet(magnet, tempDir.path);
      expect(id, greaterThan(0));
      expect(TorrentService.activeTorrentIds, contains(id));
      expect(TorrentService.idForSource(magnet), id);
      await seed(id);
      expect(TorrentService.latestStats[id], isNotNull);
      expect(TorrentService.progressFor(id), 0.0);
    });

    test('addMagnet reuses an existing live handle for the same source',
        () async {
      const magnet = 'magnet:?xt=urn:btih:11112222333344445555666677778888';
      final id1 = TorrentService.addMagnet(magnet, tempDir.path);
      final id2 = TorrentService.addMagnet(magnet, tempDir.path);
      expect(id2, id1);
    });

    test('addMagnet matches a magnet by info hash regardless of case',
        () async {
      const lower = 'magnet:?xt=urn:btih:aaaabbbbccccddddeeeeffff00001111';
      final id = TorrentService.addMagnet(lower, tempDir.path);
      await seed(id);
      const upper = 'magnet:?xt=urn:btih:AAAABBBBCCCCDDDDEEEEFFFF00001111';
      expect(TorrentService.idForSource(upper), id);
    });

    test('addMagnet with resume data caches the blob', () {
      final id = TorrentService.addMagnet(
        'magnet:?xt=urn:btih:9999',
        tempDir.path,
        resumeData: const [1, 2, 3, 4],
      );
      expect(TorrentService.resumeBlobFor(id), isNotNull);
      expect(TorrentService.fetchResumeBytes(id), isNotNull);
    });

    test('addTorrentFile registers a file torrent', () async {
      final torrentFile = File('${tempDir.path}/a.torrent');
      await torrentFile.writeAsBytes([1, 2, 3]);
      final id = TorrentService.addTorrentFile(torrentFile.path, tempDir.path);
      expect(id, greaterThan(0));
      await seed(id, fileCount: 2);
      expect(TorrentService.getFileCount(id), 2);
    });

    test('removeTorrent clears state', () async {
      final id =
          TorrentService.addMagnet('magnet:?xt=urn:btih:remove', tempDir.path);
      await seed(id);
      TorrentService.removeTorrent(id, deleteResumeData: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(TorrentService.isTorrentAlive(id), isFalse);
      expect(TorrentService.idForSource('magnet:?xt=urn:btih:remove'), isNull);
    });
  });

  group('TorrentService (FFI) lifecycle', () {
    test('pause and resume a torrent', () async {
      final id = await seed(20);
      expect(TorrentService.isTorrentAlive(20), isTrue);

      await TorrentService.pauseTorrent(20);
      expect(native.getTorrentStatus(20)!.isPaused, isTrue);

      await TorrentService.resumeTorrent(20);
      expect(native.getTorrentStatus(20)!.isPaused, isFalse);
      expect(id, 20);
    });

    test('forceStopTorrent completes and clears Dart-side tracking', () async {
      final id = await seed(21);
      await TorrentService.forceStopTorrent(id);
      expect(native.getTorrentStatus(id), isNotNull);
    });

    test('saveResumeData stores the blob', () async {
      const magnet = 'magnet:?xt=urn:btih:save-resume';
      final id = TorrentService.addMagnet(magnet, tempDir.path);
      await seed(id);
      await TorrentService.saveResumeData(id);
      expect(TorrentService.resumeBlobFor(id), isNotNull);
    });

    test('saveAllResumeData iterates active torrents', () async {
      final id = TorrentService.addMagnet(
          'magnet:?xt=urn:btih:save-all', tempDir.path);
      await seed(id);
      await TorrentService.saveAllResumeData();
      expect(native.saveResumeDataCallCount, greaterThanOrEqualTo(1));
    });

    test('loadResumeData caches only on success', () async {
      final id = await seed(22);
      expect(TorrentService.loadResumeData(id, const [1, 2]), isTrue);
      expect(TorrentService.resumeBlobFor(id), isNotNull);

      native.simulateResumeLoadFailure = true;
      expect(TorrentService.loadResumeData(id, const [3, 4]), isFalse);
    });

    test('setDownloadLimit / setUploadLimit do not throw', () async {
      TorrentService.setDownloadLimit(1024);
      TorrentService.setUploadLimit(2048);
    });

    test('dispose tears the session down', () async {
      await TorrentService.dispose();
      expect(TorrentService.isAvailable.value, isFalse);
    });
  });

  group('TorrentService (FFI) files and priorities', () {
    test('getFiles resolves sizes and priorities', () async {
      final id = await seed(30, fileCount: 2);
      final result = TorrentService.getFiles(id);
      expect(result.length, 2);
      expect(result[0].size, 1000);
      expect(result[0].priority, 4);
      expect(result[0].selected, isTrue);
    });

    test('getFiles returns empty for a dead torrent', () {
      expect(TorrentService.getFiles(9999), isEmpty);
    });

    test('getFileCount and getFileProgress', () async {
      final id = await seed(31, fileCount: 3);
      expect(TorrentService.getFileCount(id), 3);
      expect(TorrentService.getFileProgress(id).length, 3);
    });

    test('getFilesCached serves within the cache window', () async {
      final id = await seed(32, fileCount: 1);
      final first = TorrentService.getFilesCached(id);
      final second = TorrentService.getFilesCached(id);
      expect(first.length, second.length);
    });

    test('setFilePriorities rejects a length mismatch', () async {
      final id = await seed(33, fileCount: 2);
      TorrentService.setFilePriorities(id, const [1]);
      expect(native.getFilePriorities(id), [4, 4]);
    });

    test('setFilePriorities applies and dedupes identical snapshots', () async {
      final id = await seed(34, fileCount: 2);
      TorrentService.setFilePriorities(id, const [0, 4]);
      expect(native.getFilePriorities(id), [0, 4]);
      // Identical second call is a no-op but must not throw.
      TorrentService.setFilePriorities(id, const [0, 4]);
      expect(native.getFilePriorities(id), [0, 4]);
    });

    test('prioritizeFile edits the cached snapshot', () async {
      final id = await seed(35, fileCount: 2);
      TorrentService.setFilePriorities(id, const [1, 1]);
      TorrentService.prioritizeFile(id, 1, priority: 0);
      expect(native.getFilePriorities(id), [1, 0]);
    });

    test('getTorrentStatus and getPieceProgress expose native state', () async {
      final id = await seed(36, fileCount: 1);
      expect(TorrentService.getTorrentStatus(id), isNotNull);
      final piece = await TorrentService.getPieceProgress(id);
      expect(piece, isNotNull);
      expect(piece!.containsKey('piecesHave'), isTrue);
    });

    test('getAccurateFileProgress reports per-file rows', () async {
      final id = await seed(37, fileCount: 2);
      final progress =
          await TorrentService.getAccurateFileProgress(id, tempDir.path);
      expect(progress.length, 2);
      expect(progress.first.name, 'file0.bin');

      // knownSizes supplies a size the engine could not report.
      final withKnown = await TorrentService.getAccurateFileProgress(
        id,
        tempDir.path,
        knownSizes: {0: 1000, 1: 2000},
      );
      expect(withKnown.length, 2);
    });
  });

  group('TorrentService (FFI) trackers, seeds and misc', () {
    test('tracker operations honour scheme validation', () async {
      final id = await seed(40);
      TorrentService.addTracker(id, 'not-a-url');
      expect(native.getTrackers(id), isEmpty);
      TorrentService.addTracker(id, 'udp://tracker.example:80');
      expect(native.getTrackers(id).length, 1);
      expect(TorrentService.getTrackers(id).length, 1);
      TorrentService.removeTracker(id, 'udp://tracker.example:80');
      expect(native.getTrackers(id), isEmpty);
      TorrentService.announceNow(id);
      TorrentService.boostMagnetDiscovery(id);
    });

    test('web seeds round-trip', () async {
      final id = await seed(41);
      TorrentService.addWebSeed(id, 'https://seed.example/file');
      expect(TorrentService.getWebSeeds(id), ['https://seed.example/file']);
      TorrentService.addWebSeed(id, '   ');
      TorrentService.removeWebSeed(id, 'https://seed.example/file');
      expect(TorrentService.getWebSeeds(id), isEmpty);
    });

    test('misc operations do not throw', () async {
      final id = await seed(42, fileCount: 1);
      TorrentService.enableSequentialDownload(id, true);
      TorrentService.setSequentialDownload(id, true);
      TorrentService.setPieceDeadline(id, 0, 1000);
      TorrentService.enableSuperSeeding(id, true);
      TorrentService.autoEnableSequentialForVideo(id);
      await TorrentService.setProxy(host: 'h', port: 1, type: ProxyType.socks5);
      await TorrentService.setSslCertificate(
          certPath: '/c', privateKeyPath: '/k');
      expect(TorrentService.getRecentAlerts(), isEmpty);
      expect(await TorrentService.getPeers(id), isEmpty);
    });

    test('createTorrent and loadIpFilter delegate to native', () async {
      final output = await TorrentService.createTorrent(
        sourcePath: tempDir.path,
        outputPath: '${tempDir.path}/out.torrent',
        trackers: const ['udp://t'],
      );
      expect(output, '${tempDir.path}/out.torrent');

      expect(await TorrentService.loadIpFilter('${tempDir.path}/missing'),
          isFalse);
      final ipFile = File('${tempDir.path}/ip.dat');
      await ipFile.writeAsString('x');
      expect(await TorrentService.loadIpFilter(ipFile.path), isTrue);
    });

    test('downloadAndApplyBlocklist fails gracefully offline', () async {
      final result = await TorrentService.downloadAndApplyBlocklist(
        'http://127.0.0.1:1/blocklist.p2p',
      );
      expect(result, isFalse);
    });

    test('hasResumeData returns false with no saved data', () async {
      expect(await TorrentService.hasResumeData('https://none'), isFalse);
    });

    test('autoSaveResumeData persists active torrents', () async {
      final id = TorrentService.addMagnet(
          'magnet:?xt=urn:btih:auto-save', tempDir.path);
      await seed(id);
      await TorrentService.autoSaveResumeData();
      expect(native.saveResumeDataCallCount, greaterThanOrEqualTo(1));
    });

    test('TorrentServiceImpl delegates to the static bridge', () async {
      final impl = TorrentServiceImpl();
      expect(impl.isSupported, isTrue);
      expect(impl.nativeVersion, native.libraryVersion);
      expect(impl.activeTorrentIds, isEmpty);
      expect(await impl.hasResumeData('x'), isFalse);
    });
  });

  group('TorrentService (FFI) addMagnetWithMetadataTimeout', () {
    test('resolves once native metadata is present', () async {
      const magnet = 'magnet:?xt=urn:btih:meta-ready';
      final id = TorrentService.addMagnet(magnet, '/downloads/');
      native.seedTorrent(id: id, name: 'ready', files: files(1));

      final result = await TorrentService.addMagnetWithMetadataTimeout(
        magnet,
        '/downloads/',
        timeout: const Duration(seconds: 2),
        maxRetries: 0,
      );
      expect(result, id);
    });

    test('throws after the timeout with no metadata', () async {
      const magnet = 'magnet:?xt=urn:btih:never-meta';
      expect(
        TorrentService.addMagnetWithMetadataTimeout(
          magnet,
          tempDir.path,
          timeout: const Duration(milliseconds: 80),
          maxRetries: 0,
          retryDelay: const Duration(milliseconds: 5),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('TorrentService (FFI) extra branch coverage', () {
    test('init brings a disposed session back online', () async {
      await TorrentService.dispose();
      await TorrentService.init();
      expect(TorrentService.isInitialized, isTrue);
    });

    test('incompatible bridge is logged during init', () async {
      final bridge = FakeTorrentNative()
        ..fakeBridgeCompatible = false
        ..fakeBridgeDiagnostics = 'drift detected';
      TorrentService.setNativeForTesting(bridge);
      await TorrentService.dispose();
      await TorrentService.init();
      expect(TorrentService.bridgeDiagnostics, 'drift detected');
      expect(TorrentService.bridgeCompatible, isFalse);
    });

    test('all-capability bridge enables periodic resume save and sequential',
        () async {
      final caps = FakeTorrentNative()
        ..capabilities = const TorrentNativeCapabilities.all();
      TorrentService.setNativeForTesting(caps);
      expect(TorrentService.resumeDataSupported, isTrue);
      expect(TorrentService.sequentialDownloadSupported, isTrue);

      final id =
          TorrentService.addMagnet('magnet:?xt=urn:btih:caps', tempDir.path);
      await seed(id);
      TorrentService.configureSession(const TorrentSessionSettings(
        sequentialDownload: true,
      ));
      expect(TorrentService.sequentialDownloadEnabled, isTrue);
      expect(caps.lastConfig, isNotNull);
    });

    test('addMagnet with a different save path adds a second handle', () async {
      const magnet = 'magnet:?xt=urn:btih:diff-path';
      final id1 = TorrentService.addMagnet(magnet, tempDir.path);
      await seed(id1);
      final id2 = TorrentService.addMagnet(magnet, '/somewhere/else');
      expect(id2, isNot(id1));
    });

    test('addMagnet drops a stale mapping to a dead handle', () async {
      const magnet = 'magnet:?xt=urn:btih:stale-map';
      final id = TorrentService.addMagnet(magnet, tempDir.path);
      native.removeTorrent(id); // kill the native handle only
      final fresh = TorrentService.addMagnet(magnet, tempDir.path);
      expect(fresh, isNot(id));
    });

    test('removeTorrent with deleteFiles on a dead handle logs only', () async {
      const magnet = 'magnet:?xt=urn:btih:dead-del';
      final id = TorrentService.addMagnet(magnet, tempDir.path);
      native.removeTorrent(id);
      TorrentService.removeTorrent(id,
          deleteFiles: true, deleteResumeData: true);
      expect(TorrentService.isTorrentAlive(id), isFalse);
    });

    test('addTorrentFile caches supplied resume data', () async {
      final path = '${tempDir.path}/resume.torrent';
      await File(path).writeAsBytes([1, 2, 3]);
      final id = TorrentService.addTorrentFile(
        path,
        tempDir.path,
        resumeData: const [9, 9, 9],
      );
      expect(TorrentService.resumeBlobFor(id), isNotNull);
    });

    test('addTorrentFile without resume data attempts a fast-resume load',
        () async {
      final path = '${tempDir.path}/noresume.torrent';
      await File(path).writeAsBytes([1, 2, 3]);
      final id = TorrentService.addTorrentFile(path, tempDir.path);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(id, greaterThan(0));
    });

    test('resumeTorrent swallows native failures', () async {
      TorrentService.setNativeForTesting(_ThrowingResumeNative());
      final id =
          TorrentService.addMagnet('magnet:?xt=urn:btih:res-err', tempDir.path);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await TorrentService.resumeTorrent(id);
    });

    test('forceStopTorrent falls back to a native remove on pause failure',
        () async {
      final throwing = _ThrowingPauseNative();
      TorrentService.setNativeForTesting(throwing);
      final id = TorrentService.addMagnet(
          'magnet:?xt=urn:btih:stop-err', tempDir.path);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await TorrentService.forceStopTorrent(id);
      expect(throwing.pauseAttempts, greaterThanOrEqualTo(1));
    });

    test('shouldStopSeeding covers the ratio, time and idle paths', () {
      expect(
        TorrentService.shouldStopSeeding(
          progress: 0.5,
          uploadedBytes: 0,
          downloadedBytes: 0,
          shareRatioLimit: 1,
          maxSeedingMinutes: 0,
        ),
        isFalse,
      );
      expect(
        TorrentService.shouldStopSeeding(
          progress: 1.0,
          uploadedBytes: 200,
          downloadedBytes: 100,
          shareRatioLimit: 1.5,
          maxSeedingMinutes: 0,
        ),
        isTrue,
      );
      expect(
        TorrentService.shouldStopSeeding(
          progress: 1.0,
          uploadedBytes: 0,
          downloadedBytes: 100,
          shareRatioLimit: 0,
          maxSeedingMinutes: 10,
          seedingDuration: const Duration(minutes: 11),
        ),
        isTrue,
      );
      expect(
        TorrentService.shouldStopSeeding(
          progress: 1.0,
          uploadedBytes: 0,
          downloadedBytes: 100,
          shareRatioLimit: 0,
          maxSeedingMinutes: 0,
        ),
        isFalse,
      );
    });

    test('autoEnableSequentialForVideo detects large video files', () async {
      final caps = FakeTorrentNative()
        ..capabilities = const TorrentNativeCapabilities.all();
      TorrentService.setNativeForTesting(caps);
      caps.seedTorrent(
        id: 500,
        name: 'movie',
        files: [
          const NativeFileInfo(
            index: 0,
            name: 'movie.mp4',
            path: '/movie.mp4',
            size: 200 * 1024 * 1024,
            isStreamable: true,
          ),
        ],
      );
      TorrentService.autoEnableSequentialForVideo(500);
      // No throw is the assertion; the native setter is a no-op recorder.
    });
  });

  group('TorrentServiceImpl exhaustive delegation', () {
    test('forwards every interface method to the static bridge', () async {
      final impl = TorrentServiceImpl();
      final id = TorrentService.addMagnet(
          'magnet:?xt=urn:btih:impl-all', tempDir.path);
      await seed(id, fileCount: 2);

      expect(impl.isSupported, isTrue);
      expect(impl.isInitialized, isTrue);
      await impl.ready;
      expect(impl.isAvailable.value, isFalse);
      expect(impl.activeTorrentIds, contains(id));
      expect(impl.progressFor(id), isA<double>());
      impl.fetchResumeBytes(id);
      impl.resumeBlobFor(id);
      expect(impl.fileProgressSupported, isFalse);
      expect(impl.filePrioritiesSupported, isFalse);
      expect(impl.resumeDataSupported, isFalse);
      expect(impl.forceRecheckSupported, isTrue);
      expect(impl.trackersSupported, isFalse);
      expect(impl.createTorrentSupported, isFalse);
      expect(impl.ipFilterSupported, isFalse);
      expect(impl.sequentialDownloadSupported, isFalse);
      expect(impl.superSeedingSupported, isFalse);
      expect(impl.pieceDeadlineSupported, isFalse);
      expect(impl.sequentialDownloadEnabled, isFalse);
      expect(impl.seedingEnabled, isTrue);
      expect(impl.shareRatioLimit, isA<double>());
      expect(impl.maxSeedingTimeMinutes, isA<int>());

      await impl.hasResumeData('x');
      await impl.init();
      await impl.saveResumeData(id);
      await impl.saveAllResumeData();
      expect(impl.addMagnet('magnet:?xt=urn:btih:impl-m2', tempDir.path),
          greaterThan(0));
      try {
        await impl.addMagnetWithMetadataTimeout(
          'magnet:?xt=urn:btih:impl-m3',
          tempDir.path,
          timeout: const Duration(milliseconds: 40),
          maxRetries: 0,
        );
      } catch (_) {}
      impl.addTorrentFile('${tempDir.path}/x.torrent', tempDir.path);
      impl.removeTorrent(id);
      await impl.pauseTorrent(id);
      await impl.resumeTorrent(id);
      impl.loadResumeData(id, const [1, 2]);
      impl.isTorrentAlive(id);
      impl.recheckTorrent(id);
      impl.setFilePriorities(id, const [4, 4]);
      impl.getFileCount(id);
      impl.setUploadLimit(1);
      impl.setDownloadLimit(1);
      impl.getFiles(id);
      expect(impl.torrentUpdates, isA<Stream>());
      expect(impl.latestStats, isA<Map>());
      impl.idForSource('x');
      expect(impl.getTorrentSnapshot(id), isNull);
      expect(impl.nativeVersion, native.libraryVersion);
      impl.configureSession();
      impl.reconfigureSession();
      impl.autoEnableSequentialForVideo(id);
      await impl.autoSaveResumeData();
      impl.getTrackers(id);
      impl.addTracker(id, 'udp://t');
      impl.removeTracker(id, 'udp://t');
      impl.announceNow(id);
      impl.boostMagnetDiscovery(id);
      await impl.createTorrent(
        sourcePath: tempDir.path,
        outputPath: '${tempDir.path}/o.torrent',
        trackers: const [],
      );
      await impl.loadIpFilter('${tempDir.path}/missing');
      await impl.downloadAndApplyBlocklist('http://127.0.0.1:1/x');
      impl.enableSequentialDownload(id, true);
      impl.setSequentialDownload(id, true);
      impl.prioritizeFile(id, 0);
      impl.setPieceDeadline(id, 0, 1);
      impl.enableSuperSeeding(id, true);
      expect(impl.alertUpdates, isA<Stream>());
      expect(impl.getRecentAlerts(), isEmpty);
      await impl.getAccurateFileProgress(id, tempDir.path);
      await impl.getPieceProgress(id);
      await impl.getPeers(id);
      await impl.setProxy(host: 'h', port: 1, type: ProxyType.socks5);
      await impl.setSslCertificate(certPath: '/c', privateKeyPath: '/k');
      impl.addWebSeed(id, 'https://s');
      impl.removeWebSeed(id, 'https://s');
      impl.getWebSeeds(id);
      expect(impl.shouldStopSeeding(progress: 1, uploadedBytes: 0), isFalse);
      await impl.dispose();
    });
  });

  group('TorrentServiceStub exhaustive contract', () {
    test('implements the full inert contract', () async {
      final stub = TorrentServiceStub();
      expect(stub.isSupported, isFalse);
      expect(stub.isInitialized, isFalse);
      await stub.ready;
      expect(stub.isAvailable.value, isFalse);
      expect(stub.activeTorrentIds, isEmpty);
      expect(stub.progressFor(1), 0.0);
      expect(stub.fetchResumeBytes(1), isNull);
      expect(stub.resumeBlobFor(1), isNull);
      expect(stub.fileProgressSupported, isFalse);
      expect(stub.filePrioritiesSupported, isFalse);
      expect(stub.resumeDataSupported, isFalse);
      expect(stub.forceRecheckSupported, isFalse);
      expect(stub.trackersSupported, isFalse);
      expect(stub.createTorrentSupported, isFalse);
      expect(stub.ipFilterSupported, isFalse);
      expect(stub.sequentialDownloadSupported, isFalse);
      expect(stub.superSeedingSupported, isFalse);
      expect(stub.pieceDeadlineSupported, isFalse);
      expect(stub.sequentialDownloadEnabled, isFalse);
      expect(stub.seedingEnabled, isTrue);
      expect(stub.shareRatioLimit, 2.0);
      expect(stub.maxSeedingTimeMinutes, 0);

      await stub.hasResumeData('x');
      await stub.init();
      await stub.saveResumeData(1);
      await stub.saveAllResumeData();
      expect(stub.addMagnet('magnet:?xt=x', '/tmp'), -1);
      expect(
        await stub.addMagnetWithMetadataTimeout('magnet:?xt=x', '/tmp'),
        -1,
      );
      expect(stub.addTorrentFile('/a', '/tmp'), -1);
      stub.removeTorrent(1);
      await stub.pauseTorrent(1);
      await stub.forceStopTorrent(1);
      await stub.resumeTorrent(1);
      expect(stub.loadResumeData(1, const [1]), isFalse);
      expect(stub.isTorrentAlive(1), isFalse);
      stub.recheckTorrent(1);
      stub.setFilePriorities(1, const [1]);
      expect(stub.getFileCount(1), 0);
      stub.setUploadLimit(1);
      stub.setDownloadLimit(1);
      expect(stub.getFiles(1), isEmpty);
      expect(stub.torrentUpdates, emitsDone);
      expect(stub.latestStats, isEmpty);
      expect(stub.idForSource('x'), isNull);
      expect(stub.getTorrentSnapshot(1), isNull);
      expect(stub.nativeVersion, 'stub');
      stub.configureSession();
      stub.reconfigureSession();
      stub.autoEnableSequentialForVideo(1);
      await stub.autoSaveResumeData();
      expect(stub.getTrackers(1), isEmpty);
      stub.addTracker(1, 'udp://t');
      stub.removeTracker(1, 'udp://t');
      stub.announceNow(1);
      stub.boostMagnetDiscovery(1);
      expect(
        await stub.createTorrent(
          sourcePath: '/a',
          outputPath: '/b',
          trackers: const [],
        ),
        isNull,
      );
      expect(await stub.loadIpFilter('/f'), isFalse);
      expect(await stub.downloadAndApplyBlocklist('https://x'), isFalse);
      stub.enableSequentialDownload(1, true);
      stub.setSequentialDownload(1, true);
      stub.prioritizeFile(1, 0);
      stub.setPieceDeadline(1, 0, 1);
      stub.enableSuperSeeding(1, true);
      expect(stub.alertUpdates, emitsDone);
      expect(stub.getRecentAlerts(), isEmpty);
      expect(await stub.getAccurateFileProgress(1, '/tmp'), isEmpty);
      expect(await stub.getPieceProgress(1), isNull);
      expect(await stub.getPeers(1), isEmpty);
      await stub.setProxy(host: 'h', port: 1, type: ProxyType.socks5);
      await stub.setSslCertificate(certPath: '/c', privateKeyPath: '/k');
      stub.addWebSeed(1, 'https://s');
      stub.removeWebSeed(1, 'https://s');
      expect(stub.getWebSeeds(1), isEmpty);
      expect(stub.shouldStopSeeding(progress: 1, uploadedBytes: 0), isFalse);
    });
  });
}

class _ThrowingResumeNative extends FakeTorrentNative {
  @override
  Future<void> resumeTorrent(int id) async {
    throw StateError('resume failed');
  }
}

class _ThrowingPauseNative extends FakeTorrentNative {
  int pauseAttempts = 0;

  @override
  Future<void> pauseTorrent(int id, {bool graceful = true}) async {
    pauseAttempts++;
    throw StateError('pause failed');
  }
}
