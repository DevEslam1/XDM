// ignore_for_file: avoid_print

import 'package:dmx/core/services/torrent_models.dart';
import 'package:dmx/core/services/torrent_service_stub.dart';
import 'package:dmx/core/services/torrent_session_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';

void main() {
  // ---------------------------------------------------------------------------
  // TorrentService (stub) — API surface
  // ---------------------------------------------------------------------------
  group('TorrentService stub — API surface', () {
    test('isSupported is false',
        () => expect(TorrentService.isSupported, isFalse));
    test('isInitialized is false',
        () => expect(TorrentService.isInitialized, isFalse));
    test('isAvailable.value is false',
        () => expect(TorrentService.isAvailable.value, isFalse));
    test('activeTorrentIds is empty',
        () => expect(TorrentService.activeTorrentIds, isEmpty));
    test('progressFor returns 0.0',
        () => expect(TorrentService.progressFor(0), 0.0));
    test('fetchResumeBytes returns null',
        () => expect(TorrentService.fetchResumeBytes(0), isNull));
    test('resumeBlobFor returns null',
        () => expect(TorrentService.resumeBlobFor(0), isNull));
    test('addMagnet returns -1',
        () => expect(TorrentService.addMagnet('magnet:?xt=...', '/tmp'), -1));
    test(
        'addTorrentFile returns -1',
        () =>
            expect(TorrentService.addTorrentFile('/a/b.torrent', '/tmp'), -1));
    test('isTorrentAlive returns false',
        () => expect(TorrentService.isTorrentAlive(1), isFalse));
    test('getFileCount returns 0',
        () => expect(TorrentService.getFileCount(0), 0));
    test('getFiles returns empty list',
        () => expect(TorrentService.getFiles(0), isEmpty));
    test('latestStats is empty map',
        () => expect(TorrentService.latestStats, isEmpty));
    test('torrentUpdates is a stream',
        () => expect(TorrentService.torrentUpdates, isNotNull));
    test('getTrackers returns empty list',
        () => expect(TorrentService.getTrackers(0), isEmpty));
    test('getWebSeeds returns empty list',
        () => expect(TorrentService.getWebSeeds(0), isEmpty));
    test('sequentialDownloadEnabled is false',
        () => expect(TorrentService.sequentialDownloadEnabled, isFalse));
    test('shareRatioLimit default is 2.0',
        () => expect(TorrentService.shareRatioLimit, 2.0));
    test('maxSeedingTimeMinutes default is 0',
        () => expect(TorrentService.maxSeedingTimeMinutes, 0));
    test('fileProgressSupported is false',
        () => expect(TorrentService.fileProgressSupported, isFalse));
    test('filePrioritiesSupported is false',
        () => expect(TorrentService.filePrioritiesSupported, isFalse));
    test('resumeDataSupported is false',
        () => expect(TorrentService.resumeDataSupported, isFalse));
    test('seedingEnabled is true',
        () => expect(TorrentService.seedingEnabled, isTrue));
    test('init() completes',
        () async => await expectLater(TorrentService.init(), completes));
    test('dispose() completes',
        () async => await expectLater(TorrentService.dispose(), completes));
    test(
        'saveResumeData() completes',
        () async =>
            await expectLater(TorrentService.saveResumeData(0), completes));
    test(
        'saveAllResumeData() completes',
        () async =>
            await expectLater(TorrentService.saveAllResumeData(), completes));
    test(
        'hasResumeData() returns false',
        () async =>
            expect(await TorrentService.hasResumeData('magnet:?'), isFalse));
    test('createTorrent() returns null', () async {
      expect(
          await TorrentService.createTorrent(
              sourcePath: '/tmp', outputPath: '/out.torrent', trackers: []),
          isNull);
    });
    test(
        'loadIpFilter() returns false',
        () async =>
            expect(await TorrentService.loadIpFilter('/tmp/b.p2p'), isFalse));
    test('downloadAndApplyBlocklist() returns false', () async {
      expect(
          await TorrentService.downloadAndApplyBlocklist(
              'https://example.com/bl.p2p'),
          isFalse);
    });
    test('addMagnetWithMetadataTimeout() returns -1', () async {
      expect(
          await TorrentService.addMagnetWithMetadataTimeout(
              'magnet:?xt=...', '/tmp',
              timeout: const Duration(milliseconds: 10)),
          -1);
    });
  });

  // ---------------------------------------------------------------------------
  // TorrentSettingsPack — construction, copyWith, toMap/fromMap
  // ---------------------------------------------------------------------------
  group('TorrentSettingsPack', () {
    const pack = TorrentSettingsPack(
      enableDht: true,
      enableLsd: false,
      enablePex: true,
      enableUpnp: true,
      maxConnectionsGlobal: 300,
      maxDownloadRate: 2097152,
      maxUploadRate: 524288,
      forceEncrypt: true,
      enableUtp: true,
      enableTcp: true,
      socks5ProxyHost: '10.0.0.1',
      socks5ProxyPort: 9050,
      enforceProxy: true,
      cacheSize: 268435456,
    );

    test('fields are set correctly', () {
      expect(pack.enableDht, isTrue);
      expect(pack.enableLsd, isFalse);
      expect(pack.enablePex, isTrue);
      expect(pack.enableUpnp, isTrue);
      expect(pack.maxConnectionsGlobal, 300);
      expect(pack.maxDownloadRate, 2097152);
      expect(pack.maxUploadRate, 524288);
      expect(pack.forceEncrypt, isTrue);
      expect(pack.enableUtp, isTrue);
      expect(pack.enableTcp, isTrue);
      expect(pack.socks5ProxyHost, '10.0.0.1');
      expect(pack.socks5ProxyPort, 9050);
      expect(pack.enforceProxy, isTrue);
      expect(pack.cacheSize, 268435456);
    });

    test('copyWith overrides single field', () {
      final modified = pack.copyWith(enableDht: false);
      expect(modified.enableDht, isFalse);
      expect(modified.maxConnectionsGlobal, 300);
    });

    test('copyWith all fields', () {
      final all = pack.copyWith(
        enableDht: false,
        enableLsd: true,
        enablePex: false,
        enableUpnp: false,
        maxConnectionsGlobal: 50,
        maxDownloadRate: 1024,
        maxUploadRate: 512,
        socks5ProxyHost: 'newproxy',
        socks5ProxyPort: 1080,
        enforceProxy: false,
        forceEncrypt: false,
        enableUtp: false,
        enableTcp: false,
        cacheSize: 67108864,
      );
      expect(all.enableDht, isFalse);
      expect(all.enableLsd, isTrue);
      expect(all.maxConnectionsGlobal, 50);
      expect(all.socks5ProxyHost, 'newproxy');
      expect(all.cacheSize, 67108864);
    });

    test('toMap produces correct keys', () {
      final map = pack.toMap();
      expect(map['enableDht'], isTrue);
      expect(map['enableLsd'], isFalse);
      expect(map['maxConnectionsGlobal'], 300);
      expect(map['forceEncrypt'], isTrue);
      expect(map['socks5ProxyHost'], '10.0.0.1');
      expect(map['socks5ProxyPort'], 9050);
      expect(map['cacheSize'], 268435456);
    });

    test('fromMap round-trips correctly', () {
      final restored = TorrentSettingsPack.fromMap(pack.toMap());
      expect(restored.enableDht, pack.enableDht);
      expect(restored.enableLsd, pack.enableLsd);
      expect(restored.maxConnectionsGlobal, pack.maxConnectionsGlobal);
      expect(restored.maxDownloadRate, pack.maxDownloadRate);
      expect(restored.forceEncrypt, pack.forceEncrypt);
      expect(restored.socks5ProxyHost, pack.socks5ProxyHost);
      expect(restored.cacheSize, pack.cacheSize);
    });

    test('fromMap with empty map uses defaults', () {
      final minimal = TorrentSettingsPack.fromMap({});
      expect(minimal.enableDht, isTrue);
      expect(minimal.enableUtp, isTrue);
      expect(minimal.forceEncrypt, isFalse);
      expect(minimal.enforceProxy, isFalse);
      expect(minimal.maxConnectionsGlobal, isNull);
      expect(minimal.cacheSize, isNull);
    });

    test('default constructor has sensible defaults', () {
      const def = TorrentSettingsPack();
      expect(def.enableDht, isTrue);
      expect(def.enableUtp, isTrue);
      expect(def.forceEncrypt, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // TorrentSessionConfig.buildBtConfigFromPack
  // ---------------------------------------------------------------------------
  group('TorrentSessionConfig.buildBtConfigFromPack', () {
    test('DHT enabled -> disableDht false', () {
      const cfg = TorrentSettingsPack(enableDht: true);
      expect(
          TorrentSessionConfig.buildBtConfigFromPack(cfg,
                  baseConfig: const BtConfig())
              .disableDht,
          isFalse);
    });
    test('DHT disabled -> disableDht true', () {
      const cfg = TorrentSettingsPack(enableDht: false);
      expect(
          TorrentSessionConfig.buildBtConfigFromPack(cfg,
                  baseConfig: const BtConfig())
              .disableDht,
          isTrue);
    });
    test('UPnP disabled -> disableUpnp true', () {
      const cfg = TorrentSettingsPack(enableUpnp: false);
      expect(
          TorrentSessionConfig.buildBtConfigFromPack(cfg,
                  baseConfig: const BtConfig())
              .disableUpnp,
          isTrue);
    });
    test('uTP disabled -> disableUtp true', () {
      const cfg = TorrentSettingsPack(enableUtp: false);
      expect(
          TorrentSessionConfig.buildBtConfigFromPack(cfg,
                  baseConfig: const BtConfig())
              .disableUtp,
          isTrue);
    });
    test('forceEncrypt propagates', () {
      const cfg = TorrentSettingsPack(forceEncrypt: true);
      expect(
          TorrentSessionConfig.buildBtConfigFromPack(cfg,
                  baseConfig: const BtConfig())
              .forceEncrypt,
          isTrue);
    });
    test('connectionsLimit is set', () {
      const cfg = TorrentSettingsPack(maxConnectionsGlobal: 500);
      expect(
          TorrentSessionConfig.buildBtConfigFromPack(cfg,
                  baseConfig: const BtConfig())
              .connectionsLimit,
          500);
    });
    test('downloadRateLimit converts bytes to KB', () {
      const cfg = TorrentSettingsPack(maxDownloadRate: 10485760); // 10 MB/s
      expect(
          TorrentSessionConfig.buildBtConfigFromPack(cfg,
                  baseConfig: const BtConfig())
              .downloadRateLimit,
          10240);
    });
    test('uploadRateLimit converts bytes to KB', () {
      const cfg = TorrentSettingsPack(maxUploadRate: 1048576); // 1 MB/s
      expect(
          TorrentSessionConfig.buildBtConfigFromPack(cfg,
                  baseConfig: const BtConfig())
              .uploadRateLimit,
          1024);
    });
    test('cacheSize propagates', () {
      const cfg = TorrentSettingsPack(cacheSize: 536870912);
      expect(
          TorrentSessionConfig.buildBtConfigFromPack(cfg,
                  baseConfig: const BtConfig())
              .cacheSize,
          536870912);
    });
  });

  // ---------------------------------------------------------------------------
  // TorrentService.shouldStopSeeding — static pure function
  // ---------------------------------------------------------------------------
  group('TorrentService.shouldStopSeeding', () {
    test('false when progress < 1 and no download', () {
      expect(
          TorrentService.shouldStopSeeding(
              progress: 0.5,
              uploadedBytes: 0,
              downloadedBytes: 0,
              shareRatioLimit: 2.0,
              maxSeedingMinutes: 60),
          isFalse);
    });
    test('true when share ratio exceeded', () {
      expect(
          TorrentService.shouldStopSeeding(
              progress: 1.0,
              uploadedBytes: 4000,
              downloadedBytes: 1000,
              shareRatioLimit: 2.0,
              maxSeedingMinutes: 0),
          isTrue);
    });
    test('false when ratio below limit', () {
      expect(
          TorrentService.shouldStopSeeding(
              progress: 1.0,
              uploadedBytes: 1000,
              downloadedBytes: 2000,
              shareRatioLimit: 2.0,
              maxSeedingMinutes: 0),
          isFalse);
    });
    test('true when max seeding time exceeded', () {
      final completedAt = DateTime.now().subtract(const Duration(hours: 3));
      expect(
          TorrentService.shouldStopSeeding(
              progress: 1.0,
              uploadedBytes: 100,
              downloadedBytes: 1000,
              shareRatioLimit: 0,
              maxSeedingMinutes: 60,
              completedAt: completedAt),
          isTrue);
    });
    test('false when seeding time below limit', () {
      final completedAt = DateTime.now().subtract(const Duration(minutes: 10));
      expect(
          TorrentService.shouldStopSeeding(
              progress: 1.0,
              uploadedBytes: 100,
              downloadedBytes: 1000,
              shareRatioLimit: 0,
              maxSeedingMinutes: 60,
              completedAt: completedAt),
          isFalse);
    });
    test('false when both limits disabled (0)', () {
      expect(
          TorrentService.shouldStopSeeding(
              progress: 1.0,
              uploadedBytes: 999999,
              downloadedBytes: 1,
              shareRatioLimit: 0,
              maxSeedingMinutes: 0),
          isFalse);
    });
    test('uses sentinel 1 when downloadedBytes is 0', () {
      expect(
          TorrentService.shouldStopSeeding(
              progress: 1.0,
              uploadedBytes: 3000,
              downloadedBytes: 0,
              shareRatioLimit: 2.0,
              maxSeedingMinutes: 0),
          isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // TorrentServiceStub.shouldStopSeeding — always false
  // ---------------------------------------------------------------------------
  group('TorrentServiceStub.shouldStopSeeding', () {
    final stub = TorrentServiceStub();
    test('false even when ratio exceeded', () {
      expect(
          stub.shouldStopSeeding(
              progress: 1.0,
              uploadedBytes: 99999,
              downloadedBytes: 100,
              shareRatioLimit: 0.5),
          isFalse);
    });
    test('false even when time exceeded', () {
      expect(
          stub.shouldStopSeeding(
              progress: 1.0,
              uploadedBytes: 0,
              downloadedBytes: 0,
              maxSeedingMinutes: 1,
              completedAt: DateTime.now().subtract(const Duration(hours: 1))),
          isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // TorrentUpdateInfo
  // ---------------------------------------------------------------------------
  group('TorrentUpdateInfo', () {
    test('constructs with required fields and has sensible defaults', () {
      final info = TorrentUpdateInfo(
          id: 42,
          name: 'Ubuntu.iso',
          progress: 0.75,
          downloadRate: 512000,
          uploadRate: 102400,
          totalDone: 786432000,
          totalWanted: 1048576000,
          totalWantedDone: 786432000,
          hasMetadata: true,
          stateLabel: 'downloading');
      expect(info.id, 42);
      expect(info.progress, 0.75);
      expect(info.hasMetadata, isTrue);
      expect(info.numSeeds, 0);
      expect(info.infoHash, '');
      expect(info.peerCount, 0);
      expect(info.fileProgress, isEmpty);
    });
    test('fileProgress list is unmodifiable', () {
      final info = TorrentUpdateInfo(
          id: 1,
          name: 't',
          progress: 0.0,
          downloadRate: 0,
          uploadRate: 0,
          totalDone: 0,
          totalWanted: 0,
          totalWantedDone: 0,
          hasMetadata: false,
          stateLabel: 'checking',
          fileProgress: [100]);
      expect(() => (info.fileProgress as dynamic).add(200),
          throwsUnsupportedError);
    });
    test('peerCount aliases numPeers', () {
      final info = TorrentUpdateInfo(
          id: 1,
          name: 't',
          progress: 1.0,
          downloadRate: 0,
          uploadRate: 0,
          totalDone: 0,
          totalWanted: 0,
          totalWantedDone: 0,
          hasMetadata: true,
          stateLabel: 'seeding',
          numPeers: 15);
      expect(info.peerCount, 15);
    });
  });

  // ---------------------------------------------------------------------------
  // TorrentFileItem
  // ---------------------------------------------------------------------------
  group('TorrentFileItem', () {
    test(
        'hasProgressData true when downloadedBytes >= 0',
        () => expect(
            TorrentFileItem(
                    index: 0, name: 'a.mp4', size: 1024, downloadedBytes: 0)
                .hasProgressData,
            isTrue));
    test(
        'hasProgressData false for sentinel -1',
        () => expect(
            TorrentFileItem(
                    index: 0, name: 'a.mp4', size: 1024, downloadedBytes: -1)
                .hasProgressData,
            isFalse));
    test(
        'safeDownloadedBytes returns 0 for -1',
        () => expect(
            TorrentFileItem(
                    index: 0, name: 'a.mp4', size: 1024, downloadedBytes: -1)
                .safeDownloadedBytes,
            0));
    test(
        'safeDownloadedBytes returns actual value',
        () => expect(
            TorrentFileItem(
                    index: 0, name: 'a.mp4', size: 1024, downloadedBytes: 512)
                .safeDownloadedBytes,
            512));
    test('default priority=4 and selected=true', () {
      final item = TorrentFileItem(index: 0, name: 'a.mp4', size: 1024);
      expect(item.priority, 4);
      expect(item.selected, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // TorrentFileProgress
  // ---------------------------------------------------------------------------
  group('TorrentFileProgress', () {
    test('constructs correctly', () {
      const fp = TorrentFileProgress(
          index: 2,
          name: 'video.mkv',
          size: 1073741824,
          downloadedBytes: 536870912,
          progress: 0.5,
          exists: true,
          isComplete: false);
      expect(fp.index, 2);
      expect(fp.progress, 0.5);
      expect(fp.exists, isTrue);
      expect(fp.isComplete, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // TorrentAlertEvent
  // ---------------------------------------------------------------------------
  group('TorrentAlertEvent', () {
    test('constructs with all fields', () {
      final now = DateTime.now();
      final alert = TorrentAlertEvent(
          type: 7,
          torrentId: 42,
          message: 'Hash check passed',
          timestamp: now,
          category: 'integrity');
      expect(alert.type, 7);
      expect(alert.torrentId, 42);
      expect(alert.category, 'integrity');
      expect(alert.timestamp, now);
    });
    test('default category is general', () {
      expect(
          TorrentAlertEvent(
                  type: 1,
                  torrentId: 0,
                  message: 'test',
                  timestamp: DateTime.now())
              .category,
          'general');
    });
    test('toString contains torrentId category and message', () {
      final str = TorrentAlertEvent(
              type: 1,
              torrentId: 99,
              message: 'Piece 5 done',
              timestamp: DateTime.now(),
              category: 'download')
          .toString();
      expect(str, contains('T99'));
      expect(str, contains('download'));
      expect(str, contains('Piece 5 done'));
    });
  });

  // ---------------------------------------------------------------------------
  // TrackerInfo
  // ---------------------------------------------------------------------------
  group('TrackerInfo', () {
    test('constructs correctly', () {
      const t = TrackerInfo(
          url: 'udp://tracker.opentrackr.org:1337/announce',
          tier: 0,
          status: 'working',
          seeds: 100,
          peers: 50,
          message: '');
      expect(t.url, contains('opentrackr'));
      expect(t.seeds, 100);
    });
  });

  // ---------------------------------------------------------------------------
  // SeedingPolicy
  // ---------------------------------------------------------------------------
  group('SeedingPolicy.shouldStopSeeding', () {
    test('stops when ratio >= maxRatio', () {
      expect(
          const SeedingPolicy(maxRatio: 2.0).shouldStopSeeding(
              currentRatio: 2.5,
              seedDuration: const Duration(minutes: 10),
              uploadedBytes: 2500,
              isCharging: true,
              isOnWifi: true),
          isTrue);
    });
    test('does not stop when ratio < maxRatio', () {
      expect(
          const SeedingPolicy(maxRatio: 2.0).shouldStopSeeding(
              currentRatio: 1.0,
              seedDuration: const Duration(minutes: 10),
              uploadedBytes: 1000,
              isCharging: true,
              isOnWifi: true),
          isFalse);
    });
    test('stops when maxSeedTime exceeded', () {
      expect(
          const SeedingPolicy(maxSeedTime: Duration(hours: 1))
              .shouldStopSeeding(
                  currentRatio: 0.1,
                  seedDuration: const Duration(hours: 2),
                  uploadedBytes: 100,
                  isCharging: true,
                  isOnWifi: true),
          isTrue);
    });
    test('stops when not charging and seedOnlyWhenCharging=true', () {
      expect(
          const SeedingPolicy(seedOnlyWhenCharging: true).shouldStopSeeding(
              currentRatio: 0.1,
              seedDuration: const Duration(minutes: 1),
              uploadedBytes: 0,
              isCharging: false,
              isOnWifi: true),
          isTrue);
    });
    test('does not stop when charging and seedOnlyWhenCharging=true', () {
      expect(
          const SeedingPolicy(seedOnlyWhenCharging: true, maxRatio: 10.0)
              .shouldStopSeeding(
                  currentRatio: 0.1,
                  seedDuration: const Duration(minutes: 1),
                  uploadedBytes: 0,
                  isCharging: true,
                  isOnWifi: true),
          isFalse);
    });
    test('stops when not on wifi and seedOnlyOnWifi=true', () {
      expect(
          const SeedingPolicy(seedOnlyOnWifi: true).shouldStopSeeding(
              currentRatio: 0.1,
              seedDuration: const Duration(minutes: 1),
              uploadedBytes: 0,
              isCharging: true,
              isOnWifi: false),
          isTrue);
    });
    test('minSeedTimeMinutes prevents early stop', () {
      expect(
          const SeedingPolicy(maxRatio: 0.1, minSeedTimeMinutes: 30)
              .shouldStopSeeding(
                  currentRatio: 5.0,
                  seedDuration: const Duration(minutes: 5),
                  uploadedBytes: 5000,
                  isCharging: true,
                  isOnWifi: true),
          isFalse);
    });
    test('stops when maxUploadBytes reached', () {
      expect(
          const SeedingPolicy(maxUploadBytes: 1000).shouldStopSeeding(
              currentRatio: 0.1,
              seedDuration: const Duration(minutes: 1),
              uploadedBytes: 1500,
              isCharging: true,
              isOnWifi: true),
          isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // ProxyType
  // ---------------------------------------------------------------------------
  group('ProxyType', () {
    test('fromString null -> none',
        () => expect(ProxyType.fromString(null), ProxyType.none));
    test('fromString empty -> none',
        () => expect(ProxyType.fromString(''), ProxyType.none));
    test('fromString socks5',
        () => expect(ProxyType.fromString('SOCKS5'), ProxyType.socks5));
    test('fromString http',
        () => expect(ProxyType.fromString('http'), ProxyType.http));
    test('fromString https -> http',
        () => expect(ProxyType.fromString('https'), ProxyType.http));
    test('fromString unknown -> none',
        () => expect(ProxyType.fromString('tor'), ProxyType.none));
    test('displayName none',
        () => expect(ProxyType.none.displayName, 'None (Direct)'));
    test('displayName socks5',
        () => expect(ProxyType.socks5.displayName, 'SOCKS5'));
    test('displayName http', () => expect(ProxyType.http.displayName, 'HTTP'));
  });

  // ---------------------------------------------------------------------------
  // TorrentMetadata — version detection
  // ---------------------------------------------------------------------------
  group('TorrentMetadata version detection', () {
    test('v1 only', () {
      const meta = TorrentMetadata(
          name: 'ubuntu.iso',
          totalSize: 1024,
          infoHashV1: 'DA39A3EE5E6B4B0D3255BFEF95601890AFD80709');
      expect(meta.isV1Only, isTrue);
      expect(meta.version, TorrentHashVersion.v1);
      expect(meta.primaryInfoHash, 'DA39A3EE5E6B4B0D3255BFEF95601890AFD80709');
    });
    test('v2 only', () {
      const hash =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const meta =
          TorrentMetadata(name: 'test.iso', totalSize: 2048, infoHashV2: hash);
      expect(meta.isV2Only, isTrue);
      expect(meta.version, TorrentHashVersion.v2);
      expect(meta.primaryInfoHash, hash);
    });
    test('hybrid (both v1 and v2)', () {
      const meta = TorrentMetadata(
          name: 'hybrid.iso',
          totalSize: 4096,
          infoHashV1: '1111111111111111111111111111111111111111',
          infoHashV2:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
      expect(meta.isHybrid, isTrue);
      expect(meta.version, TorrentHashVersion.hybrid);
      expect(meta.primaryInfoHash,
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    });
    test('unknown when no hash', () {
      const meta = TorrentMetadata(name: 'mystery', totalSize: 0);
      expect(meta.version, TorrentHashVersion.unknown);
      expect(meta.primaryInfoHash, '');
    });
    test('metadata fields stored correctly', () {
      final now = DateTime(2025, 1, 1);
      final meta = TorrentMetadata(
          name: 'test.iso',
          totalSize: 1048576,
          isPrivate: true,
          comment: 'My comment',
          createdBy: 'DMX',
          creationDate: now,
          pieceSize: 262144,
          pieceCount: 4,
          trackers: ['udp://tracker.example.com:80/announce'],
          webSeeds: ['https://mirror.example.com/test.iso']);
      expect(meta.isPrivate, isTrue);
      expect(meta.comment, 'My comment');
      expect(meta.pieceSize, 262144);
      expect(meta.trackers, hasLength(1));
      expect(meta.webSeeds, hasLength(1));
    });
  });

  // ---------------------------------------------------------------------------
  // TrackerStatus enum
  // ---------------------------------------------------------------------------
  group('TrackerStatus enum', () {
    test('has all expected values', () {
      expect(
          TrackerStatus.values,
          containsAll([
            TrackerStatus.working,
            TrackerStatus.updating,
            TrackerStatus.notWorking,
            TrackerStatus.disabled
          ]));
    });
  });

  // ---------------------------------------------------------------------------
  // TorrentTrackerInfo.copyWith
  // ---------------------------------------------------------------------------
  group('TorrentTrackerInfo.copyWith', () {
    test('copies with updated status and seeds', () {
      final original = TorrentTrackerInfo(
          url: 'udp://tracker.example.com:80/announce',
          status: TrackerStatus.updating,
          seeds: 100,
          peers: 50);
      final updated =
          original.copyWith(status: TrackerStatus.working, seeds: 200);
      expect(updated.status, TrackerStatus.working);
      expect(updated.seeds, 200);
      expect(updated.url, original.url);
      expect(updated.peers, original.peers);
    });
  });

  // ---------------------------------------------------------------------------
  // TorrentHashVersion enum
  // ---------------------------------------------------------------------------
  group('TorrentHashVersion enum', () {
    test('has all expected values', () {
      expect(
          TorrentHashVersion.values,
          containsAll([
            TorrentHashVersion.v1,
            TorrentHashVersion.v2,
            TorrentHashVersion.hybrid,
            TorrentHashVersion.unknown
          ]));
    });
  });
}
