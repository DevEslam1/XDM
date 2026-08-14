import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/ffmpeg_mux_service.dart';
import 'package:dmx/core/services/youtube_service.dart';

void main() {
  group('YouTube & FFmpeg Muxing Tests (Y-04 / Y-05)', () {
    test('canResumeMerge returns false if input files do not exist (Y-04)',
        () async {
      final canResume = await FFmpegMuxService.canResumeMerge(
        '/nonexistent/video.mp4',
        '/nonexistent/audio.mp4',
      );
      expect(canResume, isFalse);
    });

    test('isClientCoolingDown reports accurate status (Y-04)', () {
      YoutubeService.resetClientCooldowns();
      expect(YoutubeService.isClientCoolingDown('android'), isFalse);

      YoutubeService.markClientCoolingDown(
          'android', const Duration(seconds: 10));
      expect(YoutubeService.isClientCoolingDown('android'), isTrue);

      YoutubeService.resetClientCooldowns();
      expect(YoutubeService.isClientCoolingDown('android'), isFalse);
    });
  });
}
