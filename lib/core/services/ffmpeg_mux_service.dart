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

      // Check if input files exist
      if (!File(videoPath).existsSync()) {
        _log.severe('Video file does not exist: $videoPath');
        return false;
      }
      if (!File(audioPath).existsSync()) {
        _log.severe('Audio file does not exist: $audioPath');
        return false;
      }

      // Prepare command:
      // -i video -i audio : Inputs
      // -c copy : Stream copy (no re-encoding)
      // -map 0:v:0 : Use first video stream from first input
      // -map 1:a:0 : Use first audio stream from second input
      // -shortest : Finish encoding when the shortest input stream ends
      // -y : Overwrite output file if it exists
      final command =
          '-i "$videoPath" -i "$audioPath" -c copy -map 0:v:0 -map 1:a:0 -shortest -y "$outputPath"';

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        _log.info('Merge successful: $outputPath');
        
        return true;
      } else {
        final logs = await session.getLogsAsString();
        _log.severe('Merge failed with return code $returnCode.\nLogs: $logs');
        return false;
      }
    } catch (e) {
      _log.severe('Exception during FFmpeg merge: $e');
      return false;
    }
  }
}
