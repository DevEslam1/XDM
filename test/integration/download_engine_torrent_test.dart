import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:dmx/core/services/torrent_service.dart';

void main() {
  group('Cross-Feature Integration Tests', () {
    test('Journal recovery retains progress state after crash simulation', () async {
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
      expect(governor.getAverageSpeedForDomain('cdn1.example.com'), equals(600000));
    });

    test('Torrent stub methods provide safe fallback values when FFI is uninitialized', () async {
      expect(TorrentService.isSupported, isA<bool>());
      expect(TorrentService.getTrackers(1), isEmpty);
      expect(await TorrentService.loadIpFilter('dummy.dat'), isFalse);
    });
  });
}
