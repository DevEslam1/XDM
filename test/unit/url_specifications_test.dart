import 'package:dmx/core/domain/utils/url_specifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UrlSpecifications', () {
    test('isHttpUrl correctly classifies HTTP and HTTPS schemes', () {
      expect(
          UrlSpecifications.isHttpUrl('https://example.com/file.zip'), isTrue);
      expect(
          UrlSpecifications.isHttpUrl('http://example.com/file.zip'), isTrue);
      expect(
          UrlSpecifications.isHttpUrl('ftp://example.com/file.zip'), isFalse);
      expect(UrlSpecifications.isHttpUrl(''), isFalse);
    });

    test('isMagnetUrl correctly parses v1 and v2 magnet infohashes', () {
      const v1Magnet =
          'magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709&dn=test';
      const invalidMagnet = 'magnet:?invalid=true';
      expect(UrlSpecifications.isMagnetUrl(v1Magnet), isTrue);
      expect(UrlSpecifications.isMagnetUrl(invalidMagnet), isFalse);
    });

    test('parseMagnetUrl extracts dn, xt, tr cleanly', () {
      const magnet =
          'magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709&dn=Ubuntu+ISO&tr=http%3A%2F%2Ftracker.example.com%3A80%2Fannounce';
      final parsed = UrlSpecifications.parseMagnetUrl(magnet);
      expect(parsed['name'], equals('Ubuntu ISO'));
      expect(parsed['infoHash'],
          equals('DA39A3EE5E6B4B0D3255BFEF95601890AFD80709'));
      expect(parsed['trackers'],
          contains('http://tracker.example.com:80/announce'));
    });

    test('isTorrentFileUrl correctly classifies local and remote torrent links',
        () {
      expect(
          UrlSpecifications.isTorrentFileUrl('file:///sdcard/download.torrent'),
          isTrue);
      expect(
          UrlSpecifications.isTorrentFileUrl(
              'https://example.com/linux.torrent?pass=123'),
          isTrue);
      expect(UrlSpecifications.isTorrentFileUrl('https://example.com/file.mp4'),
          isFalse);
    });
  });
}
