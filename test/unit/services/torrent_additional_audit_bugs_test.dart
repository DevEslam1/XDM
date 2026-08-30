import 'dart:typed_data';

import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:dmx/core/services/torrent_seeding_manager.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Additional Audit Bug Verifications', () {
    test(
        'Bug 6: SeedingPolicy respects charging and wifi constraints even when minSeedTimeMinutes > 0',
        () {
      const policy = SeedingPolicy(
        minSeedTimeMinutes: 60,
        seedOnlyWhenCharging: true,
        seedOnlyOnWifi: true,
      );

      // Even though seedDuration (5 min) < minSeedTimeMinutes (60 min),
      // if not charging, shouldStopSeeding must return true!
      final notChargingStop = policy.shouldStopSeeding(
        currentRatio: 0.5,
        seedDuration: const Duration(minutes: 5),
        uploadedBytes: 1000,
        isCharging: false,
        isOnWifi: true,
      );
      expect(notChargingStop, isTrue);

      // If on cellular, shouldStopSeeding must return true!
      final cellularStop = policy.shouldStopSeeding(
        currentRatio: 0.5,
        seedDuration: const Duration(minutes: 5),
        uploadedBytes: 1000,
        isCharging: true,
        isOnWifi: false,
      );
      expect(cellularStop, isTrue);

      // If charging and on wifi and under ratio/time, should return false (continue seeding)
      final continueSeeding = policy.shouldStopSeeding(
        currentRatio: 0.5,
        seedDuration: const Duration(minutes: 5),
        uploadedBytes: 1000,
        isCharging: true,
        isOnWifi: true,
      );
      expect(continueSeeding, isFalse);
    });

    test(
        'Bug 5: computePerTaskUploadLimit never exceeds globalLimit when active count is high',
        () {
      final settings = SettingsProvider();
      settings.globalTorrentSeedingLimited = true;
      settings.globalTorrentSeedingLimitKbps = 2; // 2 KB/s = 2048 bytes/s

      // 5 active seeders: 2048 ~/ 5 = 409 B/s.
      // Must not be clamped up to 1024 B/s (which would total 5120 B/s > 2048)!
      final perTask = TorrentSeedingManager.computePerTaskUploadLimit(
        settings: settings,
        activeSeedingCount: 5,
        batteryMode: BatterySaverMode.off,
        thermalStatus: ThermalStatus.none,
      );

      expect(perTask * 5 <= 2048, isTrue);
      expect(perTask, equals(409));
    });

    test('Bug 2 & 4 / B21: resumeBlobFor caches data only after the engine accepts it',
        () async {
      final fake = FakeTorrentNative();
      TorrentService.setNativeForTesting(fake);
      addTearDown(() => TorrentService.dispose());

      final sampleData = Uint8List.fromList([0x64, 0x31, 0x30, 0x65]);

      // Engine accepts the blob → it is cached and fetchable.
      expect(TorrentService.loadResumeData(999, sampleData), isTrue);
      expect(TorrentService.resumeBlobFor(999), equals(sampleData));
      expect(TorrentService.fetchResumeBytes(999), equals(sampleData));

      // B21: a blob the engine REJECTS (1.9.2: loadResumeData always fails)
      // must not be cached — the old cache-before-accept behavior made the
      // pause path trust a phantom blob and skip the degraded snapshot.
      fake.simulateResumeLoadFailure = true;
      expect(TorrentService.loadResumeData(998, sampleData), isFalse);
      expect(TorrentService.resumeBlobFor(998), isNull);
    });
  });
}
