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
      final res = BrowserDetector.detect('https://example.com/media/sample.mp4');
      expect(res, isNotNull);
      expect(res!.kind, equals(DetectedMediaKind.video));
    });

    test('Detects audio files by extension', () {
      final res = BrowserDetector.detect('https://example.com/audio/song.mp3');
      expect(res, isNotNull);
      expect(res!.kind, equals(DetectedMediaKind.audio));
    });

    test('Detects archive files by extension', () {
      final res = BrowserDetector.detect('https://example.com/downloads/archive.zip');
      expect(res, isNotNull);
      expect(res!.kind, equals(DetectedMediaKind.archive));
    });

    test('Detects streaming manifests separately from video files', () {
      final m3u8 = BrowserDetector.detect('https://example.com/live/playlist.m3u8');
      expect(m3u8, isNotNull);
      expect(m3u8!.kind, equals(DetectedMediaKind.stream));

      final mp4 = BrowserDetector.detect('https://example.com/video.mp4');
      expect(mp4, isNotNull);
      expect(mp4!.kind, equals(DetectedMediaKind.video));
    });

    test('Detects magnet URLs', () {
      final res = BrowserDetector.detect('magnet:?xt=urn:btih:1234567890abcdef');
      expect(res, isNotNull);
      expect(res!.kind, equals(DetectedMediaKind.magnet));
    });

    test('Detects content type headers correctly', () {
      expect(BrowserDetector.detectFromContentType('video/mp4'), equals(DetectedMediaKind.video));
      expect(BrowserDetector.detectFromContentType('audio/mpeg'), equals(DetectedMediaKind.audio));
      expect(BrowserDetector.detectFromContentType('application/pdf'), equals(DetectedMediaKind.document));
      expect(BrowserDetector.detectFromContentType('text/html'), isNull);
    });

    test('Detects CDN media URLs', () {
      expect(BrowserDetector.isCdnMediaUrl('https://rr1---sn-abc.googlevideo.com/videoplayback'), isTrue);
      expect(BrowserDetector.isCdnMediaUrl('https://example.com/index.html'), isFalse);
    });
  });
}
