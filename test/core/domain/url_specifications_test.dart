import 'package:dmx/core/domain/utils/url_specifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UrlSpecifications P0 and Domain Specification Tests', () {
    test('isHttpUrl correctly validates HTTP and HTTPS schemes', () {
      expect(UrlSpecifications.isHttpUrl('https://example.com/file.zip'), isTrue);
      expect(UrlSpecifications.isHttpUrl('http://example.com/file.zip'), isTrue);
      expect(UrlSpecifications.isHttpUrl('ftp://example.com/file.zip'), isFalse);
      expect(UrlSpecifications.isHttpUrl(''), isFalse);
      expect(UrlSpecifications.isHttpUrl('   '), isFalse);
    });

    test('P0-1: isTorrentFileUrl restricts file:// and content:// URIs to .torrent or MIME', () {
      // Valid torrent files
      expect(UrlSpecifications.isTorrentFileUrl('file:///sdcard/download.torrent'), isTrue);
      expect(UrlSpecifications.isTorrentFileUrl('content://media/external/files/123.torrent'), isTrue);
      expect(UrlSpecifications.isTorrentFileUrl('https://example.com/arch.torrent?pass=1'), isTrue);
      expect(UrlSpecifications.isTorrentFileUrl('content://com.android.providers.media.documents/document/document%3A1000000035', mimeType: 'application/x-bittorrent'), isTrue);

      // Normal files via SAF / file / content (must NOT be treated as torrents)
      expect(UrlSpecifications.isTorrentFileUrl('content://media/external/files/document.pdf'), isFalse);
      expect(UrlSpecifications.isTorrentFileUrl('file:///storage/emulated/0/Download/photo.jpg'), isFalse);
      expect(UrlSpecifications.isTorrentFileUrl('content://com.android.providers.media.documents/document/document%3A1000000035'), isFalse);
      expect(UrlSpecifications.isTorrentFileUrl('https://example.com/video.mp4'), isFalse);
    });

    test('P2-7: isMagnetUrl strict vs lenient mode', () {
      const v1Hex = 'magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709&dn=test';
      const v1Base32 = 'magnet:?xt=urn:btih:N46PXXS6NNVEMMRVV7XZKYAYBL65QBYJ&dn=test';
      const v2Hex64 = 'magnet:?xt=urn:btmh:1220da39a3ee5e6b4b0d3255bfef95601890afd80709da39a3ee5e6b4b0d3255bfef&dn=test_v2';
      const trackerOnly = 'magnet:?tr=http%3A%2F%2Ftracker.example.com%3A80%2Fannounce&dn=tracker_only';
      const invalidMagnet = 'magnet:?invalid=true';
      const notMagnet = 'https://example.com';

      // Strict mode (default)
      expect(UrlSpecifications.isMagnetUrl(v1Hex, strict: true), isTrue);
      expect(UrlSpecifications.isMagnetUrl(v1Base32, strict: true), isTrue);
      expect(UrlSpecifications.isMagnetUrl(v2Hex64, strict: true), isTrue);
      expect(UrlSpecifications.isMagnetUrl(trackerOnly, strict: true), isFalse);
      expect(UrlSpecifications.isMagnetUrl(invalidMagnet, strict: true), isFalse);
      expect(UrlSpecifications.isMagnetUrl(notMagnet, strict: true), isFalse);

      // Lenient mode
      expect(UrlSpecifications.isMagnetUrl(trackerOnly, strict: false), isTrue);
      expect(UrlSpecifications.isMagnetUrl(invalidMagnet, strict: false), isFalse);
    });

    test('resolveTorrentUriKind resolves Uri correctly', () {
      final magnetUri = Uri.parse('magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709&dn=test');
      final torrentFileUri = Uri.parse('file:///storage/emulated/0/Download/ubuntu.torrent');
      final safPdfUri = Uri.parse('content://com.android.providers.media.documents/document/document%3A1000000035');
      final safTorrentUri = Uri.parse('content://com.android.providers.media.documents/document/document%3A1000000035');
      final httpUri = Uri.parse('https://example.com/file.zip');

      expect(UrlSpecifications.resolveTorrentUriKind(magnetUri), TorrentUriKind.magnet);
      expect(UrlSpecifications.resolveTorrentUriKind(torrentFileUri), TorrentUriKind.torrentFile);
      expect(UrlSpecifications.resolveTorrentUriKind(safPdfUri), TorrentUriKind.notTorrent);
      expect(UrlSpecifications.resolveTorrentUriKind(safTorrentUri, mimeType: 'application/x-bittorrent'), TorrentUriKind.torrentFile);
      expect(UrlSpecifications.resolveTorrentUriKind(httpUri), TorrentUriKind.notTorrent);
    });
  });
}
