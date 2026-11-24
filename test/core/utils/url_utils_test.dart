import 'package:dio/dio.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const hash40 = '5dee65101db75097c523f19f074d0a64087dbcd3';
  const hash64 =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
  const base32Hash = 'MR6EKEINW5KJPRFD6GPQPTHKMQEH3P5T';

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

    test('parseMagnetUrl handles a real multi-tracker magnet with encoded name',
        () {
      const magnet = 'magnet:?xt=urn:btih:'
          'E933E2AFD654F2CBFB9C3A322BC4FFBA13CBA978'
          '&dn=AI+Grammar+Studio+v1.4.0+Pre-Cracked+%7BCracksHash%7D'
          '&tr=https%3A%2F%2Fedge-team.cc%2Fannounce'
          '&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce';

      expect(isMagnetUrl(magnet), isTrue);
      final parsed = parseMagnetUrl(magnet);
      expect(parsed['infoHashV1'],
          equals('E933E2AFD654F2CBFB9C3A322BC4FFBA13CBA978'));
      expect(parsed['infoHash'],
          equals('E933E2AFD654F2CBFB9C3A322BC4FFBA13CBA978'));
      expect(parsed['name'],
          equals('AI Grammar Studio v1.4.0 Pre-Cracked {CracksHash}'));
    });

    test('isTorrentFileUrl identifies .torrent files and schemes', () {
      expect(
          isTorrentFileUrl(
              'https://releases.ubuntu.com/22.04/ubuntu.iso.torrent'),
          true);
      expect(isTorrentFileUrl('file:///sdcard/Download/test.torrent'), true);
      expect(isTorrentFileUrl('https://example.com/image.png'), false);
    });

    test('isValidTransmissionUrl accepts http, https, magnet, and torrents',
        () {
      expect(
          isValidTransmissionUrl('https://cdn.test.org/archive.tar.gz'), true);
      expect(isValidTransmissionUrl('ftp://ftp.is.co.za/linux'), true);
      expect(
          isValidTransmissionUrl(
              'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567'),
          true);
      expect(isValidTransmissionUrl('plain text string'), false);
    });

    test(
        'isSafeIntentUrl accepts only http, https, and magnet schemes while rejecting dangerous schemes (S4)',
        () {
      expect(isSafeIntentUrl('https://example.com/file.zip'), isTrue);
      expect(isSafeIntentUrl('http://example.com/file.zip'), isTrue);
      expect(
          isSafeIntentUrl(
              'magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709'),
          isTrue);

      // Dangerous & injection schemes must be rejected
      expect(isSafeIntentUrl('javascript:alert(1)'), isFalse);
      expect(
          isSafeIntentUrl('data:text/html,<script>alert(1)</script>'), isFalse);
      expect(isSafeIntentUrl('file:///etc/passwd'), isFalse);
      expect(
          isSafeIntentUrl('content://media/external/images/media/1'), isFalse);
      expect(isSafeIntentUrl('about:blank'), isFalse);
      expect(isSafeIntentUrl('blob:http://example.com/123'), isFalse);
    });

    test('isSafeWebUrl allows safe schemes and blocks dangerous ones', () {
      expect(isSafeWebUrl('https://example.com/a'), isTrue);
      expect(isSafeWebUrl('http://example.com/a'), isTrue);
      expect(isSafeWebUrl('magnet:?xt=urn:btih:$hash40'), isTrue);
      expect(isSafeWebUrl('file:///tmp/a'), isTrue);
      expect(isSafeWebUrl('content://media/1'), isTrue);
      expect(isSafeWebUrl('dmx://open'), isTrue);

      expect(isSafeWebUrl('javascript:alert(1)'), isFalse);
      expect(isSafeWebUrl('data:text/html,x'), isFalse);
      expect(isSafeWebUrl('vbscript:msgbox'), isFalse);
      expect(isSafeWebUrl('about:blank'), isFalse);
      expect(isSafeWebUrl('ftp://example.com'), isFalse);
      expect(isSafeWebUrl('ftps://example.com'), isFalse);
      expect(isSafeWebUrl('   '), isFalse);
    });

    test('extractUrlFromText handles magnets, torrents, and punctuation', () {
      expect(
        extractUrlFromText('magnet:?xt=urn:btih:$hash40'),
        'magnet:?xt=urn:btih:$hash40',
      );
      expect(
        extractUrlFromText('See https://files.com/doc.pdf, thanks!'),
        'https://files.com/doc.pdf',
      );
      expect(
        extractUrlFromText('https://files.com/ubuntu.iso.torrent'),
        'https://files.com/ubuntu.iso.torrent',
      );
      expect(extractUrlFromText('no urls here'), isNull);
    });

    test('isMagnetUrl recognizes tracker-only, base32, and v2 hashes', () {
      expect(isMagnetUrl('magnet:?tr=udp://tracker.org:1337'), isTrue);
      expect(isMagnetUrl('magnet:?xt=urn:btih:$base32Hash'), isTrue);
      expect(isMagnetUrl('magnet:?xt=urn:btih:$hash64'), isTrue);
      expect(isMagnetUrl('magnet:?xt=urn:btih:not-a-hash'), isFalse);
      expect(isMagnetUrl('https://example.com'), isFalse);
    });

    test('isTorrentUrl recognizes magnet, filename, and torrent paths', () {
      expect(isTorrentUrl('magnet:?xt=urn:btih:$hash40'), isTrue);
      expect(
        isTorrentUrl('https://example.com/download', fileName: 'movie.torrent'),
        isTrue,
      );
      expect(isTorrentUrl('https://example.com/a.torrent'), isTrue);
      expect(isTorrentUrl('https://example.com/a.zip'), isFalse);
    });

    test('isValidTransmissionUrl accepts ftp and torrent variants', () {
      expect(isValidTransmissionUrl('ftp://host/file'), isTrue);
      expect(isValidTransmissionUrl('ftps://host/file'), isTrue);
      expect(isValidTransmissionUrl('https://host/a.torrent'), isTrue);
      expect(isValidTransmissionUrl('plain-file.torrent'), isTrue);
      expect(
          isValidTransmissionUrl('magnet:?tr=udp://tracker.org:1337'), isTrue);
      expect(isValidTransmissionUrl('random text'), isFalse);
    });

    test('analyzeUrl and analyzeMagnet delegate to site intelligence', () {
      expect(analyzeUrl('https://cdn.example.com/video.mp4'), isNotNull);
      expect(analyzeUrl(''), isNotNull);
      expect(
        analyzeMagnet('magnet:?xt=urn:btih:$hash40&dn=movie%201080p'),
        isNotNull,
      );
    });

    test('parseMagnetUrl captures v2-only, hybrid, and base32 hashes', () {
      final v2 = parseMagnetUrl('magnet:?xt=urn:btmh:1220$hash64&dn=V2');
      expect(v2['infoHashV2'], hash64.toUpperCase());
      expect(v2['isV2Only'], 'true');
      expect(v2['name'], 'V2');

      final hybrid = parseMagnetUrl(
        'magnet:?xt=urn:btih:$hash40&xt=urn:btmh:1220$hash64',
      );
      expect(hybrid['isHybrid'], 'true');
      expect(hybrid['infoHashV1'], isNotNull);
      expect(hybrid['infoHashV2'], isNotNull);

      final base32 = parseMagnetUrl('magnet:?xt=urn:btih:$base32Hash');
      expect(base32['infoHash'], isNotNull);
      expect((base32['infoHash'] as String).length, 40);

      final v1 = parseMagnetUrl('magnet:?xt=urn:btih:$hash40');
      expect(v1['isV1Only'], 'true');
    });

    test('parseMagnetUrl returns an empty map for non-magnets', () {
      expect(parseMagnetUrl('https://example.com'), isEmpty);
    });

    test('fileNameFromUrl derives a safe name or falls back', () {
      expect(
        fileNameFromUrl('https://example.com/path/report%20final.pdf'),
        'report final.pdf',
      );
      expect(fileNameFromUrl('https://example.com/'), startsWith('download_'));
    });

    test('fileNameFromContentDisposition handles RFC5987 and quoted forms', () {
      Headers header(Map<String, List<String>> map) => Headers.fromMap(map);

      expect(fileNameFromContentDisposition(header({})), isNull);
      expect(
        fileNameFromContentDisposition(header({
          'content-disposition': ["attachment; filename*=UTF-8''na%20me.pdf"],
        })),
        'na me.pdf',
      );
      expect(
        fileNameFromContentDisposition(header({
          'content-disposition': ['attachment; filename="a b.zip"'],
        })),
        'a b.zip',
      );
      expect(
        fileNameFromContentDisposition(header({
          'content-disposition': ['attachment; filename=raw.bin'],
        })),
        'raw.bin',
      );
    });

    test('convertIdnToPunycode encodes unicode hosts and keeps ASCII', () {
      const ascii = 'https://www.example.com/search?q=test';
      expect(convertIdnToPunycode(ascii), ascii);

      final puny = convertIdnToPunycode('https://münchen.de/path');
      expect(puny, contains('xn--'));

      expect(convertIdnToPunycode('https://'), 'https://');
    });

    test('UrlValidator.isValid enforces the scheme and length policy', () {
      expect(UrlValidator.isValid(null), isFalse);
      expect(UrlValidator.isValid(''), isFalse);
      expect(UrlValidator.isValid('   '), isFalse);
      expect(UrlValidator.isValid('https://example.com/a'), isTrue);
      expect(UrlValidator.isValid('http://example.com'), isTrue);
      expect(UrlValidator.isValid('ftp://example.com'), isTrue);
      expect(
          UrlValidator.isValid('ftp://example.com', allowFtp: false), isFalse);
      expect(UrlValidator.isValid('magnet:?xt=urn:btih:$hash40'), isTrue);
      expect(
        UrlValidator.isValid('magnet:?xt=urn:btih:$hash40', allowMagnet: false),
        isFalse,
      );
      expect(UrlValidator.isValid('dmx://open'), isTrue);
      expect(UrlValidator.isValid('javascript:alert(1)'), isFalse);
      expect(UrlValidator.isValid('data:text/html,x'), isFalse);
      expect(UrlValidator.isValid('not-a-url'), isFalse);
      expect(UrlValidator.isValid('https://example.com/\u0001'), isFalse);

      final tooLong = 'https://example.com/${List.filled(2100, 'a').join()}';
      expect(UrlValidator.isValid(tooLong), isFalse);
    });

    test('UrlValidator.sanitize strips control characters and empty results',
        () {
      expect(UrlValidator.sanitize(null), isNull);
      expect(UrlValidator.sanitize('   '), isNull);
      expect(UrlValidator.sanitize('  https://x/a \u0001 '), 'https://x/a');
    });

    test('isTorrentUrl survives an unparseable URL', () {
      expect(isTorrentUrl('http://[::1'), isFalse);
    });

    test('parseMagnetUrl strips the btmh 1220 multihash header in btih', () {
      final parsed = parseMagnetUrl('magnet:?xt=urn:btih:1220$hash64');
      expect(parsed['infoHashV1'], hash64.toUpperCase());
    });

    test('parseMagnetUrl falls back to the generic xt capture', () {
      final parsed = parseMagnetUrl('magnet:?xt=urn:btmh:zz');
      expect(parsed['infoHash'], 'ZZ');
    });

    test('parseMagnetUrl tolerates an undecodable display name', () {
      final parsed = parseMagnetUrl(
        'magnet:?xt=urn:btih:$hash40&dn=%E0%A4%A',
      );
      expect(parsed['name'], '%E0%A4%A');
    });

    test('parseMagnetUrl reads an empty display name from the query', () {
      final parsed = parseMagnetUrl('magnet:?xt=urn:btih:$hash40&dn=');
      expect(parsed['name'], '');
    });

    test('fileNameFromContentDisposition tolerates undecodable RFC5987', () {
      final headers = Headers.fromMap({
        'content-disposition': ["attachment; filename*=UTF-8''%E0%A4%A"],
      });
      expect(fileNameFromContentDisposition(headers), isNotNull);
    });

    test('convertIdnToPunycode returns the original for unparseable hosts', () {
      expect(convertIdnToPunycode('https://['), 'https://[');
      expect(convertIdnToPunycode('https://a%zz.com/x'), 'https://a%zz.com/x');
    });

    test('convertIdnToPunycode handles long unicode labels', () {
      final host = List.filled(30, 'ü').join();
      final result = convertIdnToPunycode('https://$host.de/path');
      expect(result, contains('xn--'));
    });

    test('convertIdnToPunycode handles far-from-ASCII runes', () {
      final host = List.filled(5, '中').join();
      final result = convertIdnToPunycode('https://$host.de/path');
      expect(result, contains('xn--'));
    });
  });
}
