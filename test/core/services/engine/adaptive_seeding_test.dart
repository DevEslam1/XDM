import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/services/torrent_seeding_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AdaptiveSeedingPolicy Tests', () {
    test(
        'AdaptiveSeedingPolicy stops seeding when active downloads need bandwidth',
        () {
      const policy = SeedingPolicy(
        maxRatio: 2.0,
        maxSeedTime: Duration(hours: 1),
        seedOnlyWhenCharging: false,
        seedOnlyOnWifi: false,
      );

      // Active downloads present and upload speed high -> should yield
      final shouldSeed = AdaptiveSeedingPolicy.shouldContinueSeeding(
        currentRatio: 1.0,
        currentUploadSpeed: 150 * 1024,
        seedDuration: const Duration(minutes: 10),
        isOnWifi: true,
        isCharging: true,
        activeDownloads: 1,
        policy: policy,
      );
      expect(shouldSeed, isFalse);
    });

    test('AdaptiveSeedingPolicy allows seeding when conditions are optimal',
        () {
      const policy = SeedingPolicy(
        maxRatio: 2.0,
        maxSeedTime: Duration(hours: 1),
        seedOnlyWhenCharging: false,
        seedOnlyOnWifi: false,
      );

      final shouldSeed = AdaptiveSeedingPolicy.shouldContinueSeeding(
        currentRatio: 1.0,
        currentUploadSpeed: 50 * 1024,
        seedDuration: const Duration(minutes: 10),
        isOnWifi: true,
        isCharging: true,
        activeDownloads: 0,
        policy: policy,
      );
      expect(shouldSeed, isTrue);
    });
  });
}
