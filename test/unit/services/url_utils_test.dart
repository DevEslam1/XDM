import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/utils/url_utils.dart';
import 'package:dmx/core/utils/file_utils.dart';

void main() {
  group('URL Utils', () {
    group('isHttpUrl', () {
      test('valid http URLs', () {
        expect(isHttpUrl('http://example.com'), true);
        expect(isHttpUrl('https://example.com'), true);
        expect(isHttpUrl('https://example.com/path?q=1'), true);
      });

      test('invalid URLs', () {
        expect(isHttpUrl('ftp://example.com'), false);
        expect(isHttpUrl('javascript:alert(1)'), false);
        expect(isHttpUrl('data:text/html,<script>'), false);
        expect(isHttpUrl(''), false);
        expect(isHttpUrl('not a url'), false);
      });
    });

    group('isMagnetUrl', () {
      test('valid magnet URLs', () {
        expect(
          isMagnetUrl(
            'magnet:?xt=urn:btih:'
            '08ada5a7a6183aae1e09d831df6748d566095a10',
          ),
          true,
        );
      });

      test('invalid magnet URLs', () {
        expect(isMagnetUrl('http://example.com'), false);
        expect(isMagnetUrl('magnet:'), false);
      });
    });

    group('safeFileName', () {
    test('removes path separators', () {
      expect(safeFileName('foo/bar.txt'), 'foo_bar.txt');
      expect(safeFileName('foo<bar.txt'), 'foo_bar.txt');
      expect(safeFileName('foo>bar.txt'), 'foo_bar.txt');
      expect(safeFileName('foo:bar.txt'), 'foo_bar.txt');
    });

      test('trims whitespace', () {
        expect(safeFileName('  file.txt  '), 'file.txt');
      });

      test('preserves valid names', () {
        expect(safeFileName('My Document.pdf'), 'My Document.pdf');
        expect(safeFileName('image_001.jpg'), 'image_001.jpg');
      });
    });

    group('isValidTransmissionUrl', () {
      test('valid transmission URLs', () {
        expect(isValidTransmissionUrl('https://example.com/file.zip'), true);
        expect(isValidTransmissionUrl('magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10'), true);
        expect(isValidTransmissionUrl('http://example.com/file.torrent'), true);
      });

      test('invalid transmission URLs', () {
        expect(isValidTransmissionUrl(''), false);
        expect(isValidTransmissionUrl('javascript:void(0)'), false);
      });
    });

    group('isTorrentFileUrl', () {
      test('recognizes .torrent URLs', () {
        expect(isTorrentFileUrl('http://example.com/file.torrent'), true);
        expect(isTorrentFileUrl('https://example.com/a.torrent?auth=1'), true);
      });

      test('rejects non-torrent URLs', () {
        expect(isTorrentFileUrl('http://example.com/file.zip'), false);
        expect(isTorrentFileUrl(''), false);
      });
    });

    group('extractUrlFromText', () {
      test('extracts URL from text', () {
        expect(
          extractUrlFromText('Check this https://example.com/file.zip'),
          'https://example.com/file.zip',
        );
      });

      test('returns null for plain text', () {
        expect(extractUrlFromText('hello world'), null);
      });

      test('extracts magnet from text', () {
        expect(
          extractUrlFromText('magnet:?xt=urn:btih:abc123'),
          'magnet:?xt=urn:btih:abc123',
        );
      });
    });
  });
}
