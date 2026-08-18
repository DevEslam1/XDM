import 'package:dmx/core/services/torrent_models.dart';
import 'package:dmx/core/services/torrent_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Torrent Fixes Regression Tests', () {
    test('TorrentService.ready completes without throwing StateError', () async {
      await expectLater(TorrentService.ready, completes);
    });

    test('getTorrentSnapshot returns null safely for unknown torrent', () {
      final snapshot = TorrentService.getTorrentSnapshot(99999);
      expect(snapshot, isNull);
    });

    test('getFiles returns empty list instead of throwing for unknown id', () {
      final files = TorrentService.getFiles(99999);
      expect(files, isEmpty);
    });

    test('getTrackers returns empty list instead of throwing for unknown id', () {
      final trackers = TorrentService.getTrackers(99999);
      expect(trackers, isEmpty);
    });

    test('SeedingPolicy checks real charging and wifi conditions correctly', () {
      const policy = SeedingPolicy(
        maxRatio: 2.0,
        maxSeedTime: Duration(hours: 1),
        seedOnlyWhenCharging: true,
        seedOnlyOnWifi: true,
      );

      // Should stop if not charging when seedOnlyWhenCharging is true
      expect(
        policy.shouldStopSeeding(
          currentRatio: 0.5,
          seedDuration: const Duration(minutes: 10),
          uploadedBytes: 1000,
          isCharging: false,
          isOnWifi: true,
        ),
        isTrue,
      );

      // Should stop if not on wifi when seedOnlyOnWifi is true
      expect(
        policy.shouldStopSeeding(
          currentRatio: 0.5,
          seedDuration: const Duration(minutes: 10),
          uploadedBytes: 1000,
          isCharging: true,
          isOnWifi: false,
        ),
        isTrue,
      );

      // Should continue if charging and on wifi and ratio/time limit not exceeded
      expect(
        policy.shouldStopSeeding(
          currentRatio: 0.5,
          seedDuration: const Duration(minutes: 10),
          uploadedBytes: 1000,
          isCharging: true,
          isOnWifi: true,
        ),
        isFalse,
      );

      // Should stop if ratio limit exceeded
      expect(
        policy.shouldStopSeeding(
          currentRatio: 2.5,
          seedDuration: const Duration(minutes: 10),
          uploadedBytes: 1000,
          isCharging: true,
          isOnWifi: true,
        ),
        isTrue,
      );
    });
  });
}
