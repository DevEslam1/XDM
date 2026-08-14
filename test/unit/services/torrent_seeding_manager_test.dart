import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/torrent_models.dart';
import 'package:dmx/core/services/torrent_seeding_manager.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TorrentSeedingManager Unit Tests (Phase 5 & 10)', () {
    test('calculateRatio handles division and zero download safely', () {
      expect(TorrentSeedingManager.calculateRatio(100, 50), 2.0);
      expect(TorrentSeedingManager.calculateRatio(100, 0), 0.0);
    });

    test('SeedingPolicy accurately triggers stop based on ratio', () {
      const policy = SeedingPolicy(maxRatio: 1.5);
      expect(
        policy.shouldStopSeeding(
          currentRatio: 1.0,
          seedDuration: const Duration(minutes: 10),
          uploadedBytes: 1000,
          isCharging: true,
          isOnWifi: true,
        ),
        isFalse,
      );

      expect(
        policy.shouldStopSeeding(
          currentRatio: 1.6,
          seedDuration: const Duration(minutes: 10),
          uploadedBytes: 1600,
          isCharging: true,
          isOnWifi: true,
        ),
        isTrue,
      );
    });

    test('SeedingPolicy enforces charging and wifi constraints', () {
      const chargingPolicy = SeedingPolicy(seedOnlyWhenCharging: true);
      expect(
        chargingPolicy.shouldStopSeeding(
          currentRatio: 0.5,
          seedDuration: const Duration(minutes: 5),
          uploadedBytes: 500,
          isCharging: false,
          isOnWifi: true,
        ),
        isTrue,
      );

      const wifiPolicy = SeedingPolicy(seedOnlyOnWifi: true);
      expect(
        wifiPolicy.shouldStopSeeding(
          currentRatio: 0.5,
          seedDuration: const Duration(minutes: 5),
          uploadedBytes: 500,
          isCharging: true,
          isOnWifi: false,
        ),
        isTrue,
      );
    });

    test('computeAdaptiveUploadLimit scales with power and thermal status', () {
      final settings = SettingsProvider();

      expect(
        TorrentSeedingManager.computeAdaptiveUploadLimit(
          settings: settings,
          batteryMode: BatterySaverMode.aggressive,
          thermalStatus: ThermalStatus.none,
        ),
        0,
      );

      expect(
        TorrentSeedingManager.computeAdaptiveUploadLimit(
          settings: settings,
          batteryMode: BatterySaverMode.moderate,
          thermalStatus: ThermalStatus.none,
        ),
        50 * 1024,
      );

      expect(
        TorrentSeedingManager.computeAdaptiveUploadLimit(
          settings: settings,
          batteryMode: BatterySaverMode.off,
          thermalStatus: ThermalStatus.severe,
        ),
        25 * 1024,
      );
    });
  });
}
