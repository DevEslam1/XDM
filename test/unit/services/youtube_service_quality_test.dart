import 'package:dmx/core/services/youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('YouTube Stream Quality Downgrade Evaluation (Y-04)', () {
    test('1080p -> 720p is 1 step: does NOT set qualityChanged flag', () {
      final result = YoutubeService.evaluateQualityDowngrade(
        stream: {'url': 'https://stream.url'},
        originalQuality: '1080p',
        newQuality: '720p',
      );

      expect(result.qualityChanged, isFalse);
      expect(result.originalQuality, equals('1080p'));
      expect(result.newQuality, equals('720p'));
    });

    test('1080p -> 480p is 2 steps: sets qualityChanged flag', () {
      final result = YoutubeService.evaluateQualityDowngrade(
        stream: {'url': 'https://stream.url'},
        originalQuality: '1080p',
        newQuality: '480p',
      );

      expect(result.qualityChanged, isTrue);
      expect(result.originalQuality, equals('1080p'));
      expect(result.newQuality, equals('480p'));
    });

    test('same quality: does NOT set qualityChanged flag', () {
      final result = YoutubeService.evaluateQualityDowngrade(
        stream: {'url': 'https://stream.url'},
        originalQuality: '1080p',
        newQuality: '1080p',
      );

      expect(result.qualityChanged, isFalse);
    });
  });
}
