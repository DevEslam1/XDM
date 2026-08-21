import 'dart:io';
import 'package:dmx/core/services/ffmpeg_mux_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('merge_retention_test_');
  });

  tearDown(() async {
    FFmpegMuxService.mockMergeHandler = null;
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Task 3: Merge Failure Part Retention Suite', () {
    test('Retains video and audio parts when FFmpeg merge fails', () async {
      final videoPart = File(p.join(tempDir.path, 'video.mp4.dmxpart'));
      final audioPart = File(p.join(tempDir.path, 'audio.m4a.dmxpart'));
      final outputTarget = p.join(tempDir.path, 'final_video.mp4');

      await videoPart.writeAsBytes(List.generate(1024 * 10, (i) => i % 256));
      await audioPart.writeAsBytes(List.generate(1024 * 2, (i) => i % 256));

      expect(await videoPart.exists(), isTrue);
      expect(await audioPart.exists(), isTrue);

      // Simulate a failed merge (e.g. FFmpeg error or mux timeout)
      FFmpegMuxService.mockMergeHandler = (v, a, out) async {
        return false;
      };

      final success = await FFmpegMuxService.mergeVideoAudio(
        videoPart.path,
        audioPart.path,
        outputTarget,
        deleteInputsIfTemp: true,
      );

      expect(success, isFalse);

      // Critical requirement: Input parts MUST NOT be deleted on failure
      expect(await videoPart.exists(), isTrue,
          reason: 'Video part must be preserved after failed merge');
      expect(await audioPart.exists(), isTrue,
          reason: 'Audio part must be preserved after failed merge');

      // Verify canResumeMerge allows Retry Merge without re-downloading
      final canRetry = await FFmpegMuxService.canResumeMerge(
          videoPart.path, audioPart.path);
      expect(canRetry, isTrue);
    });

    test('Deletes temporary input parts only upon merge SUCCESS', () async {
      final videoPart = File(p.join(tempDir.path, 'video_ok.mp4.dmxpart'));
      final audioPart = File(p.join(tempDir.path, 'audio_ok.m4a.dmxpart'));
      final outputTarget = p.join(tempDir.path, 'final_video_ok.mp4');

      await videoPart.writeAsBytes(List.generate(1024 * 10, (i) => i % 256));
      await audioPart.writeAsBytes(List.generate(1024 * 2, (i) => i % 256));

      // Simulate a successful merge
      FFmpegMuxService.mockMergeHandler = (v, a, out) async {
        await File(out).writeAsBytes(List.generate(1024 * 12, (i) => i % 256));
        await File(v).delete();
        await File(a).delete();
        return true;
      };

      final success = await FFmpegMuxService.mergeVideoAudio(
        videoPart.path,
        audioPart.path,
        outputTarget,
        deleteInputsIfTemp: true,
      );

      expect(success, isTrue);
      expect(await File(outputTarget).exists(), isTrue);
      expect(await videoPart.exists(), isFalse);
      expect(await audioPart.exists(), isFalse);
    });
  });
}
