import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/ffmpeg_mux_service.dart';
import 'package:dmx/core/utils/semaphore.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FFmpegMuxService Unit Tests', () {
    test('Semaphore acquire and release work correctly under concurrency',
        () async {
      final sem = Semaphore(2);
      expect(sem.maxCount, equals(2));

      await sem.acquire();
      await sem.acquire();

      bool thirdAcquired = false;
      final future = sem.acquire().then((_) => thirdAcquired = true);

      expect(thirdAcquired, isFalse);
      sem.release();
      await future;
      expect(thirdAcquired, isTrue);
      sem.release();
      sem.release();
    });

    test('canResumeMerge returns false when video input is missing', () async {
      final canResume = await FFmpegMuxService.canResumeMerge(
        'non_existent_video.mp4',
        'non_existent_audio.aac',
      );
      expect(canResume, isFalse);
    });

    test('canResumeMerge returns true when video input exists', () async {
      final tempDir = Directory.systemTemp.createTempSync('ffmpeg_test_');
      final videoFile = File('${tempDir.path}/video.dmxpart')..createSync();
      final audioFile = File('${tempDir.path}/video.audio')..createSync();

      final canResume = await FFmpegMuxService.canResumeMerge(
        videoFile.path,
        audioFile.path,
      );
      expect(canResume, isTrue);

      tempDir.deleteSync(recursive: true);
    });

    test('mergeVideoAudio delegates to mockMergeHandler when configured',
        () async {
      int calls = 0;
      FFmpegMuxService.mockMergeHandler = (video, audio, output) async {
        calls++;
        return true;
      };

      final result = await FFmpegMuxService.mergeVideoAudio(
        'video.mp4',
        'audio.aac',
        'output.mp4',
      );

      expect(result, isTrue);
      expect(calls, 1);

      FFmpegMuxService.mockMergeHandler = null;
    });
  });
}
