import 'dart:typed_data';

import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/torrent_service_stub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TorrentService static stub surface', () {
    test('capability and state getters are inert', () async {
      expect(TorrentService.isSupported, isFalse);
      expect(TorrentService.isInitialized, isFalse);
      await TorrentService.ready;
      expect(TorrentService.isAvailable.value, isFalse);
      expect(TorrentService.alertUpdates, emitsDone);
      expect(TorrentService.activeTorrentIds, isEmpty);
      expect(TorrentService.progressFor(1), 0.0);
      expect(TorrentService.fetchResumeBytes(1), isNull);
      expect(TorrentService.resumeBlobFor(1), isNull);
      expect(TorrentService.sequentialDownloadEnabled, isFalse);
      expect(TorrentService.shareRatioLimit, 2.0);
      expect(TorrentService.maxSeedingTimeMinutes, 0);
      expect(TorrentService.bridgeCompatible, isTrue);
      expect(TorrentService.bridgeDiagnostics, isNull);
      expect(TorrentService.nativeVersion, 'stub');
      expect(TorrentService.seedingEnabled, isTrue);
    });

    test('capability flags derive from the pinned 1.9.2 matrix', () {
      expect(TorrentService.fileProgressSupported, isFalse);
      expect(TorrentService.filePrioritiesSupported, isFalse);
      expect(TorrentService.resumeDataSupported, isFalse);
      expect(TorrentService.trackersSupported, isFalse);
      expect(TorrentService.createTorrentSupported, isFalse);
      expect(TorrentService.ipFilterSupported, isFalse);
      expect(TorrentService.sequentialDownloadSupported, isFalse);
      expect(TorrentService.superSeedingSupported, isFalse);
      expect(TorrentService.pieceDeadlineSupported, isFalse);
      expect(TorrentService.webSeedsSupported, isFalse);
      expect(TorrentService.proxySupported, isFalse);
      expect(TorrentService.sslSupported, isFalse);
      expect(TorrentService.peerExchangeSupported, isFalse);
      expect(TorrentService.localPeerDiscoverySupported, isFalse);
      expect(TorrentService.natPmpSupported, isFalse);
      expect(TorrentService.anonymousModeSupported, isFalse);
      expect(TorrentService.perTorrentConnectionLimitSupported, isFalse);
    });

    test('lifecycle and mutation methods are no-ops', () async {
      await TorrentService.init();
      await TorrentService.saveResumeData(1);
      await TorrentService.saveAllResumeData();
      await TorrentService.dispose();
      expect(TorrentService.addMagnet('magnet:?xt=urn:btih:x', '/tmp'), -1);
      expect(
        await TorrentService.addMagnetWithMetadataTimeout(
            'magnet:?xt=x', '/tmp'),
        -1,
      );
      expect(TorrentService.addTorrentFile('/a.torrent', '/tmp'), -1);
      TorrentService.removeTorrent(1,
          deleteFiles: true, deleteResumeData: true);
      await TorrentService.pauseTorrent(1);
      await TorrentService.forceStopTorrent(1);
      await TorrentService.resumeTorrent(1);
      expect(TorrentService.loadResumeData(1, const [1, 2]), isFalse);
      expect(TorrentService.isTorrentAlive(1), isFalse);
      TorrentService.recheckTorrent(1);
      TorrentService.setFilePriorities(1, const [1]);
      expect(TorrentService.getFileCount(1), 0);
      TorrentService.setUploadLimit(1);
      TorrentService.setDownloadLimit(1);
      expect(TorrentService.getFiles(1), isEmpty);
      expect(TorrentService.getFilesCached(1), isEmpty);
      expect(TorrentService.getTorrentStatus(1), isNull);
      expect(TorrentService.getFileProgress(1), isEmpty);
      expect(TorrentService.torrentUpdates, emitsDone);
      expect(TorrentService.latestStats, isEmpty);
      expect(TorrentService.idForSource('x'), isNull);
      TorrentService.configureSession();
      TorrentService.reconfigureSession();
    });

    test('tracker, seed, proxy and blocklist methods are inert', () async {
      expect(TorrentService.getTrackers(1), isEmpty);
      TorrentService.addTracker(1, 'udp://tracker');
      TorrentService.removeTracker(1, 'udp://tracker');
      TorrentService.announceNow(1);
      TorrentService.boostMagnetDiscovery(1);
      expect(
        await TorrentService.createTorrent(
          sourcePath: '/a',
          outputPath: '/b',
          trackers: const ['udp://t'],
        ),
        isNull,
      );
      expect(await TorrentService.loadIpFilter('/f'), isFalse);
      expect(
          await TorrentService.downloadAndApplyBlocklist('https://x'), isFalse);
      TorrentService.enableSequentialDownload(1, true);
      TorrentService.setPieceDeadline(1, 0, 1000);
      TorrentService.enableSuperSeeding(1, true);
      expect(
        await TorrentService.getAccurateFileProgress(1, '/tmp'),
        isEmpty,
      );
      TorrentService.addWebSeed(1, 'https://seed');
      TorrentService.removeWebSeed(1, 'https://seed');
      expect(TorrentService.getWebSeeds(1), isEmpty);
      await TorrentService.setProxy(
        host: 'h',
        port: 1,
        type: ProxyType.socks5,
      );
      await TorrentService.setSslCertificate(
        certPath: '/c',
        privateKeyPath: '/k',
      );
      expect(await TorrentService.getPieceProgress(1), isNull);
      expect(await TorrentService.getPeers(1), isEmpty);
      expect(TorrentService.getRecentAlerts(), isEmpty);
      TorrentService.setSequentialDownload(1, true);
      TorrentService.prioritizeFile(1, 0);
      TorrentService.autoEnableSequentialForVideo(1);
      await TorrentService.autoSaveResumeData();
      expect(TorrentService.getTorrentSnapshot(1), isNull);
      expect(await TorrentService.hasResumeData('x'), isFalse);
    });

    test('shouldStopSeeding implements the ratio and time policies', () {
      // Not yet complete -> never stop.
      expect(
        TorrentService.shouldStopSeeding(
          progress: 0.5,
          uploadedBytes: 999,
          downloadedBytes: 0,
          shareRatioLimit: 1.0,
          maxSeedingMinutes: 0,
        ),
        isFalse,
      );

      // Ratio exceeded.
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

      // Max seeding time exceeded.
      expect(
        TorrentService.shouldStopSeeding(
          progress: 1.0,
          uploadedBytes: 0,
          downloadedBytes: 100,
          shareRatioLimit: 0,
          maxSeedingMinutes: 1,
          completedAt: DateTime.now().subtract(const Duration(hours: 1)),
        ),
        isTrue,
      );

      // Otherwise keep seeding.
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
  });

  group('TorrentServiceImpl (stub) satisfies the contract', () {
    test('exposes inert values', () async {
      final ITorrentService impl = TorrentServiceImpl();
      expect(impl.isSupported, isFalse);
      expect(impl.isInitialized, isFalse);
      await impl.ready;
      expect(impl.activeTorrentIds, isEmpty);
      expect(impl.progressFor(1), 0.0);
      expect(impl.fetchResumeBytes(1), isNull);
      expect(impl.resumeBlobFor(1), isNull);
      expect(impl.nativeVersion, 'stub');
      expect(impl.addMagnet('magnet:?xt=x', '/tmp'), -1);
      expect(impl.addTorrentFile('/a', '/tmp'), -1);
      expect(impl.getFiles(1), isEmpty);
      expect(impl.latestStats, isEmpty);
      expect(impl.torrentUpdates, emitsDone);
      expect(impl.alertUpdates, emitsDone);
      expect(impl.seedingEnabled, isTrue);
      expect(impl.shareRatioLimit, 2.0);
      expect(impl.maxSeedingTimeMinutes, 0);
      expect(impl.getTrackers(1), isEmpty);
      expect(impl.getWebSeeds(1), isEmpty);
      expect(await impl.getPeers(1), isEmpty);
      expect(await impl.getPieceProgress(1), isNull);
      expect(
          await impl.createTorrent(
            sourcePath: '/a',
            outputPath: '/b',
            trackers: const [],
          ),
          isNull);
      expect(await impl.loadIpFilter('/f'), isFalse);
      expect(await impl.downloadAndApplyBlocklist('https://x'), isFalse);
      expect(await impl.getAccurateFileProgress(1, '/tmp'), isEmpty);
      expect(
        impl.shouldStopSeeding(progress: 1, uploadedBytes: 0),
        isFalse,
      );
      expect(impl.getTorrentSnapshot(1), isNull);
    });
  });

  group('TorrentServiceStub satisfies the contract', () {
    test('exposes inert values', () async {
      final ITorrentService stub = TorrentServiceStub();
      expect(stub.isSupported, isFalse);
      expect(stub.isInitialized, isFalse);
      await stub.ready;
      expect(stub.isAvailable.value, isFalse);
      expect(stub.activeTorrentIds, isEmpty);
      expect(stub.progressFor(1), 0.0);
      expect(stub.nativeVersion, 'stub');
      expect(stub.addMagnet('magnet:?xt=x', '/tmp'), -1);
      expect(stub.addTorrentFile('/a', '/tmp'), -1);
      expect(stub.getFiles(1), isEmpty);
      expect(stub.latestStats, isEmpty);
      expect(stub.torrentUpdates, emitsDone);
      expect(stub.alertUpdates, emitsDone);
      expect(stub.getTrackers(1), isEmpty);
      expect(stub.getWebSeeds(1), isEmpty);
      expect(await stub.getPeers(1), isEmpty);
      expect(await stub.getPieceProgress(1), isNull);
      expect(
        stub.shouldStopSeeding(progress: 1, uploadedBytes: 0),
        isFalse,
      );
      expect(stub.getTorrentSnapshot(1), isNull);
      expect(stub.getRecentAlerts(), isEmpty);
    });
  });

  test('Uint8List import keeps the resume surface typed', () {
    final Uint8List? bytes = TorrentService.resumeBlobFor(1);
    expect(bytes, isNull);
  });

  group('TorrentServiceImpl (stub) exhaustive contract', () {
    test('implements the full inert contract', () async {
      final impl = TorrentServiceImpl();
      expect(impl.isSupported, isFalse);
      expect(impl.isInitialized, isFalse);
      await impl.ready;
      expect(impl.isAvailable.value, isFalse);
      expect(impl.activeTorrentIds, isEmpty);
      expect(impl.progressFor(1), 0.0);
      expect(impl.fetchResumeBytes(1), isNull);
      expect(impl.resumeBlobFor(1), isNull);
      expect(impl.fileProgressSupported, isFalse);
      expect(impl.filePrioritiesSupported, isFalse);
      expect(impl.resumeDataSupported, isFalse);
      expect(impl.forceRecheckSupported, isFalse);
      expect(impl.trackersSupported, isFalse);
      expect(impl.createTorrentSupported, isFalse);
      expect(impl.ipFilterSupported, isFalse);
      expect(impl.sequentialDownloadSupported, isFalse);
      expect(impl.superSeedingSupported, isFalse);
      expect(impl.pieceDeadlineSupported, isFalse);
      expect(impl.sequentialDownloadEnabled, isFalse);
      expect(impl.seedingEnabled, isTrue);
      expect(impl.shareRatioLimit, 2.0);
      expect(impl.maxSeedingTimeMinutes, 0);

      await impl.hasResumeData('x');
      await impl.init();
      await impl.saveResumeData(1);
      await impl.saveAllResumeData();
      expect(impl.addMagnet('magnet:?xt=x', '/tmp'), -1);
      expect(
        await impl.addMagnetWithMetadataTimeout('magnet:?xt=x', '/tmp'),
        -1,
      );
      expect(impl.addTorrentFile('/a', '/tmp'), -1);
      impl.removeTorrent(1);
      await impl.pauseTorrent(1);
      await impl.forceStopTorrent(1);
      await impl.resumeTorrent(1);
      expect(impl.loadResumeData(1, const [1]), isFalse);
      expect(impl.isTorrentAlive(1), isFalse);
      impl.recheckTorrent(1);
      impl.setFilePriorities(1, const [1]);
      expect(impl.getFileCount(1), 0);
      impl.setUploadLimit(1);
      impl.setDownloadLimit(1);
      expect(impl.getFiles(1), isEmpty);
      expect(impl.torrentUpdates, emitsDone);
      expect(impl.latestStats, isEmpty);
      expect(impl.idForSource('x'), isNull);
      expect(impl.getTorrentSnapshot(1), isNull);
      expect(impl.nativeVersion, 'stub');
      impl.configureSession();
      impl.reconfigureSession();
      impl.autoEnableSequentialForVideo(1);
      await impl.autoSaveResumeData();
      expect(impl.getTrackers(1), isEmpty);
      impl.addTracker(1, 'udp://t');
      impl.removeTracker(1, 'udp://t');
      impl.announceNow(1);
      impl.boostMagnetDiscovery(1);
      expect(
        await impl.createTorrent(
          sourcePath: '/a',
          outputPath: '/b',
          trackers: const [],
        ),
        isNull,
      );
      expect(await impl.loadIpFilter('/f'), isFalse);
      expect(await impl.downloadAndApplyBlocklist('https://x'), isFalse);
      impl.enableSequentialDownload(1, true);
      impl.setSequentialDownload(1, true);
      impl.prioritizeFile(1, 0);
      impl.setPieceDeadline(1, 0, 1);
      impl.enableSuperSeeding(1, true);
      expect(impl.alertUpdates, emitsDone);
      expect(impl.getRecentAlerts(), isEmpty);
      expect(await impl.getAccurateFileProgress(1, '/tmp'), isEmpty);
      expect(await impl.getPieceProgress(1), isNull);
      expect(await impl.getPeers(1), isEmpty);
      await impl.setProxy(host: 'h', port: 1, type: ProxyType.socks5);
      await impl.setSslCertificate(certPath: '/c', privateKeyPath: '/k');
      impl.addWebSeed(1, 'https://s');
      impl.removeWebSeed(1, 'https://s');
      expect(impl.getWebSeeds(1), isEmpty);
      expect(impl.shouldStopSeeding(progress: 1, uploadedBytes: 0), isFalse);
      await impl.dispose();
    });
  });

  group('TorrentServiceStub (stub) exhaustive contract', () {
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
