import 'package:dmx/core/domain/download_data_status.dart';
import 'package:dmx/core/domain/torrent_models.dart' hide TorrentState;
import 'package:flutter_test/flutter_test.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';

void main() {
  group('Torrent Status Normalization & UI Labels Tests', () {
    test('sizeProgressLabel returns "— / —" when total <= 0', () {
      expect(sizeProgressLabel(received: 0, total: 0), equals('— / —'));
      expect(sizeProgressLabel(received: 1024, total: -1), equals('— / —'));
      expect(sizeProgressLabel(received: 0, total: -500), equals('— / —'));
    });

    test('sizeProgressLabel formats valid received and total bytes', () {
      expect(
        sizeProgressLabel(received: 512 * 1024, total: 1024 * 1024),
        equals('512.0 KB / 1.0 MB'),
      );
      expect(
        sizeProgressLabel(
            received: 1024 * 1024 * 1024, total: 2 * 1024 * 1024 * 1024),
        equals('1.0 GB / 2.0 GB'),
      );
    });

    test('seedsLabel and peersLabel format connected and swarm totals', () {
      expect(seedsLabel(connected: 5, totalInSwarm: 20), equals('5 (20)'));
      expect(seedsLabel(connected: 5, totalInSwarm: null), equals('5'));
      expect(seedsLabel(connected: null, totalInSwarm: null), equals('—'));
      expect(seedsLabel(connected: null, totalInSwarm: 10), equals('0 (10)'));

      expect(peersLabel(connected: 12, totalInSwarm: 50), equals('12 (50)'));
      expect(peersLabel(connected: 0, totalInSwarm: 0), equals('0'));
      expect(peersLabel(connected: null, totalInSwarm: null), equals('—'));
    });

    test(
        'TorrentDataStatus helpers evaluate metadata and checking flags correctly',
        () {
      const statusFetching = TorrentDataStatus(
        totalWanted: 0,
        totalWantedDone: 0,
        progress: 0.0,
        hasMetadata: false,
        state: 'downloading_metadata',
      );
      expect(statusFetching.sizeKnown, isFalse);
      expect(statusFetching.isFetchingMetadata, isTrue);
      expect(statusFetching.isChecking, isFalse);

      const statusChecking = TorrentDataStatus(
        totalWanted: 1000,
        totalWantedDone: 500,
        progress: 0.5,
        hasMetadata: true,
        state: 'checking_files',
      );
      expect(statusChecking.sizeKnown, isTrue);
      expect(statusChecking.isFetchingMetadata, isFalse);
      expect(statusChecking.isChecking, isTrue);
    });

    test('TorrentUpdateInfo computes sizeKnown and isFetchingMetadata', () {
      final info = TorrentUpdateInfo(
        id: 1,
        name: 'test.iso',
        progress: 0.0,
        downloadRate: 0,
        uploadRate: 0,
        totalDone: 0,
        totalWanted: 0,
        totalWantedDone: 0,
        hasMetadata: false,
        stateLabel: 'Getting metadata',
      );
      expect(info.sizeKnown, isFalse);
      expect(info.isFetchingMetadata, isTrue);

      final readyInfo = TorrentUpdateInfo(
        id: 1,
        name: 'test.iso',
        progress: 0.25,
        downloadRate: 1000,
        uploadRate: 0,
        totalDone: 250,
        totalWanted: 1000,
        totalWantedDone: 250,
        hasMetadata: true,
        stateLabel: 'Downloading',
      );
      expect(readyInfo.sizeKnown, isTrue);
      expect(readyInfo.isFetchingMetadata, isFalse);
    });

    test(
        'TorrentInfo model properly maps and normalizes progress and swarm counts',
        () {
      const info = TorrentInfo(
        id: 1,
        name: 'ubuntu.iso',
        savePath: '/downloads',
        errorMsg: '',
        state: TorrentState.downloading,
        progress: 0.75,
        downloadRate: 1024 * 1024,
        uploadRate: 0,
        totalDone: 750,
        totalWanted: 1000,
        totalUploaded: 0,
        numPeers: 15,
        numSeeds: 30,
        isPaused: false,
        isFinished: false,
        hasMetadata: true,
        queuePosition: 0,
      );

      expect(info.progress, equals(0.75));
      expect(info.numSeeds, equals(30));
      expect(info.numPeers, equals(15));
      expect(info.totalDone, equals(750));
    });
  });
}
