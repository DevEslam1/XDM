import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DMX Lifecycle & Data Integrity Unit Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dmx_integrity_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('HTTP: StateStore._reconcileWithDisk clamps chunk downloaded bytes when file is truncated', () async {
      final targetFile = '${tempDir.path}/test_download.bin';
      // Create a file of only 250 bytes
      await File(targetFile).writeAsBytes(List.filled(250, 1));

      // State claims chunk 0 (0..499) downloaded 400 bytes, totalSize 1000
      final state = TransferState(
        totalSize: 1000,
        threadCount: 2,
        chunks: [
          ChunkState(start: 0, end: 499, downloaded: 400),
          ChunkState(start: 500, end: 999, downloaded: 0),
        ],
        url: 'https://example.com/file.bin',
      );
      await StateStore.save(targetFile, state, durable: true);

      // Load state which triggers reconcileWithDisk
      final loadRes = await StateStore.loadOrCreate(
        targetFile,
        url: 'https://example.com/file.bin',
        threadCount: 2,
        knownFileSize: 1000,
      );

      // Chunk 0 downloaded bytes must be clamped to actual file length (250)
      expect(loadRes.state.chunks[0].downloaded, equals(250));
      expect(loadRes.state.chunks[1].downloaded, equals(0));
      expect(loadRes.state.downloadedBytes, equals(250));
      expect(loadRes.diskAdjusted, isTrue);
    });

    test('HTTP: actualDownloadedBytes returns 0 if target file does not exist on disk', () async {
      final targetFile = '${tempDir.path}/missing_file.bin';
      final state = TransferState(
        totalSize: 1000,
        threadCount: 2,
        chunks: [
          ChunkState(start: 0, end: 499, downloaded: 300),
          ChunkState(start: 500, end: 999, downloaded: 200),
        ],
        url: 'https://example.com/file.bin',
      );
      await StateStore.save(targetFile, state, durable: true);

      // State exists on disk, but targetFile does NOT
      final bytes = await actualDownloadedBytes(targetFile, threadCount: 2);
      expect(bytes, equals(0));
    });

    test('HTTP: actualDownloadedBytes caps state bytes to actual file length', () async {
      final targetFile = '${tempDir.path}/partial_file.bin';
      await File(targetFile).writeAsBytes(List.filled(200, 42));

      final state = TransferState(
        totalSize: 1000,
        threadCount: 2,
        chunks: [
          ChunkState(start: 0, end: 499, downloaded: 300),
          ChunkState(start: 500, end: 999, downloaded: 200),
        ],
        url: 'https://example.com/file.bin',
      );
      await StateStore.save(targetFile, state, durable: true);

      // Reported state has 500 bytes, but file only has 200 bytes
      final bytes = await actualDownloadedBytes(targetFile, threadCount: 2);
      expect(bytes, equals(200));
    });

    test('HTTP: StateStore.remove deletes state files and temporary state files', () async {
      final targetFile = '${tempDir.path}/target.bin';
      final stateFile = File('$targetFile.dmxstate');
      final tmpStateFile = File('$targetFile.dmxstate.tmp');

      await stateFile.writeAsString(jsonEncode({'v': 3}));
      await tmpStateFile.writeAsString(jsonEncode({'v': 3}));

      expect(await stateFile.exists(), isTrue);
      expect(await tmpStateFile.exists(), isTrue);

      await StateStore.remove(targetFile);

      expect(await stateFile.exists(), isFalse);
      expect(await tmpStateFile.exists(), isFalse);
    });

    test('YouTube: DownloadTask combinedTotalSize and combinedDownloadedBytes integrity', () {
      final task = DownloadTask(
        id: 'yt-task-1',
        url: 'https://example.com/yt-stream',
        fileName: 'video.mp4',
        savePath: tempDir.path,
        localFilePath: '${tempDir.path}/video.mp4',
        tempFilePath: '${tempDir.path}/video.mp4.tmp',
        mergedAudioUrl: 'https://example.com/yt-audio',
        videoStreamSize: 8000,
        audioSize: 2000,
        fileSize: 10000,
        downloadedBytes: 4000, // 4000 of video
        audioProgress: 0.5, // 50% of 2000 audio = 1000
        category: 'Video',
        status: DownloadStatus.downloading,
        threadCount: 2,
        chunks: const [0.5, 0.5],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(task.combinedTotalSize, equals(10000));
      expect(task.combinedDownloadedBytes, equals(5000));
      expect(task.progress, closeTo(0.5, 0.001));
    });

    test('Torrent: torrentOverallPercent is disk/data accurate and clamped to 1.0', () {
      final task = DownloadTask(
        id: 'torrent-task-1',
        url: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        fileName: 'torrent_data',
        fileSize: 5000,
        downloadedBytes: 3000,
        status: DownloadStatus.downloading,
        savePath: tempDir.path,
        localFilePath: '${tempDir.path}/torrent_data',
        tempFilePath: '${tempDir.path}/torrent_data',
        category: 'Torrent',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        torrentFiles: [
          {
            'name': 'f1.mkv',
            'length': 4000,
            'downloadedBytes': 2000,
            'selected': true,
            'progressEstimated': false,
          },
          {
            'name': 'f2.nfo',
            'length': 1000,
            'downloadedBytes': 1000,
            'selected': true,
            'progressEstimated': false,
          },
          {
            'name': 'unselected.txt',
            'length': 5000,
            'downloadedBytes': 0,
            'selected': false,
            'progressEstimated': false,
          },
        ],
      );

      // Selected total = 5000, selected downloaded = 3000 -> 60%
      expect(task.torrentOverallPercent, closeTo(0.6, 0.001));
    });
  });
}
