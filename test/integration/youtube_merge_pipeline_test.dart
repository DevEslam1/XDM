import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/models/download_task.dart';

void main() {
  group('YouTube Merge Pipeline Integration Test (FIX-35)', () {
    test('YouTube dual-stream task calculates combined size and progress correctly', () {
      final task = DownloadTask(
        id: 'yt_test_1',
        fileName: 'Sample Video.mp4',
        url: 'https://rr1---sn-abc.googlevideo.com/videoplayback?itag=137',
        fileSize: 100 * 1024 * 1024, // 100 MB video
        videoStreamSize: 100 * 1024 * 1024,
        downloadedBytes: 50 * 1024 * 1024,
        mergedAudioUrl: 'https://rr1---sn-abc.googlevideo.com/videoplayback?itag=140',
        audioSize: 20 * 1024 * 1024, // 20 MB audio
        audioDownloadedBytes: 10 * 1024 * 1024,
        audioProgress: 0.5,
        category: 'Videos',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/Sample Video.mp4',
        tempFilePath: '/downloads/Sample Video.mp4.xdm',
        threadCount: 4,
        chunks: const [0.5, 0.5, 0.5, 0.5],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(task.hasMergedAudio, isTrue);
      expect(task.combinedTotalSize, equals(120 * 1024 * 1024)); // 100MB + 20MB
      expect(task.combinedDownloadedBytes, equals(60 * 1024 * 1024)); // 50MB + 10MB
      expect(task.progress, closeTo(0.5, 0.01));
    });

    test('YouTube stream transition through merging and completion', () {
      var task = DownloadTask(
        id: 'yt_test_2',
        fileName: 'Music Video.mp4',
        url: 'https://rr1---sn-abc.googlevideo.com/videoplayback?itag=137',
        fileSize: 50 * 1024 * 1024,
        videoStreamSize: 50 * 1024 * 1024,
        downloadedBytes: 50 * 1024 * 1024,
        mergedAudioUrl: 'https://rr1---sn-abc.googlevideo.com/videoplayback?itag=140',
        audioSize: 10 * 1024 * 1024,
        audioDownloadedBytes: 10 * 1024 * 1024,
        audioProgress: 1.0,
        category: 'Videos',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/Music Video.mp4',
        tempFilePath: '/downloads/Music Video.mp4.xdm',
        threadCount: 4,
        chunks: const [1.0, 1.0, 1.0, 1.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // Both streams complete -> transitions to merging
      task = task.copyWith(
        status: DownloadStatus.merging,
        isMergeInProgress: true,
        statusMessage: 'Merging audio and video tracks...',
      );

      expect(task.status, equals(DownloadStatus.merging));
      expect(task.isMergeInProgress, isTrue);
      expect(DownloadTask.isValidTransition(DownloadStatus.downloading, DownloadStatus.merging), isTrue);

      // Merge complete -> transitions to completed
      task = task.copyWith(
        status: DownloadStatus.completed,
        isMergeInProgress: false,
        completedAt: DateTime.now(),
        statusMessage: null,
      );

      expect(task.status, equals(DownloadStatus.completed));
      expect(task.progress, equals(1.0));
      expect(DownloadTask.isValidTransition(DownloadStatus.merging, DownloadStatus.completed), isTrue);
    });

    test('YouTube merge failure allows retrying or resuming', () {
      var task = DownloadTask(
        id: 'yt_test_3',
        fileName: 'Podcast.mp4',
        url: 'https://rr1---sn-abc.googlevideo.com/videoplayback?itag=137',
        fileSize: 40 * 1024 * 1024,
        videoStreamSize: 40 * 1024 * 1024,
        downloadedBytes: 40 * 1024 * 1024,
        mergedAudioUrl: 'https://rr1---sn-abc.googlevideo.com/videoplayback?itag=140',
        audioSize: 10 * 1024 * 1024,
        audioDownloadedBytes: 10 * 1024 * 1024,
        category: 'Videos',
        status: DownloadStatus.merging,
        savePath: '/downloads',
        localFilePath: '/downloads/Podcast.mp4',
        tempFilePath: '/downloads/Podcast.mp4.xdm',
        threadCount: 2,
        chunks: const [1.0, 1.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      task = task.copyWith(
        status: DownloadStatus.failed,
        errorMessage: 'FFmpeg merge failed: Corrupt audio container',
        failureCategory: FailureCategory.mergeFailed,
      );

      expect(task.status, equals(DownloadStatus.failed));
      expect(task.failureCategory, equals(FailureCategory.mergeFailed));
      expect(DownloadTask.isValidTransition(DownloadStatus.merging, DownloadStatus.failed), isTrue);
    });
  });
}
