import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DMX Download Lifecycle Fixes Verification', () {
    test('FIX-08: torrentOverallPercent clamps downloaded > total to <= 1.0',
        () {
      final task = DownloadTask(
        id: 't-1',
        url: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        fileName: 'test.torrent',
        savePath: '/tmp',
        localFilePath: '/tmp/test.torrent',
        tempFilePath: '/tmp/test.torrent.tmp',
        fileSize: 1000,
        downloadedBytes: 1500, // exceeds fileSize
        status: DownloadStatus.downloading,
        category: 'Torrent',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        torrentFiles: [
          {
            'name': 'f1.mp4',
            'length': 1000,
            'downloadedBytes': 1200,
            'selected': true
          },
        ],
      );

      expect(task.torrentOverallPercent, lessThanOrEqualTo(1.0));
      expect(task.torrentOverallPercent, equals(1.0));
    });

    test(
        'FIX-11: combinedTotalSize returns 0 when videoStreamSize == 0 for merged audio tasks',
        () {
      final task = DownloadTask(
        id: 'yt-1',
        url: 'https://example.com/video',
        fileName: 'video.mp4',
        savePath: '/tmp',
        localFilePath: '/tmp/video.mp4',
        tempFilePath: '/tmp/video.mp4.tmp',
        mergedAudioUrl: 'https://example.com/audio',
        audioSize: 5000,
        videoStreamSize: 0,
        fileSize: 0,
        downloadedBytes: 0,
        status: DownloadStatus.downloading,
        category: 'Video',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(task.combinedTotalSize, equals(0));
    });

    test(
        'FIX-13: youtubeStreamIdentityChanged returns false on CDN rotation with same clen/itag/mime',
        () {
      const oldUrl =
          'https://rr1---sn-abc.googlevideo.com/videoplayback?itag=137&mime=video/mp4&clen=5000000';
      const newUrl =
          'https://rr2---sn-xyz.googlevideo.com/videoplayback?itag=137&mime=video/mp4&clen=5000000';

      final changed =
          DownloadProvider.youtubeStreamIdentityChanged(oldUrl, newUrl);
      expect(changed, isFalse);
    });

    test(
        'FIX-13: youtubeStreamIdentityChanged returns true with different itag',
        () {
      const oldUrl =
          'https://rr1---sn-abc.googlevideo.com/videoplayback?itag=137&mime=video/mp4&clen=5000000';
      const newUrl =
          'https://rr1---sn-abc.googlevideo.com/videoplayback?itag=248&mime=video/mp4&clen=5000000';

      final changed =
          DownloadProvider.youtubeStreamIdentityChanged(oldUrl, newUrl);
      expect(changed, isTrue);
    });

    test(
        'FIX-14: isYouTubePageUrl rejects watch/playlist/shorts and accepts direct stream urls',
        () {
      expect(
          DownloadOrchestrator.isYouTubePageUrl(
              'https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
          isTrue);
      expect(
          DownloadOrchestrator.isYouTubePageUrl('https://youtu.be/dQw4w9WgXcQ'),
          isTrue);
      expect(
          DownloadOrchestrator.isYouTubePageUrl(
              'https://www.youtube.com/shorts/xyz123'),
          isTrue);
      expect(
          DownloadOrchestrator.isYouTubePageUrl(
              'https://rr1---sn-abc.googlevideo.com/videoplayback?itag=137'),
          isFalse);
    });

    test('FIX-16: reconcileChunks handles thread count redistribution', () {
      final chunks = DownloadProvider.reconcileChunks(
        stateChunks: [0.5, 0.5],
        actualBytesOnDisk: 500,
        fileSize: 1000,
        threadCount: 4,
      );

      expect(chunks.length, equals(4));
      for (final c in chunks) {
        expect(c, closeTo(0.5, 0.01));
      }
    });

    test(
        'FIX-19: actualDownloadedBytes reads from .dmxstate, ignoring pre-allocated length for multi-threaded',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('dmx_test_fix19_');
      final tempFilePath = '${tempDir.path}/test_file.bin';
      final dmxStatePath = '$tempFilePath.dmxstate';

      // Simulate a pre-allocated 10MB file
      final file = File(tempFilePath);
      final sink = file.openWrite();
      sink.add(List.filled(1024 * 1024, 0)); // 1MB written on disk
      await sink.flush();
      await sink.close();

      // State record only has 256KB downloaded
      final stateFile = File(dmxStatePath);
      await stateFile.writeAsString(
          '{"chunks":[{"start":0,"end":500000,"downloaded":262144,"ratio":0.524}]}');

      final actualBytes =
          await actualDownloadedBytes(tempFilePath, threadCount: 4);
      expect(actualBytes, equals(262144));

      await tempDir.delete(recursive: true);
    });
  });
}
