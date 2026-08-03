import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:logging/logging.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class Semaphore {
  final int maxCount;
  int _currentCount = 0;
  final List<Completer<void>> _waiters = [];

  Semaphore(this.maxCount);

  Future<void> acquire() async {
    if (_currentCount < maxCount) {
      _currentCount++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      final next = _waiters.removeAt(0);
      next.complete();
    } else {
      _currentCount--;
      if (_currentCount < 0) _currentCount = 0;
    }
  }
}

enum MergeStrategy { streamCopy, hwReencode, swFallback }

class FFmpegMuxService {
  static final _log = Logger('FFmpegMuxService');

  /// Semaphore allows up to 2 concurrent merges safely while avoiding CPU thrashing.
  static final Semaphore _mergeSemaphore = Semaphore(2);

  /// Checks if temporary input files exist and can be remuxed without re-downloading.
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
        final videoCodec =
            Platform.isAndroid ? 'h264_mediacodec' : 'h264_videotoolbox';
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

  static Future<bool> _validateOutput(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    final size = await file.length();
    if (size < 1024) return false;

    try {
      final session = await FFprobeKit.execute(
        '-v error -show_entries format=duration -of default=noprint_wrappers=1 "$path"',
      );
      final logs = await session.getLogsAsString();
      final match = RegExp(r'duration=([\d.]+)').firstMatch(logs);
      final dur = double.tryParse(match?.group(1) ?? '');
      if (dur == null || dur <= 0) {
        _log.severe(
            '[Merge] Output validation failed: duration=$dur for $path');
        return false;
      }
      return true;
    } catch (e) {
      _log.warning('[Merge] FFprobe validation exception: $e');
      return true; // Fallback: allow valid file size if ffprobe fails
    }
  }

  static Future<bool> _mergeLocked(
    String videoPath,
    String audioPath,
    String outputPath, {
    bool deleteInputsIfTemp = true,
    ValueChanged<double>? onProgress,
    Duration? totalDuration,
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
        final match = RegExp(r'time=(\d+):(\d+):(\d+)\.(\d+)')
            .allMatches(logs)
            .lastOrNull;
        if (match != null) {
          final secs = int.parse(match.group(1)!) * 3600 +
              int.parse(match.group(2)!) * 60 +
              int.parse(match.group(3)!);
          onProgress((secs / totalDuration.inSeconds).clamp(0.0, 1.0));
        }
      });

      try {
        final returnCode = await session.getReturnCode();
        pollTimer.cancel();

        if (ReturnCode.isSuccess(returnCode)) {
          if (await _validateOutput(outputPath)) {
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

    // Clean up partial output if all strategies fail
    try {
      final outFile = File(outputPath);
      if (await outFile.exists()) await outFile.delete();
    } catch (e) {
      _log.info('[FFmpegMuxService] deleting partial output failed: $e');
    }

    return false;
  }
}
