import 'dart:io';

import 'package:dmx/core/services/ffmpeg_mux_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FFmpegMuxService.dynamicTimeout', () {
    test('returns the 10 minute floor for an empty payload', () {
      expect(FFmpegMuxService.dynamicTimeout(0), const Duration(minutes: 10));
    });

    test('grows with payload size', () {
      // 100 MiB -> 10 + 1 = 11 minutes.
      expect(
        FFmpegMuxService.dynamicTimeout(100 * 1024 * 1024),
        const Duration(minutes: 11),
      );
      // 500 MiB -> 10 + 5 = 15 minutes.
      expect(
        FFmpegMuxService.dynamicTimeout(500 * 1024 * 1024),
        const Duration(minutes: 15),
      );
    });

    test('caps at 30 minutes', () {
      expect(
        FFmpegMuxService.dynamicTimeout(10 * 1024 * 1024 * 1024),
        const Duration(minutes: 30),
      );
    });
  });

  group('FFmpegMuxService.canResumeMerge', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ffmpeg_canresume_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('false when video is missing', () async {
      expect(
        await FFmpegMuxService.canResumeMerge(
          '${dir.path}/missing.mp4',
          '${dir.path}/missing.aac',
        ),
        isFalse,
      );
    });

    test('true when only the video exists and audio is null', () async {
      final video = File('${dir.path}/video.mp4')..writeAsStringSync('v');
      expect(await FFmpegMuxService.canResumeMerge(video.path, null), isTrue);
    });

    test('false when audio is provided but missing', () async {
      final video = File('${dir.path}/video.mp4')..writeAsStringSync('v');
      expect(
        await FFmpegMuxService.canResumeMerge(
            video.path, '${dir.path}/missing.aac'),
        isFalse,
      );
    });

    test('true when both files exist', () async {
      final video = File('${dir.path}/video.mp4')..writeAsStringSync('v');
      final audio = File('${dir.path}/audio.aac')..writeAsStringSync('a');
      expect(
        await FFmpegMuxService.canResumeMerge(video.path, audio.path),
        isTrue,
      );
    });
  });

  group('FFmpegMuxService.mergeVideoAudio', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ffmpeg_merge_');
    });

    tearDown(() {
      FFmpegMuxService.mockMergeHandler = null;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('delegates to the mock handler when installed', () async {
      final calls = <List<String>>[];
      FFmpegMuxService.mockMergeHandler = (v, a, o) async {
        calls.add([v, a, o]);
        return true;
      };
      final ok = await FFmpegMuxService.mergeVideoAudio(
        '${dir.path}/v.mp4',
        '${dir.path}/a.aac',
        '${dir.path}/out.mp4',
      );
      expect(ok, isTrue);
      expect(calls, hasLength(1));
      expect(calls.first.last, '${dir.path}/out.mp4');
    });

    test('propagates a false result from the mock handler', () async {
      FFmpegMuxService.mockMergeHandler = (v, a, o) async => false;
      final ok = await FFmpegMuxService.mergeVideoAudio(
        '${dir.path}/v.mp4',
        '${dir.path}/a.aac',
        '${dir.path}/out.mp4',
      );
      expect(ok, isFalse);
    });

    test('returns false when input files are missing', () async {
      final ok = await FFmpegMuxService.mergeVideoAudio(
        '${dir.path}/missing_video.mp4',
        '${dir.path}/missing_audio.aac',
        '${dir.path}/out.mp4',
      );
      expect(ok, isFalse);
    });

    test('returns false when only the audio input is missing', () async {
      final video = File('${dir.path}/v.mp4')..writeAsStringSync('video');
      final ok = await FFmpegMuxService.mergeVideoAudio(
        video.path,
        '${dir.path}/missing_audio.aac',
        '${dir.path}/out.mp4',
      );
      expect(ok, isFalse);
    });
  });

  group('MergeStrategy enum', () {
    test('exposes the documented strategies', () {
      expect(MergeStrategy.values, containsAll(<MergeStrategy>[
        MergeStrategy.streamCopy,
        MergeStrategy.hwReencode,
        MergeStrategy.swFallback,
      ]));
    });
  });
}
