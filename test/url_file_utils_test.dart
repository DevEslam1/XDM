import 'package:dio/dio.dart';
import 'package:dmx/core/utils/file_utils.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fileNameFromUrl extracts and sanitizes names', () {
    expect(
      fileNameFromUrl('https://example.com/files/My%20Video.mp4?token=1'),
      'My Video.mp4',
    );
    expect(fileNameFromUrl('https://example.com/'), startsWith('download_'));
  });

  test('categoryFromFileName maps common extensions', () {
    expect(categoryFromFileName('movie.mkv'), 'Video');
    expect(categoryFromFileName('song.flac'), 'Audio');
    expect(categoryFromFileName('report.pdf'), 'Document');
    expect(categoryFromFileName('bundle.7z'), 'Archive');
    expect(categoryFromFileName('app.apk'), 'APK');
    expect(categoryFromFileName('unknown.bin'), 'Other');
  });

  test('isHttpUrl accepts only complete HTTP URLs', () {
    expect(isHttpUrl('https://example.com/file.zip'), isTrue);
    expect(isHttpUrl('http://example.com/file.zip'), isTrue);
    expect(isHttpUrl('ftp://example.com/file.zip'), isFalse);
    expect(isHttpUrl('https:///file.zip'), isFalse);
  });

  group('Magnet URL Tests', () {
    const validHex40 = 'magnet:?xt=urn:btih:5dee65101db75097c523f19f074d0a64087dbcd3&dn=Ubuntu';
    const validBase32 = 'magnet:?xt=urn:btih:MR6EKEINW5KJPRFD6GPQPTHKMQEH3P5T';
    const validHex64 = 'magnet:?xt=urn:btih:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    
    const invalidNoXt = 'magnet:?dn=Ubuntu';
    const invalidShortHash = 'magnet:?xt=urn:btih:5dee65101db75097';
    const invalidCharHash = 'magnet:?xt=urn:btih:5dee65101db75097c523f19f074d0a64087dbcg3'; // 'g' is not hex

    test('isMagnetUrl validates correct formats', () {
      expect(isMagnetUrl(validHex40), isTrue);
      expect(isMagnetUrl(validBase32), isTrue);
      expect(isMagnetUrl(validHex64), isTrue);

      expect(isMagnetUrl(invalidNoXt), isFalse);
      expect(isMagnetUrl(invalidShortHash), isFalse);
      expect(isMagnetUrl(invalidCharHash), isFalse);
      expect(isMagnetUrl('https://example.com'), isFalse);
    });

    test('parseMagnetUrl extracts dn and infoHash', () {
      final parsed1 = parseMagnetUrl(validHex40);
      expect(parsed1['infoHash'], '5DEE65101DB75097C523F19F074D0A64087DBCD3');
      expect(parsed1['name'], 'Ubuntu');

      final parsed2 = parseMagnetUrl(validBase32);
      expect(parsed2['infoHash'], isNotNull);
      expect(parsed2['infoHash']!.length, 40); // Converted 32-char Base32 to 40-char Hex
    });

    test('isValidTransmissionUrl accepts valid magnet URLs', () {
      expect(isValidTransmissionUrl(validHex40), isTrue);
      expect(isValidTransmissionUrl(invalidNoXt), isFalse);
    });

    test('parseMagnetUrl with no name returns empty map for name', () {
      final parsed = parseMagnetUrl('magnet:?xt=urn:btih:5dee65101db75097c523f19f074d0a64087dbcd3');
      expect(parsed['infoHash'], isNotNull);
      expect(parsed['name'], isNull);
    });

    test('parseMagnetUrl handles empty input', () {
      final parsed = parseMagnetUrl('');
      expect(parsed, isEmpty);
    });

    test('parseMagnetUrl handles non-magnet string', () {
      final parsed = parseMagnetUrl('https://example.com');
      expect(parsed, isEmpty);
    });

    test('isMagnetUrl rejects non-magnet strings', () {
      expect(isMagnetUrl(''), isFalse);
      expect(isMagnetUrl('not a magnet'), isFalse);
      expect(isMagnetUrl('magnet:?dn=test'), isFalse); // No xt parameter
    });
  });

  group('Punycode & Content Disposition Tests', () {
    test('convertIdnToPunycode handles non-Latin domains safely', () {
      expect(convertIdnToPunycode('https://example.com'), 'https://example.com');
      final puny = convertIdnToPunycode('https://موقع.الجزيرة.net/test');
      expect(puny, contains('xn--'));
    });

    test('convertIdnToPunycode preserves ASCII domains', () {
      expect(
        convertIdnToPunycode('https://www.google.com/search?q=test'),
        'https://www.google.com/search?q=test',
      );
    });

    test('convertIdnToPunycode handles malformed URLs gracefully', () {
      expect(convertIdnToPunycode(''), '');
      expect(convertIdnToPunycode('not a url'), 'not a url');
    });
  });

  group('fileNameFromUrl edge cases', () {
    test('handles URL with no path segments', () {
      final name = fileNameFromUrl('https://example.com');
      expect(name, startsWith('download_'));
    });

    test('handles URL with encoded characters', () {
      final name = fileNameFromUrl('https://example.com/file%20name.txt');
      expect(name, 'file name.txt');
    });

    test('handles URL with query parameters', () {
      final name = fileNameFromUrl('https://example.com/path/doc.pdf?v=1&token=abc');
      expect(name, 'doc.pdf');
    });
  });

  group('isTorrentUrl edge cases', () {
    test('detects magnet links', () {
      expect(isTorrentUrl('magnet:?xt=urn:btih:5dee65101db75097c523f19f074d0a64087dbcd3'), isTrue);
    });

    test('detects .torrent file URLs', () {
      expect(isTorrentUrl('https://example.com/file.torrent'), isTrue);
      expect(isTorrentUrl('https://example.com/file.torrent?download=1'), isTrue);
    });

    test('detects file:// torrent paths', () {
      expect(isTorrentUrl('file:///tmp/test.torrent'), isTrue);
    });

    test('rejects non-torrent URLs', () {
      expect(isTorrentUrl('https://example.com/video.mp4'), isFalse);
      expect(isTorrentUrl('https://example.com/file.zip'), isFalse);
    });

    test('detects .torrent via fileName parameter', () {
      expect(
        isTorrentUrl('https://example.com/download', fileName: 'movie.torrent'),
        isTrue,
      );
    });
  });

  group('fileNameFromContentDisposition edge cases', () {
    test('returns null when no content-disposition header', () {
      final headers = Headers();
      expect(fileNameFromContentDisposition(headers), isNull);
    });
  });

  group('extractUrlFromText edge cases', () {
    test('extracts URL from surrounding text', () {
      final url = extractUrlFromText('Check out https://example.com for more info');
      expect(url, 'https://example.com');
    });

    test('extracts magnet link from text', () {
      final url = extractUrlFromText('Download: magnet:?xt=urn:btih:5dee65101db75097c523f19f074d0a64087dbcd3&dn=Test');
      expect(url, contains('magnet:'));
    });

    test('returns null for text with no URLs', () {
      expect(extractUrlFromText('Just some plain text'), isNull);
    });

    test('strips trailing punctuation from extracted URL', () {
      final url = extractUrlFromText('Visit https://example.com, for more.');
      expect(url, 'https://example.com');
    });
  });

  group('safeFileName edge cases', () {
    test('sanitizes special characters', () {
      final safe = safeFileName('file<>:"/\\|?*.txt');
      expect(safe, isNot(contains('<')));
      expect(safe, isNot(contains('>')));
      expect(safe, isNot(contains(':')));
      expect(safe, isNot(contains('"')));
    });

    test('truncates long filenames', () {
      final longName = 'a' * 200 + '.mp4';
      final safe = safeFileName(longName);
      expect(safe.length, lessThanOrEqualTo(125));
      expect(safe, endsWith('.mp4'));
    });

    test('handles empty input', () {
      expect(safeFileName(''), 'download.bin');
    });

    test('handles Windows reserved names', () {
      expect(safeFileName('CON.txt'), '_CON.txt');
      expect(safeFileName('NUL.mp4'), '_NUL.mp4');
    });
  });
}
