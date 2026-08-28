import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dmx/core/services/logging_service.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_min/statistics_callback.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../utils/semaphore.dart';

enum MergeStrategy { streamCopy, hwReencode, swFallback }

class _SessionHolder {
  FFmpegSession? activeSession;
}

class FFmpegMuxService {
  static final _log = Logger('FFmpegMuxService');
  static final Semaphore _mergeSemaphore = Semaphore(2);

  static Duration dynamicTimeout(int totalBytes) {
    final minutes =
        (10 + (totalBytes / (100 * 1024 * 1024)).ceil()).clamp(10, 30);
    return Duration(minutes: minutes);
  }

  static Future<bool> canResumeMerge(
      String videoPath, String? audioPath) async {
    final video = File(videoPath);
    final audio = audioPath != null ? File(audioPath) : null;
    return await video.exists() && (audio == null || await audio.exists());
  }

  @visibleForTesting
  static Future<bool> Function(
    String videoPath,
    String audioPath,
    String outputPath,
  )? mockMergeHandler;

  static Future<bool> mergeVideoAudio(
    String videoPath,
    String audioPath,
    String outputPath, {
    bool deleteInputsIfTemp = true,
    ValueChanged<double>? onProgress,
    Duration? totalDuration,
    Duration? expectedDuration,
  }) async {
    if (mockMergeHandler != null) {
      return await mockMergeHandler!(videoPath, audioPath, outputPath);
    }
    final vFile = File(videoPath);
    final aFile = File(audioPath);
    if (!await vFile.exists() || !await aFile.exists()) {
      _log.severe(
        '[FFmpegMuxService] Missing input file: videoExists=${await vFile.exists()}, audioExists=${await aFile.exists()}',
      );
      return false;
    }
    await _mergeSemaphore.acquire();
    var wakelockAcquired = false;
    final sessionHolder = _SessionHolder();
    try {
      try {
        await WakelockPlus.enable();
        wakelockAcquired = true;
      } catch (e) {
        _log.info('[FFmpegMuxService] wakelock enable skipped: $e');
      }
      int totalBytes = 0;
      try {
        final vFile = File(videoPath);
        final aFile = File(audioPath);
        if (vFile.existsSync()) totalBytes += vFile.lengthSync();
        if (aFile.existsSync()) totalBytes += aFile.lengthSync();
      } catch (_) {}
      final timeoutDuration = dynamicTimeout(totalBytes);

      return await _mergeLocked(
        videoPath,
        audioPath,
        outputPath,
        deleteInputsIfTemp: deleteInputsIfTemp,
        onProgress: onProgress,
        totalDuration: totalDuration,
        expectedDuration: expectedDuration,
        sessionHolder: sessionHolder,
      ).timeout(
        timeoutDuration,
        onTimeout: () {
          _log.severe(
            '[FFmpegMuxService] Merge job timed out after ${timeoutDuration.inMinutes} minutes; cancelling session',
          );
          try {
            if (sessionHolder.activeSession != null) {
              FFmpegKit.cancel(sessionHolder.activeSession!.getSessionId());
            }
          } catch (e, st) {
            LoggingService.logger('FfmpegMuxService')
                .warning('Operation failed', e, st);
          }
          // FIX P1-17: Delete orphan *.part on timeout — previously leaked.
          try {
            final tmp = File('$outputPath.part');
            if (tmp.existsSync()) tmp.deleteSync();
          } catch (_) {}
          return false;
        },
      );
    } finally {
      if (wakelockAcquired) {
        try {
          await WakelockPlus.disable();
        } catch (e) {
          _log.info('[FFmpegMuxService] wakelock disable skipped: $e');
        }
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
          '-max_muxing_queue_size',
          '1024',
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
        final isHwEncoder = videoCodec != 'libx264';
        final qualityArgs = isHwEncoder
            ? ['-b:v', '8M', '-maxrate', '12M', '-bufsize', '16M']
            : ['-crf', '23', '-preset', 'fast'];
        return [
          '-i',
          videoPath,
          '-i',
          audioPath,
          '-c:v',
          videoCodec,
          ...qualityArgs,
          '-c:a',
          'aac',
          '-b:a',
          '192k',
          '-max_muxing_queue_size',
          '1024',
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
          '-max_muxing_queue_size',
          '1024',
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

  static Future<bool> _canStreamCopy({
    required String videoPath,
    required String audioPath,
    required String outputPath,
  }) async {
    try {
      final ext = p.extension(outputPath).toLowerCase();
      final probeV = await FFprobeKit.executeWithArguments([
        '-v',
        'error',
        '-show_entries',
        'stream=codec_name',
        '-of',
        'default=noprint_wrappers=1',
        videoPath,
      ]);
      final vLogs = (await probeV.getLogsAsString()).toLowerCase();

      final probeA = await FFprobeKit.executeWithArguments([
        '-v',
        'error',
        '-show_entries',
        'stream=codec_name',
        '-of',
        'default=noprint_wrappers=1',
        audioPath,
      ]);
      final aLogs = (await probeA.getLogsAsString()).toLowerCase();

      if (ext == '.mp4' || ext == '.m4v') {
        final hasCompatibleVideo = vLogs.contains('h264') ||
            vLogs.contains('hevc') ||
            vLogs.contains('av01') ||
            vLogs.contains('vp9') ||
            vLogs.contains('avc1');
        final hasCompatibleAudio = aLogs.contains('aac') ||
            aLogs.contains('mp3') ||
            aLogs.contains('opus') ||
            aLogs.contains('m4a');
        return hasCompatibleVideo && hasCompatibleAudio;
      }
      if (ext == '.mkv' || ext == '.webm') {
        return true;
      }
      return false;
    } catch (e) {
      _log.info('Stream probe skipped or failed: $e');
      return false;
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
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-show_entries',
        'stream=codec_type',
        '-of',
        'default=noprint_wrappers=1',
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
        } catch (e, st) {
          LoggingService.logger('FfmpegMuxService')
              .warning('Operation failed', e, st);
        }
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[FFmpeg] FFprobe validation exception: $e');
      try {
        if (await file.exists()) await file.delete();
      } catch (e, st) {
        LoggingService.logger('FfmpegMuxService')
            .warning('Operation failed', e, st);
      }
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
    _SessionHolder? sessionHolder,
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

    // Clean up orphan .part files from previous failed merges in the same output directory
    try {
      final partFile = File('$outputPath.part');
      if (await partFile.exists()) {
        await partFile.delete();
        _log.info('Cleaned up orphan merge temp file: ${partFile.path}');
      }
    } catch (e) {
      _log.fine('Failed to clean orphan .part file: $e');
    }

    final requiredSpace = videoSize + audioSize;
    _log.info(
        'Starting merge for $videoSize bytes video + $audioSize bytes audio (required storage: $requiredSpace bytes)');

    final canCopy = await _canStreamCopy(
      videoPath: videoPath,
      audioPath: audioPath,
      outputPath: outputPath,
    );

    final strategies = canCopy
        ? [MergeStrategy.streamCopy]
        : [
            MergeStrategy.streamCopy,
            MergeStrategy.hwReencode,
            MergeStrategy.swFallback,
          ];

    final tempOutputPath = '$outputPath.part';
    for (final strategy in strategies) {
      final args = _buildArgs(
        videoPath: videoPath,
        audioPath: audioPath,
        outputPath: tempOutputPath,
        strategy: strategy,
      );
      _log.info('Running merge strategy $strategy with args: $args');
      DateTime lastStatsProgress = DateTime.fromMillisecondsSinceEpoch(0);

      // Task 3.6: Use per-session StatisticsCallback rather than the global
      // FFmpegKitConfig.enableStatisticsCallback, which can bleed across
      // concurrent sessions and requires manual cleanup on success/failure.
      StatisticsCallback? sessionStatsCallback;
      if (onProgress != null &&
          totalDuration != null &&
          totalDuration.inMilliseconds > 0) {
        sessionStatsCallback = (statistics) {
          final now = DateTime.now();
          // Cap statistics progress updates at 4 Hz (250 ms)
          if (now.difference(lastStatsProgress).inMilliseconds < 250) return;
          lastStatsProgress = now;
          final timeMs = statistics.getTime();
          if (timeMs > 0) {
            onProgress((timeMs / totalDuration.inMilliseconds).clamp(0.0, 1.0));
          }
        };
      }

      final session = await FFmpegSession.create(
        args,
        null,
        null,
        sessionStatsCallback,
      );
      sessionHolder?.activeSession = session;
      await FFmpegKitConfig.ffmpegExecute(session);

      try {
        final returnCode = await session.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          final targetExpectedDuration = expectedDuration ?? totalDuration;
          if (await _validateOutput(tempOutputPath,
              expectedDuration: targetExpectedDuration)) {
            final tempFile = File(tempOutputPath);
            final targetFile = File(outputPath);
            if (await targetFile.exists()) {
              try {
                await targetFile.delete();
              } catch (_) {}
            }
            try {
              await tempFile.rename(outputPath);
            } catch (_) {
              await tempFile.copy(outputPath);
              await tempFile.delete();
            }
            _log.info('Merge strategy $strategy succeeded: $outputPath');
            await cleanUpInputs();
            return true;
          }
        }
      } catch (e) {
        _log.warning('Merge strategy $strategy failed: $e');
      }
    }

    try {
      final outFile = File(tempOutputPath);
      if (await outFile.exists()) await outFile.delete();
    } catch (e) {
      _log.info('[FFmpegMuxService] deleting partial output failed: $e');
    }
    // FIX Task 3: Retain video and audio input parts on merge failure for seamless Retry Merge
    return false;
  }
}
