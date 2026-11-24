import 'package:dmx/core/domain/cycle_state.dart';
import 'package:dmx/core/domain/torrent_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('stateFromInt', () {
    test('maps all codes and unknown default', () {
      expect(stateFromInt(-2), DmxTorrentState.error);
      expect(stateFromInt(0), DmxTorrentState.checkingFiles);
      expect(stateFromInt(1), DmxTorrentState.downloadingMetadata);
      expect(stateFromInt(2), DmxTorrentState.downloading);
      expect(stateFromInt(3), DmxTorrentState.finished);
      expect(stateFromInt(4), DmxTorrentState.seeding);
      expect(stateFromInt(5), DmxTorrentState.allocating);
      expect(stateFromInt(6), DmxTorrentState.checkingResume);
      expect(stateFromInt(42), DmxTorrentState.unknown);

      const TorrentState alias = DmxTorrentState.downloading;
      expect(alias, DmxTorrentState.downloading);
    });
  });

  group('TorrentFileItem', () {
    test('defaults and safe getters', () {
      final f = TorrentFileItem(index: 0, name: 'a', size: 10);
      expect(f.downloadedBytes, 0);
      expect(f.priority, 4);
      expect(f.selected, isTrue);
      expect(f.hasProgressData, isTrue);
      expect(f.safeDownloadedBytes, 0);

      final negative = TorrentFileItem(
        index: 1,
        name: 'b',
        size: 10,
        downloadedBytes: -1,
      );
      expect(negative.hasProgressData, isFalse);
      expect(negative.safeDownloadedBytes, 0);
    });
  });

  group('TorrentUpdateInfo', () {
    TorrentUpdateInfo build({
      TorrentState state = TorrentState.unknown,
      String label = 'downloading',
      bool hasMetadata = true,
    }) =>
        TorrentUpdateInfo(
          id: 1,
          name: 'n',
          progress: 0.5,
          downloadRate: 1,
          uploadRate: 2,
          totalDone: 3,
          totalWanted: 4,
          totalWantedDone: 2,
          hasMetadata: hasMetadata,
          stateLabel: label,
          state: state,
          numPeers: 7,
        );

    test('getters and immutability of lists', () {
      final info = TorrentUpdateInfo(
        id: 1,
        name: 'n',
        progress: 0.5,
        downloadRate: 1,
        uploadRate: 2,
        totalDone: 3,
        totalWanted: 4,
        totalWantedDone: 2,
        hasMetadata: true,
        stateLabel: 'downloading',
        fileProgress: const [1, 2],
        filePriorities: const [4],
        pieces: const [true],
      );
      expect(info.peerCount, info.numPeers);
      expect(info.sizeKnown, isTrue);
      expect(info.fileProgress, [1, 2]);
      expect(
        () => info.fileProgress.add(3),
        throwsUnsupportedError,
      );
    });

    test('isChecking branches', () {
      expect(build(state: TorrentState.checkingFiles).isChecking, isTrue);
      expect(build(state: TorrentState.checkingResume).isChecking, isTrue);
      expect(build(label: 'checking_files').isChecking, isTrue);
      expect(build(label: 'downloading').isChecking, isFalse);
    });

    test('isFetchingMetadata branches', () {
      expect(
        build(state: TorrentState.downloadingMetadata, hasMetadata: false)
            .isFetchingMetadata,
        isTrue,
      );
      expect(
        build(label: 'metadata', hasMetadata: false).isFetchingMetadata,
        isTrue,
      );
      expect(
        build(label: 'getting_metadata', hasMetadata: false).isFetchingMetadata,
        isTrue,
      );
      expect(build(label: 'metadata', hasMetadata: true).isFetchingMetadata,
          isFalse);
      expect(build(label: 'downloading').isFetchingMetadata, isFalse);
    });
  });

  group('TorrentSwarmSnapshot', () {
    test('defaults and derived values', () {
      const s = TorrentSwarmSnapshot();
      expect(s.connectedSeeds, 0);
      expect(s.swarmSeeds, isNull);
      expect(TorrentSwarmSnapshot.empty.isEmpty, isTrue);
      expect(s.hasSwarmScrape, isFalse);
      expect(s.totalConnections, 0);

      const populated = TorrentSwarmSnapshot(
        connectedSeeds: 2,
        connectedPeers: 3,
        swarmSeeds: 10,
        swarmPeers: 20,
        availability: 1.5,
      );
      expect(populated.isEmpty, isFalse);
      expect(populated.hasSwarmScrape, isTrue);
      expect(populated.totalConnections, 5);

      const onlyScrape = TorrentSwarmSnapshot(swarmPeers: 0);
      expect(onlyScrape.hasSwarmScrape, isTrue);
      expect(onlyScrape.isEmpty, isFalse);
    });
  });

  group('TorrentTrackerInfo', () {
    test('defaults and copyWith', () {
      final t = TorrentTrackerInfo(url: 'http://t');
      expect(t.status, TrackerStatus.working);
      expect(t.seeds, 0);
      expect(t.peers, 0);
      expect(t.downloaded, 0);
      expect(t.message, '');
      expect(t.nextAnnounceSeconds, 0);

      final c = t.copyWith(
        url: 'u',
        status: TrackerStatus.notWorking,
        seeds: 1,
        peers: 2,
        downloaded: 3,
        message: 'm',
        nextAnnounceSeconds: 9,
      );
      expect(c.url, 'u');
      expect(c.status, TrackerStatus.notWorking);
      expect(c.seeds, 1);
      expect(c.peers, 2);
      expect(c.downloaded, 3);
      expect(c.message, 'm');
      expect(c.nextAnnounceSeconds, 9);
    });
  });

  group('simple value types', () {
    test('TorrentFileProgress defaults', () {
      const p = TorrentFileProgress(
        index: 0,
        name: 'a',
        size: 1,
        downloadedBytes: 0,
        progress: 0,
        exists: true,
        isComplete: false,
      );
      expect(p.isEstimated, isFalse);
    });

    test('PeerConnectionQuality defaults', () {
      const p = PeerConnectionQuality(
        ip: '1.1.1.1',
        port: 80,
        client: 'c',
        downloadSpeed: 0,
        uploadSpeed: 0,
        progress: 0,
        isSeed: false,
        isEncrypted: false,
      );
      expect(p.isOutgoing, isFalse);
      expect(p.connectedDuration, Duration.zero);
      expect(p.failedHashChecks, 0);
      expect(p.relevance, 0.0);
    });

    test('TrackerInfo', () {
      const t = TrackerInfo(
        url: 'u',
        tier: 0,
        status: 'working',
        seeds: 1,
        peers: 2,
        message: 'm',
      );
      expect(t.url, 'u');
      expect(t.tier, 0);
    });
  });

  group('SeedingPolicy', () {
    test('defaults', () {
      const p = SeedingPolicy();
      expect(p.maxRatio, 2.0);
      expect(p.maxSeedTime, Duration.zero);
      expect(p.maxUploadBytes, 0);
      expect(p.seedOnlyWhenCharging, isFalse);
      expect(p.seedOnlyOnWifi, isFalse);
      expect(p.minSeedTimeMinutes, 0);
    });

    test('shouldStopSeeding branches', () {
      const p = SeedingPolicy(
        maxRatio: 2.0,
        maxSeedTime: Duration(minutes: 10),
        maxUploadBytes: 100,
        minSeedTimeMinutes: 5,
      );

      expect(
        p.shouldStopSeeding(
          currentRatio: 99,
          seedDuration: const Duration(hours: 1),
          uploadedBytes: 999,
          isCharging: true,
          isOnWifi: true,
          cycleState: CycleState.paused,
        ),
        isFalse,
      );

      const charging = SeedingPolicy(seedOnlyWhenCharging: true);
      expect(
        charging.shouldStopSeeding(
          currentRatio: 0,
          seedDuration: Duration.zero,
          uploadedBytes: 0,
          isCharging: false,
          isOnWifi: true,
        ),
        isTrue,
      );

      const wifi = SeedingPolicy(seedOnlyOnWifi: true);
      expect(
        wifi.shouldStopSeeding(
          currentRatio: 0,
          seedDuration: Duration.zero,
          uploadedBytes: 0,
          isCharging: true,
          isOnWifi: false,
        ),
        isTrue,
      );

      expect(
        p.shouldStopSeeding(
          currentRatio: 0,
          seedDuration: const Duration(minutes: 1),
          uploadedBytes: 0,
          isCharging: true,
          isOnWifi: true,
        ),
        isFalse,
      );

      expect(
        p.shouldStopSeeding(
          currentRatio: 2.5,
          seedDuration: const Duration(hours: 1),
          uploadedBytes: 0,
          isCharging: true,
          isOnWifi: true,
        ),
        isTrue,
      );

      const timePolicy = SeedingPolicy(maxSeedTime: Duration(minutes: 10));
      expect(
        timePolicy.shouldStopSeeding(
          currentRatio: 0,
          seedDuration: const Duration(minutes: 10),
          uploadedBytes: 0,
          isCharging: true,
          isOnWifi: true,
        ),
        isTrue,
      );

      const bytesPolicy = SeedingPolicy(maxUploadBytes: 100);
      expect(
        bytesPolicy.shouldStopSeeding(
          currentRatio: 0,
          seedDuration: Duration.zero,
          uploadedBytes: 100,
          isCharging: true,
          isOnWifi: true,
        ),
        isTrue,
      );

      const none = SeedingPolicy(maxRatio: 0);
      expect(
        none.shouldStopSeeding(
          currentRatio: 100,
          seedDuration: Duration.zero,
          uploadedBytes: 0,
          isCharging: true,
          isOnWifi: true,
        ),
        isFalse,
      );
    });
  });

  group('TorrentMetadata', () {
    test('version detection', () {
      const v1 = TorrentMetadata(name: 'n', totalSize: 0, infoHashV1: 'a');
      expect(v1.isV1Only, isTrue);
      expect(v1.isV2Only, isFalse);
      expect(v1.isHybrid, isFalse);
      expect(v1.version, TorrentHashVersion.v1);
      expect(v1.primaryInfoHash, 'a');

      const v2 = TorrentMetadata(name: 'n', totalSize: 0, infoHashV2: 'b');
      expect(v2.isV2Only, isTrue);
      expect(v2.version, TorrentHashVersion.v2);
      expect(v2.primaryInfoHash, 'b');

      const hybrid = TorrentMetadata(
          name: 'n', totalSize: 0, infoHashV1: 'a', infoHashV2: 'b');
      expect(hybrid.isHybrid, isTrue);
      expect(hybrid.version, TorrentHashVersion.hybrid);
      expect(hybrid.primaryInfoHash, 'b');

      const unknown = TorrentMetadata(name: 'n', totalSize: 0);
      expect(unknown.version, TorrentHashVersion.unknown);
      expect(unknown.primaryInfoHash, '');

      const emptyHashes = TorrentMetadata(
        name: 'n',
        totalSize: 0,
        infoHashV1: '',
        infoHashV2: '',
      );
      expect(emptyHashes.isV1Only, isFalse);
      expect(emptyHashes.isV2Only, isFalse);
      expect(emptyHashes.isHybrid, isFalse);
    });

    test('defaults', () {
      const m = TorrentMetadata(name: 'n', totalSize: 0);
      expect(m.files, isEmpty);
      expect(m.trackers, isEmpty);
      expect(m.webSeeds, isEmpty);
      expect(m.pieceSize, 0);
      expect(m.pieceCount, 0);
      expect(m.isPrivate, isFalse);
      expect(m.comment, isNull);
      expect(m.createdBy, isNull);
      expect(m.creationDate, isNull);
    });
  });

  group('TorrentAlertEvent', () {
    test('toString', () {
      final e = TorrentAlertEvent(
        type: 1,
        torrentId: 2,
        message: 'm',
        timestamp: DateTime.utc(2025, 1, 1),
      );
      expect(e.category, 'general');
      expect(e.toString(), contains('[T2]'));
      expect(e.toString(), contains('(general) m'));
    });
  });

  group('ProxyType', () {
    test('fromString', () {
      expect(ProxyType.fromString(null), ProxyType.none);
      expect(ProxyType.fromString('socks5'), ProxyType.socks5);
      expect(ProxyType.fromString(' SOCKS5 '), ProxyType.socks5);
      expect(ProxyType.fromString('http'), ProxyType.http);
      expect(ProxyType.fromString('https'), ProxyType.http);
      expect(ProxyType.fromString('bogus'), ProxyType.none);
    });

    test('displayName', () {
      expect(ProxyType.none.displayName, 'None (Direct)');
      expect(ProxyType.socks5.displayName, 'SOCKS5');
      expect(ProxyType.http.displayName, 'HTTP');
    });
  });
}
