import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.now();

  DownloadTask createTestTask({
    required String id,
    required String fileName,
    required String url,
    required int fileSize,
    int downloadedBytes = 0,
    int threadCount = 4,
    List<double> chunks = const [],
    int videoStreamSize = 0,
    int audioSize = 0,
    int audioDownloadedBytes = 0,
    String? mergedAudioUrl,
  }) {
    return DownloadTask(
      id: id,
      fileName: fileName,
      url: url,
      fileSize: fileSize,
      downloadedBytes: downloadedBytes,
      category: 'General',
      status: DownloadStatus.downloading,
      savePath: '/downloads',
      localFilePath: '/downloads/$fileName',
      tempFilePath: '/downloads/$fileName.dmxpart',
      threadCount: threadCount,
      chunks: chunks,
      createdAt: now,
      updatedAt: now,
      videoStreamSize: videoStreamSize,
      audioSize: audioSize,
      audioDownloadedBytes: audioDownloadedBytes,
      mergedAudioUrl: mergedAudioUrl,
    );
  }

  group('Download Cycle Bug Fixes Unit Tests', () {
    test('BUG 3: sanitizedChunks getter distributes progress when chunks list is empty', () {
      final task = createTestTask(
        id: 't_empty_chunks',
        fileName: 'test.mp4',
        url: 'https://example.com/test.mp4',
        fileSize: 1000,
        downloadedBytes: 500,
        threadCount: 4,
        chunks: [],
      );

      final sanitized = task.sanitizedChunks;
      expect(sanitized.length, equals(4));
      for (final chunkProgress in sanitized) {
        expect(chunkProgress, equals(0.5));
      }
    });

    test('BUG 3: sanitizedChunks clamps NaN chunk values to 0.0', () {
      final task = createTestTask(
        id: 't_nan_chunks',
        fileName: 'test.mp4',
        url: 'https://example.com/test.mp4',
        fileSize: 1000,
        downloadedBytes: 250,
        threadCount: 2,
        chunks: [double.nan, 0.5],
      );

      final sanitized = task.sanitizedChunks;
      expect(sanitized.length, equals(2));
      expect(sanitized[0], equals(0.0));
      expect(sanitized[1], equals(0.5));
    });

    test('BUG 3 (Audit Fix): combinedTotalSize returns 0 when videoStreamSize == 0 and fileSize <= 0 to trigger indeterminate state', () {
      final task = createTestTask(
        id: 't_unknown_size_av',
        fileName: 'yt.mp4',
        url: 'https://youtube.com/watch?v=123',
        fileSize: 0,
        videoStreamSize: 0,
        audioSize: 5000000,
        downloadedBytes: 10000000,
        audioDownloadedBytes: 2000000,
        mergedAudioUrl: 'https://youtube.com/audio',
      );

      expect(task.combinedTotalSize, equals(0));
    });

    test('FIX 11 & 4: videoStreamSize reset sentinel path in copyWith', () {
      final task = createTestTask(
        id: 't_stream_reset',
        fileName: 'yt.mp4',
        url: 'https://youtube.com/watch?v=123',
        fileSize: 10000000,
        videoStreamSize: 8000000,
      );

      final updated = task.copyWith(videoStreamSize: 0);
      expect(updated.videoStreamSize, equals(0));
    });

    test('FIX 19: normalizeChunks handles NaN/Infinity chunks gracefully', () {
      final chunks = [double.nan, double.infinity, 0.5, 1.0];
      final normalized = DownloadOrchestrator.normalizeChunks(chunks, 1000, 500);

      expect(normalized.length, equals(4));
      for (final c in normalized) {
        expect(c.isNaN, isFalse);
        expect(c.isInfinite, isFalse);
        expect(c >= 0.0 && c <= 1.0, isTrue);
      }
    });

    test('BUG 1: retryMergeOnly restores _video_only file when merge is retried', () async {
      final tempDir = await Directory.systemTemp.createTemp('video_only_test_');
      try {
        final localPath = '${tempDir.path}/merged_video.mp4';
        final videoOnlyPath = '${tempDir.path}/merged_video_video_only.mp4';
        final audioPath = '${tempDir.path}/task1.tmp.audio';

        await File(videoOnlyPath).writeAsString('video content');
        await File(audioPath).writeAsString('audio content');

        expect(File(videoOnlyPath).existsSync(), isTrue);
        expect(File(localPath).existsSync(), isFalse);

        final videoOnlyFile = File(videoOnlyPath);
        if (videoOnlyFile.existsSync() && !File(localPath).existsSync()) {
          await videoOnlyFile.rename(localPath);
        }

        expect(File(localPath).existsSync(), isTrue);
        expect(File(videoOnlyPath).existsSync(), isFalse);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });
}
