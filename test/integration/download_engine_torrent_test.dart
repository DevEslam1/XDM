import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Cross-Feature Integration Tests', () {
    test('Journal recovery retains progress state after crash simulation',
        () async {
      const journalPath = 'test_integration.journal';
      final journal = DownloadJournal(journalPath);
      await journal.open();
      await journal.writeInit(4, 10000);
      await journal.recordChunkProgress(0, 2500);
      await journal.recordChunkProgress(1, 2500);
      await journal.close();

      final recovered = await DownloadJournal.recover(journalPath);
      expect(recovered, isNotNull);
      expect(recovered, equals([2500, 2500, 0, 0]));
    });

    test('Bandwidth governor tracks per-domain throughput correctly', () {
      final governor = BandwidthGovernor(1024 * 1024);
      governor.reportDomainSpeed('cdn1.example.com', 500000);
      governor.reportDomainSpeed('cdn1.example.com', 700000);
      expect(governor.getAverageSpeedForDomain('cdn1.example.com'),
          equals(600000));
    });

    test(
        'Torrent stub methods provide safe fallback values when FFI is uninitialized',
        () async {
      expect(TorrentService.isSupported, isA<bool>());
      expect(TorrentService.getTrackers(1), isEmpty);
      expect(await TorrentService.loadIpFilter('dummy.dat'), isFalse);
    });

    test('TorrentService.ready resolves cleanly', () async {
      await expectLater(TorrentService.ready, completes);
    });

    test(
        'TorrentService.hasResumeData returns false when no resume data exists',
        () async {
      final exists = await TorrentService.hasResumeData('non_existent_source');
      expect(exists, isFalse);
    });

    test(
        'TorrentService.shouldStopSeeding correctly calculates ratio and time limits',
        () {
      // Under ratio limit and under max time -> false
      expect(
        TorrentService.shouldStopSeeding(
          progress: 1.0,
          uploadedBytes: 500,
          downloadedBytes: 1000,
          shareRatioLimit: 2.0,
          maxSeedingMinutes: 60,
          completedAt: DateTime.now().subtract(const Duration(minutes: 30)),
        ),
        isFalse,
      );

      // Exceeds ratio limit (1500 / 1000 = 1.5 >= 1.0) -> true
      expect(
        TorrentService.shouldStopSeeding(
          progress: 1.0,
          uploadedBytes: 1500,
          downloadedBytes: 1000,
          shareRatioLimit: 1.0,
          maxSeedingMinutes: 0,
        ),
        isTrue,
      );

      // Exceeds max seeding minutes -> true
      expect(
        TorrentService.shouldStopSeeding(
          progress: 1.0,
          uploadedBytes: 0,
          downloadedBytes: 1000,
          shareRatioLimit: 0,
          maxSeedingMinutes: 30,
          completedAt: DateTime.now().subtract(const Duration(minutes: 35)),
        ),
        isTrue,
      );
    });

    test('TorrentService.addTracker ignores invalid schemes silently', () {
      expect(() => TorrentService.addTracker(1, 'ftp://tracker.example.com'),
          returnsNormally);
      expect(() => TorrentService.addTracker(1, 'http://tracker.example.com'),
          returnsNormally);
    });
  });
}
