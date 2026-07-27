import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:logging/logging.dart';

class FFmpegMuxService {
  static final _log = Logger('FFmpegMuxService');

  static Future<bool> mergeVideoAudio(
    String videoPath,
    String audioPath,
    String outputPath, {
    bool deleteInputsIfTemp = true,
  }) async {
    bool isTempFile(String path) {
      final name = p.basename(path).toLowerCase();
      return name.endsWith('.tmp') ||
          name.endsWith('.audio') ||
          name.endsWith('.dmxpart') ||
          name.endsWith('.temp');
    }

    final videoFile = File(videoPath);
    final audioFile = File(audioPath);

    Future<void> cleanUpInputs() async {
      if (deleteInputsIfTemp) {
        if (isTempFile(videoPath)) {
          try {
            await videoFile.delete();
          } catch (e) {
            _log.warning('Failed to delete temp video input file: $e');
          }
        }
        if (isTempFile(audioPath)) {
          try {
            await audioFile.delete();
          } catch (e) {
            _log.warning('Failed to delete temp audio input file: $e');
          }
        }
      }
    }

    /// Cancels all active FFmpeg sessions (best-effort) and re-throws [error].
    Future<Never> cancelAndRethrow(Object error, StackTrace stack) async {
      try {
        final sessions = await FFmpegKit.listSessions();
        for (final s in sessions) {
          await FFmpegKit.cancel(s.getSessionId());
        }
      } catch (cancelErr) {
        _log.warning('FFmpeg cancel on timeout failed: $cancelErr');
      }
      Error.throwWithStackTrace(error, stack);
    }

    try {
      _log.info(
        'Starting merge:\nVideo: $videoPath\nAudio: $audioPath\nOutput: $outputPath',
      );

      if (!await videoFile.exists()) {
        _log.severe('Video file does not exist: $videoPath');
        return false;
      }
      final videoSize = await videoFile.length();
      _log.info('Video file size: $videoSize bytes');

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
        '-i',
        videoPath,
        '-i',
        audioPath,
        '-c',
        'copy',
        '-map',
        '0:v:0',
        '-map',
        '1:a:0',
        '-shortest',
        '-y',
        outputPath,
      ];

      final int totalInputBytes = videoSize + audioSize;
      final calculatedMinutes =
          (totalInputBytes / (200 * 1024 * 1024)).ceil() + 15;
      final timeoutDuration = Duration(
        minutes: calculatedMinutes.clamp(15, 300),
      );

      _log.info(
        'FFmpeg arguments: $arguments (Timeout: ${timeoutDuration.inMinutes} mins)',
      );

      // Primary attempt -------------------------------------------------------
      final session = await FFmpegKit.executeWithArguments(arguments)
          .timeout(timeoutDuration, onTimeout: () {
        throw TimeoutException(
          'FFmpeg primary merge timed out after ${timeoutDuration.inMinutes} min',
        );
      });
      final returnCode = await session
          .getReturnCode()
          .timeout(const Duration(seconds: 30));

      if (ReturnCode.isSuccess(returnCode)) {
        final outputFile = File(outputPath);
        if (await outputFile.exists()) {
          final outputSize = await outputFile.length();
          _log.info('Merge successful: $outputPath ($outputSize bytes)');
          await cleanUpInputs();
          return true;
        } else {
          _log.warning(
            'Merge reported success but output file not found: $outputPath',
          );
          return false;
        }
      } else {
        final logs = await session.getLogsAsString();
        _log.severe('Merge failed with return code $returnCode.\nLogs:\n$logs');

        // Fallback attempt: re-encode audio to AAC --------------------------
        _log.info('Retrying merge with AAC audio encoding...');
        final fallbackArguments = [
          '-i',
          videoPath,
          '-i',
          audioPath,
          '-c:v',
          'copy',
          '-c:a',
          'aac',
          '-b:a',
          '192k',
          '-map',
          '0:v:0',
          '-map',
          '1:a:0',
          '-shortest',
          '-y',
          outputPath,
        ];

        final fallbackSession =
            await FFmpegKit.executeWithArguments(fallbackArguments)
                .timeout(timeoutDuration, onTimeout: () {
          throw TimeoutException(
            'FFmpeg fallback merge timed out after ${timeoutDuration.inMinutes} min',
          );
        });
        final fallbackReturnCode = await fallbackSession
            .getReturnCode()
            .timeout(const Duration(seconds: 30));

        if (ReturnCode.isSuccess(fallbackReturnCode)) {
          final outputFile = File(outputPath);
          if (await outputFile.exists()) {
            final outputSize = await outputFile.length();
            _log.info(
              'Fallback merge successful: $outputPath ($outputSize bytes)',
            );
            await cleanUpInputs();
            return true;
          }
        }

        final fallbackLogs = await fallbackSession.getLogsAsString();
        _log.severe(
          'Fallback merge failed with return code $fallbackReturnCode.\nLogs:\n$fallbackLogs',
        );

        try {
          final outputFile = File(outputPath);
          if (await outputFile.exists()) await outputFile.delete();
        } catch (e) {
          _log.warning('Failed to delete failed output file: $e');
        }
        return false;
      }
    } on TimeoutException catch (e, stack) {
      // Cancel any lingering native sessions then propagate.
      _log.severe('FFmpeg timed out: $e — cancelling native sessions');
      await cleanUpInputs();
      await cancelAndRethrow(e, stack);
    } catch (e, stackTrace) {
      _log.severe('Exception during FFmpeg merge: $e\n$stackTrace');
      // Clean up temp inputs even if an exception (like timeout) occurs
      await cleanUpInputs();
      rethrow;
    }
  }
}
