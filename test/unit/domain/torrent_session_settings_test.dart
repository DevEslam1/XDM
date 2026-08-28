import 'package:dmx/core/domain/torrent_session_settings.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (methodCall) async => null,
    );
  });

  group('TorrentSessionSettings Value Object & Clean Architecture (P0-5)', () {
    test('default values are initialized correctly', () {
      const settings = TorrentSessionSettings();
      expect(settings.enableDht, isTrue);
      expect(settings.enableUpnp, isTrue);
      expect(settings.forceEncrypt, isFalse);
      expect(settings.torrentConnectionsLimit, 200);
      expect(settings.downloadRateLimitKbps, 0);
      expect(settings.uploadRateLimitKbps, 0);
      expect(settings.sequentialDownload, isFalse);
      expect(settings.shareRatioLimit, 0.0);
      expect(settings.maxSeedingTimeMinutes, 0);
      expect(settings.enableUtp, isTrue);
      expect(settings.diskCacheSizeBytes, 64 * 1024 * 1024);
    });

    test('copyWith updates fields correctly', () {
      const settings = TorrentSessionSettings();
      final updated = settings.copyWith(
        enableDht: false,
        torrentConnectionsLimit: 100,
        sequentialDownload: true,
        shareRatioLimit: 2.5,
        enableUtp: false,
        diskCacheSizeBytes: 128 * 1024 * 1024,
      );

      expect(updated.enableDht, isFalse);
      expect(updated.torrentConnectionsLimit, 100);
      expect(updated.sequentialDownload, isTrue);
      expect(updated.shareRatioLimit, 2.5);
      expect(updated.enableUpnp, isTrue);
      expect(updated.enableUtp, isFalse);
      expect(updated.diskCacheSizeBytes, 128 * 1024 * 1024);
    });

    test('SettingsProvider maps correctly to TorrentSessionSettings', () async {
      SharedPreferences.setMockInitialValues({
        'enableDht': false,
        'torrentConnectionsLimit': 150,
        'sequentialDownload': true,
        'enableUtp': false,
        'diskCacheSizeMb': 256,
      });

      final provider = SettingsProvider.instance;
      await provider.load();

      final sessionSettings = provider.toTorrentSessionSettings();
      expect(sessionSettings.enableDht, isFalse);
      expect(sessionSettings.torrentConnectionsLimit, 150);
      expect(sessionSettings.sequentialDownload, isTrue);
      expect(sessionSettings.enableUtp, isFalse);
      expect(sessionSettings.diskCacheSizeBytes, 256 * 1024 * 1024);
    });
  });
}
