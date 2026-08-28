import 'package:dmx/features/browser/services/media_sniffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MediaSniffer Unit Tests [Browser 10/10]', () {
    test('isYoutubeHost correctly identifies YouTube URLs', () {
      expect(MediaSniffer.isYoutubeHost('https://www.youtube.com/watch?v=123'),
          isTrue);
      expect(MediaSniffer.isYoutubeHost('https://m.youtube.com/watch?v=123'),
          isTrue);
      expect(MediaSniffer.isYoutubeHost('https://youtu.be/123'), isTrue);
      expect(
          MediaSniffer.isYoutubeHost('https://example.com/video.mp4'), isFalse);
      expect(MediaSniffer.isYoutubeHost('invalid-uri'), isFalse);
    });

    test('totalDetectedCount and clearAll correctly update detection state',
        () {
      final sniffer = MediaSniffer(
        isActive: () => true,
        containsTab: (_) => true,
        isSnifferEnabled: () => true,
      );

      sniffer.detectedDownloadUrls['tab_1'] = 'https://example.com/video.mp4';
      sniffer.detectedMediaSources['tab_1'] = [
        {'url': 'https://example.com/audio.mp3', 'type': 'audio/mp3'},
        {'url': 'https://example.com/video.webm', 'type': 'video/webm'},
      ];
      sniffer.detectedPlaylistUrls['tab_2'] = 10;

      expect(sniffer.totalDetectedCount, equals(1 + 2 + 1));

      sniffer.clearAll();
      expect(sniffer.totalDetectedCount, equals(0));
      expect(sniffer.detectedDownloadUrls.isEmpty, isTrue);
      expect(sniffer.detectedMediaSources.isEmpty, isTrue);
      expect(sniffer.detectedPlaylistUrls.isEmpty, isTrue);

      sniffer.dispose();
    });

    test('cleanupTab removes all state associated with closed tab', () {
      final sniffer = MediaSniffer(
        isActive: () => true,
        containsTab: (_) => true,
        isSnifferEnabled: () => true,
      );

      sniffer.detectedDownloadUrls['tab_1'] = 'https://example.com/v1.mp4';
      sniffer.detectedDownloadUrls['tab_2'] = 'https://example.com/v2.mp4';
      sniffer.detectedMediaSources['tab_1'] = [
        {'url': 'https://example.com/s1.mp4'}
      ];

      sniffer.cleanupTab('tab_1');

      expect(sniffer.detectedDownloadUrls.containsKey('tab_1'), isFalse);
      expect(sniffer.detectedMediaSources.containsKey('tab_1'), isFalse);
      expect(sniffer.detectedDownloadUrls.containsKey('tab_2'), isTrue);

      sniffer.dispose();
    });
  });
}
