import 'package:dmx/features/browser/services/browser_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    setupTestPluginMocks();
    SharedPreferences.setMockInitialValues({});
  });

  group('BrowserDetector Tests', () {
    test('Detects video files by extension', () {
      final res =
          BrowserDetector.detect('https://example.com/media/sample.mp4');
      expect(res, isNotNull);
      expect(res!.kind, equals(DetectedMediaKind.video));
    });

    test('Detects audio files by extension', () {
      final res = BrowserDetector.detect('https://example.com/audio/song.mp3');
      expect(res, isNotNull);
      expect(res!.kind, equals(DetectedMediaKind.audio));
    });

    test('Detects archive files by extension', () {
      final res =
          BrowserDetector.detect('https://example.com/downloads/archive.zip');
      expect(res, isNotNull);
      expect(res!.kind, equals(DetectedMediaKind.archive));
    });

    test('Detects streaming manifests separately from video files', () {
      final m3u8 =
          BrowserDetector.detect('https://example.com/live/playlist.m3u8');
      expect(m3u8, isNotNull);
      expect(m3u8!.kind, equals(DetectedMediaKind.stream));

      final mp4 = BrowserDetector.detect('https://example.com/video.mp4');
      expect(mp4, isNotNull);
      expect(mp4!.kind, equals(DetectedMediaKind.video));
    });

    test('Detects magnet URLs', () {
      final res =
          BrowserDetector.detect('magnet:?xt=urn:btih:1234567890abcdef');
      expect(res, isNotNull);
      expect(res!.kind, equals(DetectedMediaKind.magnet));
    });

    test('Detects content type headers correctly', () {
      expect(BrowserDetector.detectFromContentType('video/mp4'),
          equals(DetectedMediaKind.video));
      expect(BrowserDetector.detectFromContentType('audio/mpeg'),
          equals(DetectedMediaKind.audio));
      expect(BrowserDetector.detectFromContentType('application/pdf'),
          equals(DetectedMediaKind.document));
      expect(BrowserDetector.detectFromContentType('text/html'), isNull);
    });

    test('Detects CDN media URLs', () {
      expect(
          BrowserDetector.isCdnMediaUrl(
              'https://rr1---sn-abc.googlevideo.com/videoplayback'),
          isTrue);
      expect(BrowserDetector.isCdnMediaUrl('https://example.com/index.html'),
          isFalse);
    });

    test('isPathBased reflects detection confidence', () {
      const high = DetectedMedia(
          kind: DetectedMediaKind.video, url: 'https://a.com/v.mp4');
      const low = DetectedMedia(
        kind: DetectedMediaKind.video,
        url: 'https://a.com/v.mp4',
        confidence: DetectionConfidence.low,
      );
      expect(high.isPathBased, isTrue);
      expect(low.isPathBased, isFalse);
    });

    test(
        'Detects executables, torrents and documents through the extension map',
        () {
      expect(BrowserDetector.detect('https://example.com/app.apk')!.kind,
          DetectedMediaKind.executable);
      expect(BrowserDetector.detect('https://example.com/setup.exe')!.kind,
          DetectedMediaKind.executable);

      final torrent =
          BrowserDetector.detect('https://unknown-host.example/file.torrent');
      expect(torrent, isNotNull);
      expect(torrent!.kind, DetectedMediaKind.torrent);
      expect(torrent.suggestedFileName, 'file.torrent');
      expect(torrent.isPathBased, isTrue);

      final csv =
          BrowserDetector.detect('https://unknown-host.example/data.csv');
      expect(csv, isNotNull);
      expect(csv!.kind, DetectedMediaKind.document);
    });

    test('Detects low-confidence extension matches in query strings', () {
      final detected = BrowserDetector.detect(
          'https://unknown-host.example/page?file=.torrent');
      expect(detected, isNotNull);
      expect(detected!.kind, DetectedMediaKind.torrent);
      expect(detected.confidence, DetectionConfidence.low);
      expect(detected.isPathBased, isFalse);

      final noSegments =
          BrowserDetector.detect('https://unknown-host.example?file=.torrent');
      expect(noSegments, isNotNull);
      expect(noSegments!.suggestedFileName, 'download.torrent');
    });

    test('Download keyword URLs are unknown downloads', () {
      final detected =
          BrowserDetector.detect('https://example.com/download?id=456');
      expect(detected, isNotNull);
      expect(detected!.kind, DetectedMediaKind.unknown);
    });

    test('Web assets and plain pages return null', () {
      expect(BrowserDetector.detect('https://example.com/page.html'), isNull);
      expect(BrowserDetector.detect('https://example.com/app.js'), isNull);
      expect(BrowserDetector.detect('https://example.com/site.css'), isNull);
      expect(BrowserDetector.detect('https://example.com/page.php'), isNull);
      expect(BrowserDetector.detect('https://example.com'), isNull);
      expect(
          BrowserDetector.detect('https://unknown-host.example/dir/'), isNull);
    });

    test('detectFromContentType covers every mapping and unknown', () {
      expect(BrowserDetector.detectFromContentType('image/png'),
          DetectedMediaKind.image);
      expect(BrowserDetector.detectFromContentType('application/zip'),
          DetectedMediaKind.archive);
      expect(BrowserDetector.detectFromContentType('application/x-rar'),
          DetectedMediaKind.archive);
      expect(BrowserDetector.detectFromContentType('application/x-7z'),
          DetectedMediaKind.archive);
      expect(BrowserDetector.detectFromContentType('application/x-bittorrent'),
          DetectedMediaKind.torrent);
      expect(BrowserDetector.detectFromContentType('application/octet-stream'),
          DetectedMediaKind.unknown);
      expect(BrowserDetector.detectFromContentType('unknown/type'), isNull);
    });

    test('isAutoDownloadable classifies media kinds', () {
      expect(
          BrowserDetector.isAutoDownloadable('magnet:?xt=urn:btih:x'), isTrue);
      expect(
          BrowserDetector.isAutoDownloadable('https://a.com/pic.png'), isFalse);
      expect(BrowserDetector.isAutoDownloadable('https://a.com/live.m3u8'),
          isFalse);
      expect(BrowserDetector.isAutoDownloadable('https://a.com/download?id=1'),
          isFalse);
      expect(
          BrowserDetector.isAutoDownloadable('https://a.com/doc.pdf'), isTrue);
      expect(
          BrowserDetector.isAutoDownloadable('https://a.com/app.apk'), isTrue);
      expect(BrowserDetector.isAutoDownloadable('https://a.com/x.torrent'),
          isTrue);
    });

    test('isCdnMediaUrl matches all configured CDN patterns', () {
      for (final host in [
        'fbcdn.net',
        'cdninstagram.com',
        'twimg.com',
        'akamaized.net',
      ]) {
        expect(BrowserDetector.isCdnMediaUrl('https://$host/asset'), isTrue);
      }
    });
  });
}
