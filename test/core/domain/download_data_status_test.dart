import 'package:dmx/core/domain/download_data_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TorrentDataStatus', () {
    const base = TorrentDataStatus(
      totalWanted: 1000,
      totalWantedDone: 500,
      progress: 0.5,
      hasMetadata: true,
      numSeeds: 2,
      numPeers: 3,
      numComplete: 10,
      numIncomplete: 20,
      state: 'downloading',
    );

    test('derived getters', () {
      expect(base.sizeKnown, isTrue);
      expect(base.isChecking, isFalse);
      expect(base.isFetchingMetadata, isFalse);

      expect(
        const TorrentDataStatus(
          totalWanted: 0,
          totalWantedDone: 0,
          progress: 0,
          hasMetadata: false,
          state: 'checking_files',
        ).isChecking,
        isTrue,
      );
      expect(
        const TorrentDataStatus(
          totalWanted: 0,
          totalWantedDone: 0,
          progress: 0,
          hasMetadata: false,
          state: 'downloading_metadata',
        ).isFetchingMetadata,
        isTrue,
      );
      expect(
        const TorrentDataStatus(
          totalWanted: 0,
          totalWantedDone: 0,
          progress: 0,
          hasMetadata: true,
          state: 'getting_metadata',
        ).isFetchingMetadata,
        isFalse,
      );
      expect(
        const TorrentDataStatus(
          totalWanted: 0,
          totalWantedDone: 0,
          progress: 0,
          hasMetadata: false,
          state: 'getting_metadata',
        ).isFetchingMetadata,
        isTrue,
      );
    });

    test('equality and hashCode', () {
      const same = TorrentDataStatus(
        totalWanted: 1000,
        totalWantedDone: 500,
        progress: 0.5,
        hasMetadata: true,
        numSeeds: 2,
        numPeers: 3,
        numComplete: 10,
        numIncomplete: 20,
        state: 'downloading',
      );
      expect(base, equals(same));
      expect(base.hashCode, equals(same.hashCode));
      expect(base == Object(), isFalse);
      expect(
        const TorrentDataStatus(
              totalWanted: 1000,
              totalWantedDone: 500,
              progress: 0.5,
              hasMetadata: true,
              numSeeds: 2,
              numPeers: 3,
              numComplete: 10,
              numIncomplete: 20,
              state: 'seeding',
            ) ==
            base,
        isFalse,
      );
    });

    test('default optional fields', () {
      const d = TorrentDataStatus(
        totalWanted: 1,
        totalWantedDone: 0,
        progress: 0,
        hasMetadata: true,
        state: 'x',
      );
      expect(d.piecesTotal, 0);
      expect(d.piecesDone, 0);
      expect(d.distributedCopies, 0.0);
      expect(d.activeTime, 0);
      expect(d.seedingTime, 0);
      expect(d.piecesEstimated, isTrue);
    });
  });

  group('HttpPartStatus', () {
    test('totalBytes and progress', () {
      const part = HttpPartStatus(
        partIndex: 0,
        startByte: 0,
        endByte: 99,
        downloadedBytes: 50,
      );
      expect(part.totalBytes, 100);
      expect(part.progress, closeTo(0.5, 0.001));

      const invalid = HttpPartStatus(
        partIndex: 0,
        startByte: 100,
        endByte: 0,
        downloadedBytes: 10,
      );
      expect(invalid.totalBytes, 0);
      expect(invalid.progress, 0.0);
    });

    test('clamps progress and equality', () {
      const over = HttpPartStatus(
        partIndex: 0,
        startByte: 0,
        endByte: 9,
        downloadedBytes: 100,
      );
      expect(over.progress, 1.0);
      const same = HttpPartStatus(
        partIndex: 0,
        startByte: 0,
        endByte: 9,
        downloadedBytes: 100,
      );
      expect(over, equals(same));
      expect(over.hashCode, equals(same.hashCode));
      expect(over == Object(), isFalse);
      expect(
        const HttpPartStatus(
              partIndex: 1,
              startByte: 0,
              endByte: 9,
              downloadedBytes: 100,
            ) ==
            over,
        isFalse,
      );
    });
  });

  group('YtStreamStatus', () {
    test('equality and hashCode', () {
      const a = YtStreamStatus(
        streamType: 'video',
        downloadedBytes: 1,
        totalBytes: 2,
        progress: 0.5,
      );
      const b = YtStreamStatus(
        streamType: 'video',
        downloadedBytes: 1,
        totalBytes: 2,
        progress: 0.5,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a == Object(), isFalse);
      expect(
        const YtStreamStatus(
              streamType: 'audio',
              downloadedBytes: 1,
              totalBytes: 2,
              progress: 0.5,
            ) ==
            a,
        isFalse,
      );
    });
  });

  group('TorrentFileStatus', () {
    test('progress and equality', () {
      const file = TorrentFileStatus(
        fileIndex: 0,
        name: 'a.mp4',
        size: 100,
        downloadedBytes: 25,
        priority: 4,
        selected: true,
      );
      expect(file.progress, closeTo(0.25, 0.001));
      expect(file == Object(), isFalse);
      expect(
        const TorrentFileStatus(
              fileIndex: 0,
              name: 'a.mp4',
              size: 100,
              downloadedBytes: 25,
              priority: 4,
              selected: false,
            ) ==
            file,
        isFalse,
      );

      const zero = TorrentFileStatus(
        fileIndex: 1,
        name: 'z',
        size: 0,
        downloadedBytes: 0,
        priority: 4,
        selected: true,
      );
      expect(zero.progress, 0.0);

      const over = TorrentFileStatus(
        fileIndex: 1,
        name: 'z',
        size: 10,
        downloadedBytes: 100,
        priority: 4,
        selected: true,
      );
      expect(over.progress, 1.0);
      expect(file.hashCode, isNot(equals(over.hashCode)));
    });
  });

  group('label helpers', () {
    test('sizeProgressLabel', () {
      expect(sizeProgressLabel(received: 0, total: 0), '— / —');
      expect(sizeProgressLabel(received: 0, total: -1), '— / —');
      expect(
        sizeProgressLabel(
          received: 5,
          total: 10,
          formatBytesFn: (n) => 'X$n',
        ),
        'X5 / X10',
      );
      expect(sizeProgressLabel(received: 1024, total: 2048), isNotEmpty);
    });

    test('seedsLabel', () {
      expect(seedsLabel(), '—');
      expect(seedsLabel(connected: -1), '—');
      expect(seedsLabel(connected: -1, totalInSwarm: 5), '0 (5)');
      expect(seedsLabel(totalInSwarm: 5), '0 (5)');
      expect(seedsLabel(connected: 2), '2');
      expect(seedsLabel(connected: 2, totalInSwarm: 0), '2');
      expect(seedsLabel(connected: 2, totalInSwarm: 9), '2 (9)');
    });

    test('peersLabel', () {
      expect(peersLabel(), '—');
      expect(peersLabel(connected: -1), '—');
      expect(peersLabel(connected: -1, totalInSwarm: 5), '0 (5)');
      expect(peersLabel(totalInSwarm: 5), '0 (5)');
      expect(peersLabel(connected: 2), '2');
      expect(peersLabel(connected: 2, totalInSwarm: 0), '2');
      expect(peersLabel(connected: 2, totalInSwarm: 9), '2 (9)');
    });
  });
}
