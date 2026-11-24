import 'package:dmx/core/services/site_intelligence/url_patterns.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UrlPatterns regexes', () {
    test('qualityRegex matches resolution markers', () {
      expect(UrlPatterns.qualityRegex.firstMatch('movie.1080p.mkv')?.group(0),
          '1080p');
      expect(
          UrlPatterns.qualityRegex
              .firstMatch('clip 4K')
              ?.group(0)
              ?.toLowerCase(),
          '4k');
      expect(UrlPatterns.qualityRegex.hasMatch('no quality here'), isFalse);
    });

    test('magnet regexes extract hash, name and trackers', () {
      const magnet =
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567'
          '&dn=My%20File&tr=udp%3A%2F%2Ftracker.example%2Fannounce'
          '&tr=https%3A%2F%2Ft2.example%2Fannounce';
      expect(UrlPatterns.magnetHashRegex.firstMatch(magnet)?.group(1),
          '0123456789abcdef0123456789abcdef01234567');
      expect(UrlPatterns.magnetNameRegex.firstMatch(magnet)?.group(1),
          'My%20File');
      expect(UrlPatterns.magnetTrackerRegex.allMatches(magnet).length, 2);
    });

    test('magnetHashRegex supports v2 and base32 hashes', () {
      const v2 = 'magnet:?xt=urn:btmh:1220'
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
      expect(UrlPatterns.magnetHashRegex.hasMatch(v2), isTrue);
      const b32 = 'magnet:?xt=urn:btih:ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
      expect(UrlPatterns.magnetHashRegex.hasMatch(b32), isTrue);
    });

    test('torrent metadata regexes', () {
      expect(
          UrlPatterns.releaseGroupRegex.firstMatch('[GROUP] title')?.group(1),
          'GROUP');
      expect(UrlPatterns.yearRegex.hasMatch('Movie.2021.1080p'), isTrue);
      expect(UrlPatterns.videoCodecRegex.hasMatch('x265'), isTrue);
      expect(UrlPatterns.audioCodecRegex.hasMatch('DTS'), isTrue);
      expect(UrlPatterns.sourceRegex.hasMatch('WEB-DL'), isTrue);
    });
  });

  group('isExpiryOrSignatureParam', () {
    test('known expiry parameter names are detected', () {
      for (final key in ['token', 'expires', 'signature', 'sig', 'auth']) {
        expect(UrlPatterns.isExpiryOrSignatureParam(key, 'anything'), isTrue,
            reason: key);
      }
    });

    test('numeric st/exp above the epoch threshold counts as expiry', () {
      expect(UrlPatterns.isExpiryOrSignatureParam('st', '1700000000'), isTrue);
      expect(UrlPatterns.isExpiryOrSignatureParam('exp', '1700000000'), isTrue);
      expect(UrlPatterns.isExpiryOrSignatureParam('st', '123'), isFalse);
      expect(UrlPatterns.isExpiryOrSignatureParam('exp', 'notnum'), isFalse);
    });

    test('h/key with a long hex-like value counts as a signature', () {
      expect(UrlPatterns.isExpiryOrSignatureParam('h', 'abcdef0123456789'),
          isTrue);
      expect(UrlPatterns.isExpiryOrSignatureParam('key', 'abcdef0123456789'),
          isTrue);
      expect(UrlPatterns.isExpiryOrSignatureParam('h', 'short'), isFalse);
      expect(UrlPatterns.isExpiryOrSignatureParam('key', 'not-hex-value!!'),
          isFalse);
    });

    test('unrelated params return false', () {
      expect(UrlPatterns.isExpiryOrSignatureParam('page', '2'), isFalse);
    });
  });

  group('extension sets', () {
    test('cover representative extensions', () {
      expect(UrlPatterns.videoExtensions, contains('.mp4'));
      expect(UrlPatterns.audioExtensions, contains('.mp3'));
      expect(UrlPatterns.archiveExtensions, contains('.zip'));
      expect(UrlPatterns.softwareExtensions, contains('.apk'));
      expect(UrlPatterns.documentExtensions, contains('.pdf'));
      expect(UrlPatterns.imageExtensions, contains('.png'));
    });
  });
}
