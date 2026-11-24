import 'package:dmx/core/domain/torrent_session_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TorrentSessionSettings', () {
    test('defaults', () {
      const s = TorrentSessionSettings();
      expect(s.enableDht, isTrue);
      expect(s.enableUpnp, isTrue);
      expect(s.forceEncrypt, isFalse);
      expect(s.torrentConnectionsLimit, 200);
      expect(s.downloadRateLimitKbps, 0);
      expect(s.uploadRateLimitKbps, 0);
      expect(s.sequentialDownload, isFalse);
      expect(s.shareRatioLimit, 0.0);
      expect(s.maxSeedingTimeMinutes, 0);
      expect(s.enableUtp, isTrue);
      expect(s.diskCacheSizeBytes, 64 * 1024 * 1024);
    });

    test('validated factory accepts valid values', () {
      final s = TorrentSessionSettings.validated(
        enableDht: false,
        enableUpnp: false,
        forceEncrypt: true,
        torrentConnectionsLimit: 10,
        downloadRateLimitKbps: 1,
        uploadRateLimitKbps: 2,
        sequentialDownload: true,
        shareRatioLimit: 1.5,
        maxSeedingTimeMinutes: 60,
        enableUtp: false,
        diskCacheSizeBytes: 1024,
      );
      expect(s.torrentConnectionsLimit, 10);
      expect(s.shareRatioLimit, 1.5);
      expect(s.sequentialDownload, isTrue);
    });

    test('validated factory throws on invalid values', () {
      expect(
        () => TorrentSessionSettings.validated(torrentConnectionsLimit: 0),
        throwsArgumentError,
      );
      expect(
        () => TorrentSessionSettings.validated(downloadRateLimitKbps: -1),
        throwsArgumentError,
      );
      expect(
        () => TorrentSessionSettings.validated(uploadRateLimitKbps: -1),
        throwsArgumentError,
      );
      expect(
        () => TorrentSessionSettings.validated(shareRatioLimit: -0.1),
        throwsArgumentError,
      );
      expect(
        () => TorrentSessionSettings.validated(maxSeedingTimeMinutes: -1),
        throwsArgumentError,
      );
      expect(
        () => TorrentSessionSettings.validated(diskCacheSizeBytes: 0),
        throwsArgumentError,
      );
    });

    test('copyWith overrides and defaults', () {
      const base = TorrentSessionSettings();
      final modified = base.copyWith(
        enableDht: false,
        torrentConnectionsLimit: 5,
        shareRatioLimit: 2.0,
      );
      expect(modified.enableDht, isFalse);
      expect(modified.torrentConnectionsLimit, 5);
      expect(modified.shareRatioLimit, 2.0);
      expect(modified.enableUpnp, base.enableUpnp);

      expect(base.copyWith(), equals(base));
    });

    test('equality and hashCode', () {
      const a = TorrentSessionSettings();
      const b = TorrentSessionSettings();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a == Object(), isFalse);
      expect(a.copyWith(forceEncrypt: true) == a, isFalse);
      expect(
        const TorrentSessionSettings(torrentConnectionsLimit: 1).hashCode,
        isNot(equals(a.hashCode)),
      );
    });
  });
}
