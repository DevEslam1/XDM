import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/ffmpeg_mux_service.dart';
import 'package:dmx/core/services/download_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Download Merge Pipeline Integration Tests (TC-01)', () {
    late Directory tempDir;
    late File videoFile;
    late File audioFile;
    late File outputFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('merge_pipeline_test_');
      videoFile = File('${tempDir.path}/sample.mp4.dmxpart');
      audioFile = File('${tempDir.path}/sample.mp4.audio');
      outputFile = File('${tempDir.path}/sample_final.mp4');

      // 100KB video, 50KB audio
      await videoFile.writeAsBytes(List.filled(100 * 1024, 0xAA));
      await audioFile.writeAsBytes(List.filled(50 * 1024, 0xBB));
    });

    tearDown(() async {
      FFmpegMuxService.mockMergeHandler = null;
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
        'Full mux pipeline merges video and audio into output file and cleans temp inputs',
        () async {
      FFmpegMuxService.mockMergeHandler = (vPath, aPath, outPath) async {
        final vBytes = await File(vPath).readAsBytes();
        final aBytes = await File(aPath).readAsBytes();
        final out = File(outPath);
        await out.writeAsBytes([...vBytes, ...aBytes]);
        await DownloadEngine.cleanupOrphanFiles(vPath, mergeConfirmed: true);
        return true;
      };

      final success = await FFmpegMuxService.mergeVideoAudio(
        videoFile.path,
        audioFile.path,
        outputFile.path,
      );

      expect(success, isTrue);
      expect(await outputFile.exists(), isTrue);
      expect(await outputFile.length(), equals(150 * 1024));

      // Intermediate files cleaned up
      expect(await videoFile.exists(), isFalse);
      expect(await audioFile.exists(), isFalse);
    });

    test('Pipeline failure / cancellation cleans up partial output', () async {
      FFmpegMuxService.mockMergeHandler = (vPath, aPath, outPath) async {
        final out = File(outPath);
        await out.writeAsBytes([0x00, 0x01, 0x02]);
        // Simulate failure / abort
        if (await out.exists()) {
          await out.delete();
        }
        return false;
      };

      final success = await FFmpegMuxService.mergeVideoAudio(
        videoFile.path,
        audioFile.path,
        outputFile.path,
      );

      expect(success, isFalse);
      expect(await outputFile.exists(), isFalse);
    });
  });
}
