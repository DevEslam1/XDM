import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:logging/logging.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../utils/semaphore.dart';

enum MergeStrategy { streamCopy, hwReencode, swFallback }

class FFmpegMuxService {
  static final _log = Logger('FFmpegMuxService');
  static final Semaphore _mergeSemaphore = Semaphore(2);

  static Future<bool> canResumeMerge(
      String videoPath, String? audioPath) async {
    final video = File(videoPath);
    final audio = audioPath != null ? File(audioPath) : null;
    return await video.exists() && (audio == null || await audio.exists());
  }

  static Future<bool> mergeVideoAudio(
    String videoPath,
    String audioPath,
    String outputPath, {
    bool deleteInputsIfTemp = true,
    ValueChanged<double>? onProgress,
    Duration? totalDuration,
    Duration? expectedDuration,
  }) async {
    await _mergeSemaphore.acquire();
    try {
      await WakelockPlus.enable();
    } catch (e) {
      _log.info('[FFmpegMuxService] wakelock enable skipped: $e');
    }
    try {
      return await _mergeLocked(
        videoPath,
        audioPath,
        outputPath,
        deleteInputsIfTemp: deleteInputsIfTemp,
        onProgress: onProgress,
        totalDuration: totalDuration,
        expectedDuration: expectedDuration,
      );
    } finally {
      try {
        await WakelockPlus.disable();
      } catch (e) {
        _log.info('[FFmpegMuxService] wakelock disable skipped: $e');
      }
      _mergeSemaphore.release();
    }
  }

  static List<String> _buildArgs({
    required String videoPath,
    required String audioPath,
    required String outputPath,
    required MergeStrategy strategy,
  }) {
    switch (strategy) {
      case MergeStrategy.streamCopy:
        return [
          '-i',
          videoPath,
          '-i',
          audioPath,
          '-c:v',
          'copy',
          '-c:a',
          'copy',
          '-map',
          '0:v:0',
          '-map',
          '1:a:0',
          '-movflags',
          '+faststart',
          '-shortest',
          '-y',
          outputPath,
        ];
      case MergeStrategy.hwReencode:
        final videoCodec = Platform.isAndroid
            ? 'h264_mediacodec'
            : Platform.isMacOS
                ? 'h264_videotoolbox'
                : 'libx264';
        return [
          '-i',
          videoPath,
          '-i',
          audioPath,
          '-c:v',
          videoCodec,
          '-b:v',
          '5M',
          '-c:a',
          'aac',
          '-b:a',
          '192k',
          '-af',
          'loudnorm=I=-16:TP=-1.5:LRA=11',
          '-map',
          '0:v:0',
          '-map',
          '1:a:0',
          '-movflags',
          '+faststart',
          '-shortest',
          '-y',
          outputPath,
        ];
      case MergeStrategy.swFallback:
        return [
          '-i',
          videoPath,
          '-i',
          audioPath,
          '-c:v',
          'libx264',
          '-preset',
          'veryfast',
          '-crf',
          '23',
          '-c:a',
          'aac',
          '-b:a',
          '192k',
          '-af',
          'loudnorm=I=-16:TP=-1.5:LRA=11',
          '-map',
          '0:v:0',
          '-map',
          '1:a:0',
          '-movflags',
          '+faststart',
          '-shortest',
          '-y',
          outputPath,
        ];
    }
  }

  static Future<bool> _validateOutput(
    String path, {
    Duration? expectedDuration,
  }) async {
    final file = File(path);
    if (!await file.exists()) return false;
    try {
      final probe = await FFprobeKit.executeWithArguments([
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-show_entries', 'stream=codec_type',
        '-of', 'default=noprint_wrappers=1',
        path,
      ]);
      final logs = await probe.getLogsAsString();
      final hasVideo = logs.contains('codec_type=video');
      final hasAudio = logs.contains('codec_type=audio');
      final durMatch = RegExp(r'duration=([\d.]+)').firstMatch(logs);
      final duration = double.tryParse(durMatch?.group(1) ?? '') ?? 0;
      final sizeOk = path.isNotEmpty &&
          await file.exists() &&
          (await file.length()) > 1024;
      final expectedSecs = expectedDuration != null
          ? expectedDuration.inMilliseconds / 1000.0
          : null;
      final durationOk = expectedSecs == null ||
          (duration > 0 &&
              (duration - expectedSecs).abs() <=
                  math.max(2.0, expectedSecs * 0.05));
      if (!hasVideo || !hasAudio || !sizeOk || !durationOk) {
        debugPrint('[FFmpeg] Merged output invalid '
            '(video=$hasVideo audio=$hasAudio size=$sizeOk dur=$durationOk)');
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[FFmpeg] FFprobe validation exception: $e');
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      return false;
    }
  }

  static Future<bool> _mergeLocked(
    String videoPath,
    String audioPath,
    String outputPath, {
    bool deleteInputsIfTemp = true,
    ValueChanged<double>? onProgress,
    Duration? totalDuration,
    Duration? expectedDuration,
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

    if (!await videoFile.exists() || !await audioFile.exists()) {
      _log.severe('Input video or audio file missing.');
      return false;
    }
    final videoSize = await videoFile.length();
    final audioSize = await audioFile.length();
    if (videoSize == 0 || audioSize == 0) {
      _log.severe('Input file is empty.');
      return false;
    }

    final outputDir = File(outputPath).parent;
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    for (final strategy in [
      MergeStrategy.streamCopy,
      MergeStrategy.hwReencode,
      MergeStrategy.swFallback,
    ]) {
      final args = _buildArgs(
        videoPath: videoPath,
        audioPath: audioPath,
        outputPath: outputPath,
        strategy: strategy,
      );
      _log.info('Running merge strategy $strategy with args: $args');
      final session = await FFmpegKit.executeWithArguments(args);

      final pollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (onProgress == null ||
            totalDuration == null ||
            totalDuration.inSeconds == 0) {
          return;
        }
        final logs = await session.getLogsAsString();
        final lines = logs.split('\n');
        for (var i = lines.length - 1; i >= 0; i--) {
          final match = RegExp(r'time=(\d+):(\d+):(\d+)\.(\d+)').firstMatch(lines[i]);
          if (match != null) {
            final secs = int.parse(match.group(1)!) * 3600 +
                int.parse(match.group(2)!) * 60 +
                int.parse(match.group(3)!);
            onProgress((secs / totalDuration.inSeconds).clamp(0.0, 1.0));
            break;
          }
        }
      });

      try {
        final returnCode = await session.getReturnCode();
        pollTimer.cancel();
        if (ReturnCode.isSuccess(returnCode)) {
          final targetExpectedDuration = expectedDuration ?? totalDuration;
          if (await _validateOutput(outputPath,
              expectedDuration: targetExpectedDuration)) {
            _log.info('Merge strategy $strategy succeeded: $outputPath');
            await cleanUpInputs();
            return true;
          }
        }
      } catch (e) {
        pollTimer.cancel();
        _log.warning('Merge strategy $strategy failed: $e');
      }
    }

    try {
      final outFile = File(outputPath);
      if (await outFile.exists()) await outFile.delete();
    } catch (e) {
      _log.info('[FFmpegMuxService] deleting partial output failed: $e');
    }
    return false;
  }
}