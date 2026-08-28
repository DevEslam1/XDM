import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/services/torrent_tracker_optimizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SmartTrackerManager Tests', () {
    test('SmartTrackerManager records successes and computes ranking', () {
      final manager = SmartTrackerManager();

      manager.recordTrackerResult('udp://tracker1.org:80',
          success: true, seeds: 50, latencyMs: 50);
      manager.recordTrackerResult('udp://tracker2.org:80', success: false);
      manager.recordTrackerResult('udp://tracker2.org:80', success: false);

      final tracker1 = TorrentTrackerInfo(
          url: 'udp://tracker1.org:80', seeds: 50, peers: 20);
      final tracker2 =
          TorrentTrackerInfo(url: 'udp://tracker2.org:80', seeds: 0, peers: 0);

      final ranked = manager.rankTrackers([tracker2, tracker1]);
      expect(ranked.first.url, 'udp://tracker1.org:80');
    });

    test(
        'SmartTrackerManager calculates exponential backoff for failed tracker',
        () {
      final manager = SmartTrackerManager();
      manager.recordTrackerResult('udp://failing.org:80', success: false);
      manager.recordTrackerResult('udp://failing.org:80', success: false);

      final backoff = manager.computeBackoffDelay('udp://failing.org:80');
      expect(backoff.inSeconds, greaterThanOrEqualTo(4));
    });
  });
}
