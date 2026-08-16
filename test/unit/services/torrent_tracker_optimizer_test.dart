import 'package:dmx/core/services/torrent_models.dart';
import 'package:dmx/core/services/torrent_tracker_optimizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TorrentTrackerOptimizer Unit Tests (Phase 3 & 10)', () {
    test('getRankedHealthyTrackers ranks by seed and peer health', () {
      final trackers = [
        TorrentTrackerInfo(
          url: 'udp://tracker.low.com:6969/announce',
          status: TrackerStatus.working,
          seeds: 1,
          peers: 2,
        ),
        TorrentTrackerInfo(
          url: 'udp://tracker.broken.com:6969/announce',
          status: TrackerStatus.notWorking,
          seeds: 0,
          peers: 0,
        ),
        TorrentTrackerInfo(
          url: 'udp://tracker.high.com:6969/announce',
          status: TrackerStatus.working,
          seeds: 100,
          peers: 50,
        ),
      ];

      final ranked = TorrentTrackerOptimizer.getRankedHealthyTrackers(trackers);
      expect(ranked.length, 2);
      expect(ranked.first.url, 'udp://tracker.high.com:6969/announce');
      expect(ranked.last.url, 'udp://tracker.low.com:6969/announce');
    });

    test(
        'calculatePeerRelevance rewards encrypted seeds and penalizes bad hashes',
        () {
      final seedRelevance = TorrentTrackerOptimizer.calculatePeerRelevance(
        downloadSpeedBytesPerSec: 200 * 1024,
        isSeed: true,
        isEncrypted: true,
        failedHashChecks: 0,
      );
      expect(seedRelevance, greaterThan(1.5));

      final badPeerRelevance = TorrentTrackerOptimizer.calculatePeerRelevance(
        downloadSpeedBytesPerSec: 5 * 1024,
        isSeed: false,
        isEncrypted: false,
        failedHashChecks: 2,
      );
      expect(badPeerRelevance, lessThan(0.5));
    });
  });
}
