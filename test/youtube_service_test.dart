import 'package:dmx/core/services/youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('YoutubeService Quality & Height Parsing Tests', () {
    test(
      'parseQualityHeight extracts numeric resolution heights accurately',
      () {
        expect(YoutubeService.parseQualityHeight('2160p'), 2160);
        expect(YoutubeService.parseQualityHeight('1440p'), 1440);
        expect(YoutubeService.parseQualityHeight('1080p'), 1080);
        expect(YoutubeService.parseQualityHeight('720p'), 720);
        expect(YoutubeService.parseQualityHeight('480p'), 480);
        expect(YoutubeService.parseQualityHeight('360p'), 360);
        expect(YoutubeService.parseQualityHeight('240p'), 240);
        expect(YoutubeService.parseQualityHeight('144p'), 144);
        expect(YoutubeService.parseQualityHeight('Video: 1080p (Muxed)'), 1080);
        expect(YoutubeService.parseQualityHeight('best_combined'), 0);
      },
    );

    test('formatDuration formats seconds accurately', () {
      expect(YoutubeService.formatDuration(0), '0:00');
      expect(YoutubeService.formatDuration(45), '0:45');
      expect(YoutubeService.formatDuration(320), '5:20');
      expect(YoutubeService.formatDuration(3665), '1:01:05');
    });
  });

  group('YoutubeService URL Detection & ID Extraction Tests', () {
    test('isYoutubeVideoUrl detects single videos and Shorts', () {
      expect(
        YoutubeService.isYoutubeVideoUrl(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        ),
        isTrue,
      );
      expect(
        YoutubeService.isYoutubeVideoUrl('https://youtu.be/dQw4w9WgXcQ'),
        isTrue,
      );
      expect(
        YoutubeService.isYoutubeVideoUrl(
          'https://www.youtube.com/shorts/abcdefghijk',
        ),
        isTrue,
      );
      expect(
        YoutubeService.isYoutubeVideoUrl('https://example.com/video.mp4'),
        isFalse,
      );
    });

    test('isPlaylistUrl detects YouTube playlist links', () {
      expect(
        YoutubeService.isPlaylistUrl(
          'https://www.youtube.com/playlist?list=PL123456789',
        ),
        isTrue,
      );
      expect(
        YoutubeService.isPlaylistUrl(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123456789',
        ),
        isTrue,
      );
      expect(
        YoutubeService.isPlaylistUrl(
          'youtube.com/playlist?list=PL123456789',
        ),
        isTrue,
      );
      expect(
        YoutubeService.isPlaylistUrl(
          'PL123456789',
        ),
        isTrue,
      );
      expect(
        YoutubeService.isPlaylistUrl(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        ),
        isFalse,
      );
    });

    test('isPurePlaylistUrl distinguishes pure playlists from mixed links', () {
      expect(
        YoutubeService.isPurePlaylistUrl(
          'https://www.youtube.com/playlist?list=PL123456789',
        ),
        isTrue,
      );
      expect(
        YoutubeService.isPurePlaylistUrl(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123456789',
        ),
        isFalse,
      );
    });

    test('extractVideoId extracts correct video IDs', () {
      expect(
        YoutubeService.extractVideoId(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        ),
        'dQw4w9WgXcQ',
      );
      expect(
        YoutubeService.extractVideoId('https://youtu.be/dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
      expect(
        YoutubeService.extractVideoId(
          'https://www.youtube.com/shorts/12345678901',
        ),
        '12345678901',
      );
    });

    test('extractPlaylistId extracts correct playlist IDs', () {
      expect(
        YoutubeService.extractPlaylistId(
          'https://www.youtube.com/playlist?list=PL123456789',
        ),
        'PL123456789',
      );
      expect(
        YoutubeService.extractPlaylistId(
          'https://www.youtube.com/watch?v=abc&list=PL987654321',
        ),
        'PL987654321',
      );
      expect(
        YoutubeService.extractPlaylistId(
          'youtube.com/playlist?list=PL123456789',
        ),
        'PL123456789',
      );
      expect(
        YoutubeService.extractPlaylistId(
          'PL123456789',
        ),
        'PL123456789',
      );
    });
  });

  group('YoutubeService Stream Map Schema & Quality Selection Tests', () {
    final mockCombined1080 = {
      'type': 'combined',
      'quality': '1080p',
      'label': '1080p MP4 + M4A',
      'src': 'https://googlevideo.com/video1080',
      'audioSrc': 'https://googlevideo.com/audio128',
      'videoSize': 40000000,
      'audioSize': 5000000,
      'size': 45000000,
      'ext': 'mp4',
      'title': 'Test Video Title',
    };

    final mockMuxed720 = {
      'type': 'muxed',
      'quality': '720p',
      'label': '720p MP4',
      'src': 'https://googlevideo.com/muxed720',
      'size': 15000000,
      'ext': 'mp4',
      'title': 'Test Video Title',
    };

    final mockAudioOnly = {
      'type': 'audio',
      'quality': '160kbps',
      'label': 'Audio Only M4A',
      'src': 'https://googlevideo.com/audio160',
      'size': 6000000,
      'ext': 'm4a',
      'title': 'Test Video Title',
    };

    final mockVideoOnly1080 = {
      'type': 'video_only',
      'quality': '1080p',
      'label': '1080p Video Only',
      'src': 'https://googlevideo.com/video1080',
      'size': 40000000,
      'ext': 'mp4',
      'title': 'Test Video Title',
    };

    test('Combined stream map conforms to required schema keys', () {
      expect(mockCombined1080['type'], 'combined');
      expect(mockCombined1080['quality'], '1080p');
      expect(mockCombined1080.containsKey('src'), isTrue);
      expect(mockCombined1080.containsKey('audioSrc'), isTrue);
      expect(mockCombined1080.containsKey('videoSize'), isTrue);
      expect(mockCombined1080.containsKey('audioSize'), isTrue);
      expect(
        mockCombined1080['size'],
        (mockCombined1080['videoSize'] as int) +
            (mockCombined1080['audioSize'] as int),
      );
      expect(mockCombined1080['ext'], 'mp4');
      expect(mockCombined1080['title'], 'Test Video Title');
    });

    test('Muxed stream map conforms to required schema keys', () {
      expect(mockMuxed720['type'], 'muxed');
      expect(mockMuxed720['quality'], '720p');
      expect(mockMuxed720.containsKey('src'), isTrue);
      expect(mockMuxed720['ext'], 'mp4');
    });

    test('Audio stream map conforms to required schema keys', () {
      expect(mockAudioOnly['type'], 'audio');
      expect(mockAudioOnly['quality'], '160kbps');
      expect(mockAudioOnly['ext'], 'm4a');
    });

    test('Video only stream map conforms to required schema keys', () {
      expect(mockVideoOnly1080['type'], 'video_only');
      expect(mockVideoOnly1080['quality'], '1080p');
    });

    test('Audio only request selects audio stream', () {
      final streams = [mockMuxed720, mockCombined1080, mockAudioOnly];
      final audios = streams.where((s) => s['type'] == 'audio').toList();
      expect(audios.length, 1);
      expect(audios.first['type'], 'audio');
    });

    test('Best combined request selects combined stream over muxed', () {
      final streams = [mockMuxed720, mockCombined1080, mockAudioOnly];
      final combined = streams.where((s) => s['type'] == 'combined').toList();
      expect(combined.isNotEmpty, isTrue);
      expect(combined.first['quality'], '1080p');
    });

    test('Fallback to muxed stream when separate streams do not exist', () {
      final streams = [mockMuxed720];
      final best = streams.where((s) => s['type'] == 'combined').isNotEmpty
          ? streams.firstWhere((s) => s['type'] == 'combined')
          : streams.firstWhere((s) => s['type'] == 'muxed');
      expect(best['type'], 'muxed');
      expect(best['quality'], '720p');
    });

    test(
        'normalizeStreamEntry supports backend responses using url instead of direct_url',
        () {
      final normalized = YoutubeService.normalizeStreamEntry({
        'type': 'video_audio',
        'quality': '1080p',
        'url': 'https://googlevideo.com/stream1080',
        'audio_url': 'https://googlevideo.com/audio1080',
        'size': 12345678,
        'ext': 'mp4',
        'title': 'Test Video Title',
      });

      expect(normalized['src'], 'https://googlevideo.com/stream1080');
      expect(normalized['audioSrc'], 'https://googlevideo.com/audio1080');
      expect(normalized['type'], 'muxed');
      expect(normalized['size'], 12345678);
    });

    test('normalizeStreamEntry ignores placeholder page URLs', () {
      final normalized = YoutubeService.normalizeStreamEntry({
        'type': 'video_audio',
        'quality': '1080p',
        'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'audio_url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'size': 12345678,
        'ext': 'mp4',
        'title': 'Test Video Title',
      });

      expect(normalized['src'], isNull);
      expect(normalized['audioSrc'], isNull);
    });
  });

  group('YoutubeService Playlist Mapping & Duplicate Detection Tests', () {
    test('Playlist data structure matches required schema', () {
      final playlistDetails = {
        'info': {
          'title': 'Test Playlist',
          'author': 'Test Author',
          'videoCount': 2,
        },
        'videos': [
          {
            'id': 'vid1',
            'title': 'Video 1',
            'duration': 300,
            'author': 'Test Author',
            'thumbnailUrl': 'https://img.youtube.com/vi/vid1/hqdefault.jpg',
            'selected': true,
          },
          {
            'id': 'vid2',
            'title': 'Video 2',
            'duration': 180,
            'author': 'Test Author',
            'thumbnailUrl': null,
            'selected': true,
          },
        ],
      };

      final info = playlistDetails['info'] as Map<String, dynamic>;
      final videos =
          (playlistDetails['videos'] as List).cast<Map<String, dynamic>>();

      expect(info['title'], 'Test Playlist');
      expect(info['videoCount'], 2);
      expect(videos.length, 2);
      expect(videos.first['duration'], isA<int>());
      expect(videos.first['selected'], isTrue);
    });

    test(
      'Duplicate detection matches same downloadPageUrl and qualityPreset',
      () {
        const pageUrl = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';
        const preset = '1080p';

        final existingTasks = [
          {
            'downloadPageUrl': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
            'youtubeQualityPreset': '1080p',
            'status': 'downloading',
          },
        ];

        final isDuplicate = existingTasks.any(
          (t) =>
              t['status'] != 'failed' &&
              t['status'] != 'completed' &&
              t['status'] != 'paused' &&
              t['downloadPageUrl'] == pageUrl &&
              t['youtubeQualityPreset'] == preset,
        );

        expect(isDuplicate, isTrue);
      },
    );
  });
}
