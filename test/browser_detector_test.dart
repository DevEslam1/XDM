import 'package:dmx/features/browser/services/browser_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BrowserDetector Tests', () {
    test('Web pages and code assets are ignored', () {
      expect(BrowserDetector.detect('https://example.com/index.html'), isNull);
      expect(BrowserDetector.detect('https://example.com/script.js'), isNull);
      expect(BrowserDetector.detect('https://example.com/style.css'), isNull);
      expect(BrowserDetector.detect('https://example.com/about.php'), isNull);
    });

    test('Clean download pages without queries are ignored', () {
      expect(BrowserDetector.detect('https://example.com/download'), isNull);
      expect(BrowserDetector.detect('https://example.com/downloads'), isNull);
      expect(BrowserDetector.detect('https://example.com/download/'), isNull);
      expect(BrowserDetector.detect('https://example.com/downloads/'), isNull);
    });

    test('Download endpoints with queries are detected as unknown downloads', () {
      final detected = BrowserDetector.detect('https://example.com/download?id=456');
      expect(detected, isNotNull);
      expect(detected!.kind, DetectedMediaKind.unknown);
      expect(BrowserDetector.isAutoDownloadable('https://example.com/download?id=456'), isTrue);
    });

    test('Images are detected but not auto-downloaded', () {
      final detected = BrowserDetector.detect('https://example.com/pic.png');
      expect(detected, isNotNull);
      expect(detected!.kind, DetectedMediaKind.image);
      expect(BrowserDetector.isAutoDownloadable('https://example.com/pic.png'), isFalse);
    });

    test('Downloadable assets are detected and auto-downloaded', () {
      final mp4 = BrowserDetector.detect('https://example.com/video.mp4');
      expect(mp4, isNotNull);
      expect(mp4!.kind, DetectedMediaKind.video);
      expect(BrowserDetector.isAutoDownloadable('https://example.com/video.mp4'), isTrue);

      final zip = BrowserDetector.detect('https://example.com/archive.zip');
      expect(zip, isNotNull);
      expect(zip!.kind, DetectedMediaKind.archive);
      expect(BrowserDetector.isAutoDownloadable('https://example.com/archive.zip'), isTrue);
    });
  });
}
