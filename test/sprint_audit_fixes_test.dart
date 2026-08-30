import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Sprint 1 & 2 Audit Fixes', () {
    test('C1 — DownloadTask.fromMap chunk mismatch preserves overall progress',
        () {
      // 4 chunks at 50% = total sum 2.0. With threadCount=2, each chunk should be 2.0 / 4 = 0.5 (50%)
      final mapNtoM = {
        'id': 'c1-task-1',
        'fileName': 'test.bin',
        'url': 'https://example.com/test.bin',
        'fileSize': 1000,
        'downloadedBytes': 500,
        'category': 'Other',
        'status': 'downloading',
        'savePath': '/tmp',
        'localFilePath': '/tmp/test.bin',
        'tempFilePath': '/tmp/test.bin.dmxpart',
        'threadCount': 2,
        'chunks': [0.5, 0.5, 0.5, 0.5], // rawChunks length = 4, threadCount = 2
        'createdAt': 100000,
        'updatedAt': 100000,
      };

      final task1 = DownloadTask.fromMap(mapNtoM);
      expect(task1.chunks.length, equals(2));
      expect(task1.chunks[0], equals(0.5));
      expect(task1.chunks[1], equals(0.5));

      // NaN and Infinity chunk values are sanitized to 0.0
      final mapNaN = {
        'id': 'c1-task-2',
        'fileName': 'test.bin',
        'url': 'https://example.com/test.bin',
        'fileSize': 1000,
        'downloadedBytes': 0,
        'category': 'Other',
        'status': 'downloading',
        'savePath': '/tmp',
        'localFilePath': '/tmp/test.bin',
        'tempFilePath': '/tmp/test.bin.dmxpart',
        'threadCount': 2,
        'chunks': [double.nan, double.infinity],
        'createdAt': 100000,
        'updatedAt': 100000,
      };

      final task2 = DownloadTask.fromMap(mapNaN);
      expect(task2.chunks.length, equals(2));
      expect(task2.chunks[0], equals(0.0));
      expect(task2.chunks[1], equals(0.0));
    });

    test(
        'C2 — youtubeStreamIdentityChanged compares itag/mime/clen ignoring CDN host rotation',
        () {
      const oldCdn =
          'https://rr1---sn-cx57n7e.googlevideo.com/videoplayback?itag=22&mime=video%2Fmp4&clen=500000';
      const newCdnHostRotated =
          'https://rr2---sn-ab57z7l.googlevideo.com/videoplayback?itag=22&mime=video%2Fmp4&clen=500000';
      const newItagChanged =
          'https://rr1---sn-cx57n7e.googlevideo.com/videoplayback?itag=137&mime=video%2Fmp4&clen=500000';
      const newMimeChanged =
          'https://rr1---sn-cx57n7e.googlevideo.com/videoplayback?itag=22&mime=video%2Fwebm&clen=500000';

      // Same stream format across CDN host rotation -> false (not identity changed)
      expect(
        DownloadProvider.youtubeStreamIdentityChanged(
            oldCdn, newCdnHostRotated),
        isFalse,
      );

      // itag change -> true
      expect(
        DownloadProvider.youtubeStreamIdentityChanged(oldCdn, newItagChanged),
        isTrue,
      );

      // mime change -> true
      expect(
        DownloadProvider.youtubeStreamIdentityChanged(oldCdn, newMimeChanged),
        isTrue,
      );

      // Invalid or unparseable URLs -> false
      expect(
        DownloadProvider.youtubeStreamIdentityChanged('not-a-url', oldCdn),
        isFalse,
      );
    });

    test(
        'H1 — isYouTubePageUrl detects YouTube watch, playlist, and shorts page URLs',
        () {
      expect(
        DownloadOrchestrator.isYouTubePageUrl(
            'https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        isTrue,
      );
      expect(
        DownloadOrchestrator.isYouTubePageUrl('https://youtu.be/dQw4w9WgXcQ'),
        isTrue,
      );
      expect(
        DownloadOrchestrator.isYouTubePageUrl(
            'https://www.youtube.com/shorts/abc123xyz'),
        isTrue,
      );
      // Resolved googlevideo stream URL -> false
      expect(
        DownloadOrchestrator.isYouTubePageUrl(
          'https://rr1---sn-cx57n7e.googlevideo.com/videoplayback?itag=22&mime=video%2Fmp4',
        ),
        isFalse,
      );
    });
  });
}
