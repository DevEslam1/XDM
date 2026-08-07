import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';

void main() {
  group('YouTube Download Pause & Resume Data Integrity Tests', () {
    test('DownloadTask maintains progress calculations accurately', () {
      final task = DownloadTask(
        id: 'yt_test_1',
        fileName: 'Test Video.mp4',
        url: 'https://googlevideo.com/videoplayback?id=123',
        fileSize: 100000000, // 100 MB total
        downloadedBytes: 30000000, // 30 MB
        category: 'Video',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/Test Video.mp4',
        tempFilePath: '/downloads/temp/Test Video.mp4',
        threadCount: 4,
        chunks: [0.3, 0.3, 0.3, 0.3],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        mergedAudioUrl: 'https://googlevideo.com/videoplayback?id=123_audio',
        audioSize: 20000000, // 20 MB audio
        audioProgress: 0.5, // 50% audio
        youtubeQualityPreset: '1080p',
      );

      expect(task.progress, closeTo(0.4, 0.01));
      expect(task.progressPercentString, '40.0%');
      expect(task.audioProgressPercentString, '50.0%');
    });

    test(
        'copyWith updating status to paused does not lose downloadedBytes or audioProgress',
        () {
      final liveTask = DownloadTask(
        id: 'yt_test_2',
        fileName: 'Test Video.mp4',
        url: 'https://googlevideo.com/videoplayback?id=123',
        fileSize: 100000000,
        downloadedBytes: 45000000, // 45 MB downloaded
        category: 'Video',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/Test Video.mp4',
        tempFilePath: '/downloads/temp/Test Video.mp4',
        threadCount: 4,
        chunks: [0.45, 0.45, 0.45, 0.45],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        mergedAudioUrl: 'https://googlevideo.com/videoplayback?id=123_audio',
        audioSize: 20000000,
        audioProgress: 1.0, // 100% audio completed
        youtubeQualityPreset: '1080p',
      );

      final pausedTask = liveTask.copyWith(
        status: DownloadStatus.paused,
        speed: 0,
        clearEta: true,
        pausedByUser: true,
      );

      expect(pausedTask.status, DownloadStatus.paused);
      expect(pausedTask.downloadedBytes, 45000000);
      expect(pausedTask.audioProgress, 1.0);
      expect(pausedTask.fileSize, 100000000);
      expect(pausedTask.progressPercentString, '65.0%');
    });
  });
}
