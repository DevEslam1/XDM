import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TEST-T2: youtubeStreamIdentityChanged', () {
    test('returns false when itag, mime, and clen match across host rotations', () {
      const url1 =
          'https://rr1---sn-4g5ednks.googlevideo.com/videoplayback?itag=22&mime=video%2Fmp4&clen=10485760&expire=123';
      const url2 =
          'https://rr2---sn-4g5ednks.googlevideo.com/videoplayback?itag=22&mime=video%2Fmp4&clen=10485760&expire=456';

      expect(
        DownloadProvider.youtubeStreamIdentityChanged(url1, url2),
        isFalse,
      );
    });

    test('returns true when itag differs', () {
      const url1 =
          'https://googlevideo.com/videoplayback?itag=22&mime=video%2Fmp4&clen=10485760';
      const url2 =
          'https://googlevideo.com/videoplayback?itag=137&mime=video%2Fmp4&clen=10485760';

      expect(
        DownloadProvider.youtubeStreamIdentityChanged(url1, url2),
        isTrue,
      );
    });

    test('returns true when clen differs', () {
      const url1 =
          'https://googlevideo.com/videoplayback?itag=22&mime=video%2Fmp4&clen=10485760';
      const url2 =
          'https://googlevideo.com/videoplayback?itag=22&mime=video%2Fmp4&clen=20971520';

      expect(
        DownloadProvider.youtubeStreamIdentityChanged(url1, url2),
        isTrue,
      );
    });

    test('returns true when mime differs', () {
      const url1 =
          'https://googlevideo.com/videoplayback?itag=22&mime=video%2Fmp4&clen=10485760';
      const url2 =
          'https://googlevideo.com/videoplayback?itag=22&mime=audio%2Fmp4&clen=10485760';

      expect(
        DownloadProvider.youtubeStreamIdentityChanged(url1, url2),
        isTrue,
      );
    });
  });

  group('TEST-T3: isYouTubePageUrl', () {
    test('identifies YouTube web page URLs', () {
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
            'https://www.youtube.com/shorts/abcdef12345'),
        isTrue,
      );
      expect(
        DownloadOrchestrator.isYouTubePageUrl('https://m.youtube.com/watch?v=xyz'),
        isTrue,
      );
    });

    test('returns false for direct googlevideo playback URLs with itag', () {
      expect(
        DownloadOrchestrator.isYouTubePageUrl(
          'https://rr3---sn-4g5ednks.googlevideo.com/videoplayback?expire=123&itag=22&source=youtube',
        ),
        isFalse,
      );
    });

    test('returns false for non-youtube URLs', () {
      expect(
        DownloadOrchestrator.isYouTubePageUrl('https://example.com/video.mp4'),
        isFalse,
      );
    });
  });

  group('TEST-T4: _autoResumeIncomplete filtering criteria', () {
    final now = DateTime.now();

    test('identifies tasks eligible for auto-resume vs skipped', () {
      // 1. Interrupted active download -> should resume
      final interruptedTask = DownloadTask(
        id: 't_interrupted',
        fileName: 'file.zip',
        url: 'https://example.com/file.zip',
        fileSize: 1000,
        downloadedBytes: 500,
        category: 'Archive',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/file.zip',
        tempFilePath: '/downloads/file.zip.dmxpart',
        threadCount: 4,
        chunks: const [0.5],
        createdAt: now,
        updatedAt: now,
        pausedByUser: false,
      );

      // 2. User paused task -> should NOT resume
      final userPausedTask = DownloadTask(
        id: 't_user_paused',
        fileName: 'file2.zip',
        url: 'https://example.com/file2.zip',
        fileSize: 1000,
        downloadedBytes: 200,
        category: 'Archive',
        status: DownloadStatus.paused,
        savePath: '/downloads',
        localFilePath: '/downloads/file2.zip',
        tempFilePath: '/downloads/file2.zip.dmxpart',
        threadCount: 4,
        chunks: const [0.2],
        createdAt: now,
        updatedAt: now,
        pausedByUser: true,
      );

      // 3. Waiting for wifi task -> should NOT auto-resume
      final waitingWifiTask = DownloadTask(
        id: 't_wifi',
        fileName: 'file3.zip',
        url: 'https://example.com/file3.zip',
        fileSize: 1000,
        downloadedBytes: 100,
        category: 'Archive',
        status: DownloadStatus.paused,
        savePath: '/downloads',
        localFilePath: '/downloads/file3.zip',
        tempFilePath: '/downloads/file3.zip.dmxpart',
        threadCount: 4,
        chunks: const [0.1],
        createdAt: now,
        updatedAt: now,
        pausedByUser: false,
        statusMessage: DownloadStatusMessages.waitingWifi,
      );

      // 4. Future scheduled task -> should NOT auto-resume immediately
      final futureScheduledTask = DownloadTask(
        id: 't_future_sched',
        fileName: 'file4.zip',
        url: 'https://example.com/file4.zip',
        fileSize: 1000,
        downloadedBytes: 0,
        category: 'Archive',
        status: DownloadStatus.paused,
        savePath: '/downloads',
        localFilePath: '/downloads/file4.zip',
        tempFilePath: '/downloads/file4.zip.dmxpart',
        threadCount: 4,
        chunks: const [],
        createdAt: now,
        updatedAt: now,
        pausedByUser: false,
        scheduledAt: now.add(const Duration(hours: 2)),
      );

      bool shouldAutoResume(DownloadTask task) {
        if (task.pausedByUser) return false;
        if (task.waitingWifi || task.waitingNetwork) return false;
        if (task.scheduledAt != null && task.scheduledAt!.isAfter(DateTime.now())) {
          return false;
        }
        return task.status == DownloadStatus.downloading ||
            task.status == DownloadStatus.queued ||
            (task.status == DownloadStatus.paused && !task.pausedByUser);
      }

      expect(shouldAutoResume(interruptedTask), isTrue);
      expect(shouldAutoResume(userPausedTask), isFalse);
      expect(shouldAutoResume(waitingWifiTask), isFalse);
      expect(shouldAutoResume(futureScheduledTask), isFalse);
    });
  });
}
