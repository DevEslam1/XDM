import 'package:dmx/core/domain/torrent_session_settings.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guard against dead torrent settings (Plan 05 Task 5.8).
///
/// Every field of [TorrentSessionSettings] that the settings UI can change must
/// reach the native [NativeBtConfig]; anything the 1.9.2 bridge cannot honour
/// must instead be gated behind a `*Supported` capability flag so the UI hides
/// it rather than showing a functionless control. These tests fail loudly if a
/// future edit drops a mapping or flips a gate without wiring the native side.
void main() {
  group('Torrent session config wiring guard (Plan 05 Task 5.8)', () {
    late FakeTorrentNative fakeNative;

    setUp(() {
      fakeNative = FakeTorrentNative();
      TorrentService.setNativeForTesting(fakeNative);
    });

    test('configureSession maps every wired setting to NativeBtConfig', () {
      const settings = TorrentSessionSettings(
        enableDht: false,
        enableUpnp: false,
        forceEncrypt: true,
        torrentConnectionsLimit: 321,
        downloadRateLimitKbps: 500,
        uploadRateLimitKbps: 250,
        sequentialDownload: true,
        shareRatioLimit: 3.0,
        maxSeedingTimeMinutes: 120,
        enableUtp: false,
        diskCacheSizeBytes: 200 * 1024 * 1024,
      );

      TorrentService.configureSession(settings);

      final config = fakeNative.lastConfig;
      expect(config, isNotNull,
          reason: 'configureSession must forward a NativeBtConfig to native');
      // Boolean toggles are inverted at the boundary (enable -> disable).
      expect(config!.disableDht, isTrue);
      expect(config.disableUpnp, isTrue);
      expect(config.forceEncrypt, isTrue);
      expect(config.connectionsLimit, 321);
      // Rate limits cross the boundary in Bytes/s (kbps * 1024).
      expect(config.downloadRateLimit, 500 * 1024);
      expect(config.uploadRateLimit, 250 * 1024);

      // Session-level state that lives on TorrentService rather than BtConfig.
      expect(TorrentService.sequentialDownloadEnabled, isTrue);
      expect(TorrentService.shareRatioLimit, 3.0);
      expect(TorrentService.maxSeedingTimeMinutes, 120);
    });

    test('enableUtp and diskCacheSizeMb reach the native BtConfig (Phase A)',
        () {
      // Previously these two UI controls were dead: the toggle/slider updated
      // the provider but configureSession never populated the BtConfig fields.
      const utpOff = TorrentSessionSettings(
        enableUtp: false,
        diskCacheSizeBytes: 128 * 1024 * 1024,
      );
      TorrentService.configureSession(utpOff);
      expect(fakeNative.lastConfig!.disableUtp, isTrue,
          reason: 'enableUtp:false must disable uTP at the native layer');
      expect(fakeNative.lastConfig!.cacheSize, 128 * 1024 * 1024,
          reason: 'diskCacheSizeBytes must set the native disk cache size');

      const utpOn = TorrentSessionSettings(enableUtp: true);
      TorrentService.configureSession(utpOn);
      expect(fakeNative.lastConfig!.disableUtp, isFalse,
          reason: 'enableUtp:true must leave uTP enabled');
    });

    test('unsupported toggles stay gated behind false capability flags', () {
      // libtorrent 1.9.2 exposes no BtConfig knob for these, so the settings UI
      // hides them. If a future bridge adds support and someone flips a flag
      // true, they must also wire the native side (and update this guard).
      expect(TorrentService.peerExchangeSupported, isFalse);
      expect(TorrentService.localPeerDiscoverySupported, isFalse);
      expect(TorrentService.natPmpSupported, isFalse);
      expect(TorrentService.anonymousModeSupported, isFalse);
      expect(TorrentService.perTorrentConnectionLimitSupported, isFalse);
    });
  });
}
