import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/utils/url_utils.dart';

void main() {
  group('UrlUtils', () {
    test('isHttpUrl correctly validates HTTP and HTTPS links', () {
      expect(isHttpUrl('https://example.com/file.zip'), true);
      expect(isHttpUrl('http://insecure.site/test'), true);
      expect(isHttpUrl('ftp://example.com'), false);
      expect(isHttpUrl('not a url'), false);
      expect(isHttpUrl(''), false);
    });

    test('extractUrlFromText extracts URLs embedded inside messages', () {
      const msg = 'Check out this download: https://files.com/doc.pdf thanks!';
      final extracted = extractUrlFromText(msg);
      expect(extracted, 'https://files.com/doc.pdf');
    });

    test('isMagnetUrl identifies valid BitTorrent magnet URIs', () {
      const validHex40 =
          'magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709&dn=Ubuntu';
      const validHex2 =
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567';
      const invalid = 'https://example.com/not-a-magnet';

      expect(isMagnetUrl(validHex40), true);
      expect(isMagnetUrl(validHex2), true);
      expect(isMagnetUrl(invalid), false);
    });

    test('isTorrentFileUrl identifies .torrent files and schemes', () {
      expect(isTorrentFileUrl('https://releases.ubuntu.com/22.04/ubuntu.iso.torrent'), true);
      expect(isTorrentFileUrl('file:///sdcard/Download/test.torrent'), true);
      expect(isTorrentFileUrl('https://example.com/image.png'), false);
    });

    test('isValidTransmissionUrl accepts http, https, magnet, and torrents', () {
      expect(isValidTransmissionUrl('https://cdn.test.org/archive.tar.gz'), true);
      expect(isValidTransmissionUrl('ftp://ftp.is.co.za/linux'), true);
      expect(isValidTransmissionUrl('magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567'), true);
      expect(isValidTransmissionUrl('plain text string'), false);
    });
  });
}
