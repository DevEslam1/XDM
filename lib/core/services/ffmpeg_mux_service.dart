import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:logging/logging.dart';

class FFmpegMuxService {
  static final _log = Logger('FFmpegMuxService');

  /// Merges a video-only file and an audio-only file into a single output file
  /// using FFmpeg. This uses `-c copy` so there is no re-encoding, making it
  /// extremely fast and preserving original quality.
  /// 
  /// Returns `true` if the merge was successful.
  static Future<bool> mergeVideoAudio(
      String videoPath, String audioPath, String outputPath) async {
    try {
      _log.info('Starting merge:\nVideo: $videoPath\nAudio: $audioPath\nOutput: $outputPath');

      // Check if input files exist and log their sizes
      final videoFile = File(videoPath);
      if (!await videoFile.exists()) {
        _log.severe('Video file does not exist: $videoPath');
        return false;
      }
      final videoSize = await videoFile.length();
      _log.info('Video file size: $videoSize bytes');

      final audioFile = File(audioPath);
      if (!await audioFile.exists()) {
        _log.severe('Audio file does not exist: $audioPath');
        return false;
      }
      final audioSize = await audioFile.length();
      _log.info('Audio file size: $audioSize bytes');

      if (videoSize == 0) {
        _log.severe('Video file is empty: $videoPath');
        return false;
      }
      if (audioSize == 0) {
        _log.severe('Audio file is empty: $audioPath');
        return false;
      }

      // Ensure output directory exists
      final outputDir = File(outputPath).parent;
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
        _log.info('Created output directory: ${outputDir.path}');
      }

      // Prepare command:
      // -i video -i audio : Inputs
      // -c copy : Stream copy (no re-encoding)
      // -map 0:v:0 : Use first video stream from first input
      // -map 1:a:0 : Use first audio stream from second input
      // -shortest : Finish encoding when the shortest input stream ends
      // -y : Overwrite output file if it exists
      final arguments = [
        '-i', videoPath,
        '-i', audioPath,
        '-c', 'copy',
        '-map', '0:v:0',
        '-map', '1:a:0',
        '-shortest',
        '-y',
        outputPath
      ];

      _log.info('FFmpeg arguments: $arguments');
      final session = await FFmpegKit.executeWithArguments(arguments);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        final outputFile = File(outputPath);
        if (await outputFile.exists()) {
          final outputSize = await outputFile.length();
          _log.info('Merge successful: $outputPath ($outputSize bytes)');
          // Clean up temp input files
          try { await videoFile.delete(); } catch (_) {}
          try { await audioFile.delete(); } catch (_) {}
        } else {
          _log.warning('Merge reported success but output file not found: $outputPath');
        }
        return true;
      } else {
        final logs = await session.getLogsAsString();
        _log.severe('Merge failed with return code $returnCode.\nLogs:\n$logs');
        return false;
      }
    } catch (e, stackTrace) {
      _log.severe('Exception during FFmpeg merge: $e\n$stackTrace');
      return false;
    }
  }
}
