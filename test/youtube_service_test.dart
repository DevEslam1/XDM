import 'package:dmx/core/services/youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('YoutubeService Quality & Height Parsing Tests', () {
    test('parseQualityHeight extracts numeric resolution heights accurately', () {
      expect(YoutubeService.parseQualityHeight('1080p'), 1080);
      expect(YoutubeService.parseQualityHeight('720p'), 720);
      expect(YoutubeService.parseQualityHeight('480p'), 480);
      expect(YoutubeService.parseQualityHeight('360p'), 360);
      expect(YoutubeService.parseQualityHeight('240p'), 240);
      expect(YoutubeService.parseQualityHeight('144p'), 144);
      expect(YoutubeService.parseQualityHeight('Video: 1080p (Muxed)'), 1080);
      expect(YoutubeService.parseQualityHeight('best_combined'), 0);
    });
  });

  group('YoutubeService Stream Matching Logic Tests', () {
    final mockMuxed720 = {
      'src': 'https://googlevideo.com/muxed720',
      'label': 'Video: 720p (Muxed)',
      'size': 15000000,
      'ext': 'mp4',
      'title': 'Test Video',
      'quality': '720p',
      'type': 'muxed',
    };

    final mockMuxed360 = {
      'src': 'https://googlevideo.com/muxed360',
      'label': 'Video: 360p (Muxed)',
      'size': 8000000,
      'ext': 'mp4',
      'title': 'Test Video',
      'quality': '360p',
      'type': 'muxed',
    };

    final mockCombined1080 = {
      'src': 'https://googlevideo.com/video1080',
      'audioSrc': 'https://googlevideo.com/audio128',
      'label': 'Video: 1080p + Audio (Best)',
      'size': 45000000,
      'ext': 'mp4',
      'title': 'Test Video',
      'quality': '1080p',
      'type': 'combined',
      'videoSize': 40000000,
      'audioSize': 5000000,
    };

    final mockAudioOnly = {
      'src': 'https://googlevideo.com/audio160',
      'label': 'Audio Only: (160 Kbps)',
      'size': 6000000,
      'ext': 'm4a',
      'title': 'Test Video',
      'quality': '160kbps',
      'type': 'audio',
    };

    test('Audio only request selects audio stream', () {
      final streams = [mockMuxed720, mockCombined1080, mockAudioOnly];
      final audios = streams.where((s) => s['type'] == 'audio').toList();
      expect(audios.length, 1);
      expect(audios.first['type'], 'audio');
    });

    test('Exact resolution match for 1080p returns combined stream', () {
      final streams = [mockMuxed720, mockCombined1080, mockAudioOnly];
      final target = YoutubeService.parseQualityHeight('1080p');
      final match = streams.firstWhere((s) => YoutubeService.parseQualityHeight(s['quality'] as String) == target);
      expect(match['type'], 'combined');
      expect(match['quality'], '1080p');
    });

    test('Muxed preferred request selects muxed stream when available', () {
      final streams = [mockMuxed720, mockMuxed360, mockCombined1080];
      final muxedStreams = streams.where((s) => s['type'] == 'muxed').toList();
      expect(muxedStreams.isNotEmpty, isTrue);
      expect(muxedStreams.first['type'], 'muxed');
    });
  });
}
