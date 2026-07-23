import 'dart:io';
import 'package:path/path.dart' as p;
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
      String videoPath, String audioPath, String outputPath,
      {bool deleteInputsIfTemp = true}) async {
    bool isTempFile(String path) {
      final name = p.basename(path).toLowerCase();
      return name.endsWith('.tmp') ||
          name.endsWith('.audio') ||
          name.endsWith('.dmxpart') ||
          name.endsWith('.temp');
    }

    try {
      _log.info('Starting merge:\nVideo: $videoPath\nAudio: $audioPath\nOutput: $outputPath');

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

      if (videoSize == 0 || audioSize == 0) {
        _log.severe('Input file is empty.');
        return false;
      }

      final outputDir = File(outputPath).parent;
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
        _log.info('Created output directory: ${outputDir.path}');
      }

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
      final session = await FFmpegKit
          .executeWithArguments(arguments)
          .timeout(const Duration(minutes: 60));
      final returnCode = await session.getReturnCode();

      Future<void> cleanUpInputs() async {
        if (deleteInputsIfTemp) {
          if (isTempFile(videoPath)) {
            try { await videoFile.delete(); } catch (_) {}
          }
          if (isTempFile(audioPath)) {
            try { await audioFile.delete(); } catch (_) {}
          }
        }
      }

      if (ReturnCode.isSuccess(returnCode)) {
        final outputFile = File(outputPath);
        if (await outputFile.exists()) {
          final outputSize = await outputFile.length();
          _log.info('Merge successful: $outputPath ($outputSize bytes)');
          await cleanUpInputs();
          return true;
        } else {
          _log.warning('Merge reported success but output file not found: $outputPath');
          return false;
        }
      } else {
        final logs = await session.getLogsAsString();
        _log.severe('Merge failed with return code $returnCode.\nLogs:\n$logs');
        
        _log.info('Retrying merge with AAC audio encoding...');
        final fallbackArguments = [
          '-i', videoPath,
          '-i', audioPath,
          '-c:v', 'copy',
          '-c:a', 'aac',
          '-b:a', '192k',
          '-map', '0:v:0',
          '-map', '1:a:0',
          '-shortest',
          '-y',
          outputPath
        ];
        
        final fallbackSession = await FFmpegKit.executeWithArguments(fallbackArguments)
            .timeout(const Duration(minutes: 60));
        final fallbackReturnCode = await fallbackSession.getReturnCode();
        
        if (ReturnCode.isSuccess(fallbackReturnCode)) {
          final outputFile = File(outputPath);
          if (await outputFile.exists()) {
            final outputSize = await outputFile.length();
            _log.info('Fallback merge successful: $outputPath ($outputSize bytes)');
            await cleanUpInputs();
            return true;
          }
        }
        
        final fallbackLogs = await fallbackSession.getLogsAsString();
        _log.severe('Fallback merge failed with return code $fallbackReturnCode.\nLogs:\n$fallbackLogs');

        try {
          final outputFile = File(outputPath);
          if (await outputFile.exists()) await outputFile.delete();
        } catch (_) {}
        return false;
      }
    } catch (e, stackTrace) {
      _log.severe('Exception during FFmpeg merge: $e\n$stackTrace');
      return false;
    }
  }
}
