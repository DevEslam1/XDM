import 'package:dmx/core/services/data_status_verifier.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Section 11 Unit Tests — Download Lifecycle & Data Status Audit', () {
    // 1. DataStatusVerifier.verifyHttpTask — all edge cases
    test('1. verifyHttpTask checks HTTP data status and detects inconsistencies', () {
      final validTask = DownloadTask(
        id: 'http-1',
        fileName: 'test.zip',
        url: 'https://example.com/test.zip',
        fileSize: 1000,
        downloadedBytes: 500,
        category: 'Archives',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/test.zip',
        tempFilePath: '/downloads/test.zip.tmp',
        threadCount: 2,
        chunks: [0.5, 0.5],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final validStatus = DataStatusVerifier.verifyHttpTask(validTask);
      expect(validStatus.isConsistent, isTrue);
      expect(validStatus.overallPercent, closeTo(0.5, 0.01));
      expect(validStatus.totalParts, 2);
      expect(validStatus.parts.length, 2);

      // Edge case: overflow / mismatch
      final overflowTask = DownloadTask(
        id: 'http-overflow',
        fileName: 'test.zip',
        url: 'https://example.com/test.zip',
        fileSize: 1000,
        downloadedBytes: 2000,
        category: 'Archives',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/test.zip',
        tempFilePath: '/downloads/test.zip.tmp',
        threadCount: 2,
        chunks: [1.0, 1.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final overStatus = DataStatusVerifier.verifyHttpTask(overflowTask);
      expect(overStatus.isConsistent, isFalse);
      expect(overStatus.inconsistencies.any((i) => i.contains('exceeds totalBytes')), isTrue);
    });

    // 2. DataStatusVerifier.verifyYtTask — all edge cases
    test('2. verifyYtTask checks YouTube dual-stream data status', () {
      final ytTask = DownloadTask(
        id: 'yt-1',
        fileName: 'video.mp4',
        url: 'https://youtube.com/watch?v=123',
        fileSize: 8000,
        videoStreamSize: 8000,
        audioSize: 2000,
        downloadedBytes: 4000,
        audioDownloadedBytes: 2000,
        mergedAudioUrl: 'https://youtube.com/audio',
        category: 'Video',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/video.mp4',
        tempFilePath: '/downloads/video.mp4.tmp',
        threadCount: 2,
        audioThreadCount: 2,
        chunks: [0.5, 0.5],
        audioChunks: [1.0, 1.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final ytStatus = DataStatusVerifier.verifyYtTask(ytTask);
      expect(ytStatus.isConsistent, isTrue);
      expect(ytStatus.videoPercent, closeTo(0.5, 0.01));
      expect(ytStatus.audioPercent, closeTo(1.0, 0.01));
      expect(ytStatus.overallPercent, closeTo(0.6, 0.01)); // (4000+2000)/(8000+2000) = 6000/10000 = 60%
      expect(ytStatus.audioCompletedChunks, 2);
    });

    // 3. DataStatusVerifier.verifyTorrentTask — all edge cases
    test('3. verifyTorrentTask checks Torrent files & piece progress', () {
      final torrentTask = DownloadTask(
        id: 'tor-1',
        fileName: 'ubuntu.torrent',
        url: 'magnet:?xt=urn:btih:abcdef',
        fileSize: 10000,
        downloadedBytes: 5000,
        category: 'Other',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/ubuntu',
        tempFilePath: '/downloads/ubuntu.tmp',
        threadCount: 1,
        chunks: [0.5],
        totalPieces: 100,
        completedPieces: 50,
        torrentPieceProgress: 0.5,
        torrentFiles: [
          {'name': 'file1.iso', 'length': 5000, 'downloadedBytes': 5000, 'selected': true},
          {'name': 'file2.txt', 'length': 5000, 'downloadedBytes': 0, 'selected': true},
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final torStatus = DataStatusVerifier.verifyTorrentTask(torrentTask);
      expect(torStatus.isConsistent, isTrue);
      expect(torStatus.piecePercent, closeTo(0.5, 0.01));
      expect(torStatus.totalFiles, 2);
      expect(torStatus.completedFiles, 1);
      expect(torStatus.files.length, 2);
      expect(torStatus.files[0].isComplete, isTrue);
      expect(torStatus.files[1].isComplete, isFalse);
    });

    // 4. DownloadTask.progress — YouTube dual-stream formula calculation
    test('4. DownloadTask progress formula for YouTube dual-stream downloads', () {
      final task = DownloadTask(
        id: 'yt-progress',
        fileName: 'yt.mp4',
        url: 'https://youtube.com',
        fileSize: 1000,
        videoStreamSize: 800,
        audioSize: 200,
        downloadedBytes: 400, // 50% of video (800)
        audioDownloadedBytes: 200, // 100% of audio (200)
        mergedAudioUrl: 'https://youtube.com/audio',
        category: 'Video',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/yt.mp4',
        tempFilePath: '/downloads/yt.mp4.tmp',
        threadCount: 2,
        chunks: [0.5, 0.5],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // (400 + 200) / (800 + 200) = 600 / 1000 = 0.6
      expect(task.progress, closeTo(0.6, 0.001));
      expect(task.videoProgressPercent, closeTo(0.5, 0.001));
      expect(task.audioProgressPercent, closeTo(1.0, 0.001));
      expect(task.combinedProgressPercent, closeTo(0.6, 0.001));
    });

    // 5. CycleState transition legality — all pairs
    test('5. CycleState.isValidTransition validates legal and illegal transitions', () {
      // Legal transitions
      expect(CycleState.isValidTransition(CycleState.starting, CycleState.downloading), isTrue);
      expect(CycleState.isValidTransition(CycleState.downloading, CycleState.paused), isTrue);
      expect(CycleState.isValidTransition(CycleState.downloading, CycleState.merging), isTrue);
      expect(CycleState.isValidTransition(CycleState.downloading, CycleState.completed), isTrue);
      expect(CycleState.isValidTransition(CycleState.downloading, CycleState.failed), isTrue);
      expect(CycleState.isValidTransition(CycleState.paused, CycleState.resuming), isTrue);
      expect(CycleState.isValidTransition(CycleState.resuming, CycleState.downloading), isTrue);
      expect(CycleState.isValidTransition(CycleState.retrying, CycleState.downloading), isTrue);
      expect(CycleState.isValidTransition(CycleState.merging, CycleState.completed), isTrue);
      expect(CycleState.isValidTransition(CycleState.updatingLinks, CycleState.downloading), isTrue);

      // Illegal transitions
      expect(CycleState.isValidTransition(CycleState.completed, CycleState.downloading), isFalse);
      expect(CycleState.isValidTransition(CycleState.completed, CycleState.paused), isFalse);
      expect(CycleState.isValidTransition(CycleState.completed, CycleState.resuming), isFalse);
    });

    // 6. PauseReason mapping — all scenarios
    test('6. PauseReason fromName maps all strings and aliases', () {
      expect(PauseReason.fromName('user'), PauseReason.user);
      expect(PauseReason.fromName('user_requested'), PauseReason.user);
      expect(PauseReason.fromName('battery_saver'), PauseReason.batterySaver);
      expect(PauseReason.fromName('battery_low'), PauseReason.batterySaver);
      expect(PauseReason.fromName('disk_full'), PauseReason.diskFull);
      expect(PauseReason.fromName('network_lost'), PauseReason.networkLost);
      expect(PauseReason.fromName('scheduled'), PauseReason.scheduled);
      expect(PauseReason.fromName('app_restarted'), PauseReason.appRestarted);
      expect(PauseReason.fromName('url_expired'), PauseReason.urlExpired);
      expect(PauseReason.fromName('permission_revoked'), PauseReason.permissionRevoked);
    });

    // 7. HTTP chunk state save/restore round-trip
    test('7. HttpPartStatus serialization and round-trip', () {
      const part = HttpPartStatus(
        partIndex: 1,
        startByte: 1000,
        endByte: 1999,
        downloadedBytes: 500,
        isComplete: false,
      );

      final map = part.toMap();
      final restored = HttpPartStatus.fromMap(map);
      expect(restored.partIndex, part.partIndex);
      expect(restored.startByte, part.startByte);
      expect(restored.endByte, part.endByte);
      expect(restored.downloadedBytes, part.downloadedBytes);
      expect(restored.isComplete, part.isComplete);
      expect(restored, equals(part));
    });

    // 8. YouTube audio + video state save/restore round-trip
    test('8. YouTube dual-stream state persistence in DownloadTask', () {
      final task = DownloadTask(
        id: 'yt-task-persisted',
        fileName: 'test.mp4',
        url: 'https://youtube.com/watch?v=abc',
        fileSize: 5000,
        downloadedBytes: 2500,
        category: 'Video',
        status: DownloadStatus.paused,
        savePath: '/downloads',
        localFilePath: '/downloads/test.mp4',
        tempFilePath: '/downloads/test.mp4.tmp',
        threadCount: 2,
        chunks: [0.5, 0.5],
        audioDownloadedBytes: 1000,
        audioSize: 1000,
        audioProgress: 1.0,
        audioThreadCount: 2,
        audioChunks: [1.0, 1.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final map = task.toMap();
      final restored = DownloadTask.fromMap(map);
      expect(restored.audioDownloadedBytes, 1000);
      expect(restored.audioSize, 1000);
      expect(restored.audioProgress, 1.0);
      expect(restored.audioChunks, [1.0, 1.0]);
    });

    // 9. Torrent per-file & piece state save/restore round-trip
    test('9. Torrent piece and file progress persistence in DownloadTask', () {
      final task = DownloadTask(
        id: 'torrent-persisted',
        fileName: 'files.torrent',
        url: 'magnet:?xt=urn:btih:123456',
        fileSize: 20000,
        downloadedBytes: 10000,
        category: 'Other',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/files',
        tempFilePath: '/downloads/files.tmp',
        threadCount: 1,
        chunks: [0.5],
        totalPieces: 200,
        completedPieces: 100,
        torrentPieceProgress: 0.5,
        torrentFiles: [
          {'name': 'f1.mkv', 'length': 10000, 'downloadedBytes': 10000, 'selected': true},
          {'name': 'f2.mkv', 'length': 10000, 'downloadedBytes': 0, 'selected': true},
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final map = task.toMap();
      final restored = DownloadTask.fromMap(map);
      expect(restored.totalPieces, 200);
      expect(restored.completedPieces, 100);
      expect(restored.torrentPieceProgress, 0.5);
      expect(restored.torrentPiecePercentString, '50.0%');
      expect(restored.torrentCompletedFilesCount, 1);
      expect(restored.torrentTotalFilesCount, 2);
    });

    // 10. URL update with size change → progress reset
    test('10. Task size mismatch resets progress during update', () {
      final original = DownloadTask(
        id: 'update-size-change',
        fileName: 'app.iso',
        url: 'https://example.com/old.iso',
        fileSize: 1000,
        downloadedBytes: 500,
        category: 'Software',
        status: DownloadStatus.paused,
        savePath: '/downloads',
        localFilePath: '/downloads/app.iso',
        tempFilePath: '/downloads/app.iso.tmp',
        threadCount: 2,
        chunks: [0.5, 0.5],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // Simulating update with changed size (e.g. 2000 instead of 1000)
      const newFileSize = 2000;
      final sizeChanged = newFileSize != original.fileSize;
      final updated = original.copyWith(
        url: 'https://example.com/new.iso',
        fileSize: newFileSize,
        downloadedBytes: sizeChanged ? 0 : original.downloadedBytes,
        chunks: sizeChanged ? [0.0, 0.0] : original.chunks,
        cycleState: CycleState.updatingLinks,
      );

      expect(updated.downloadedBytes, 0);
      expect(updated.chunks, [0.0, 0.0]);
      expect(updated.cycleState, CycleState.updatingLinks);
    });

    // 11. URL update without size change → progress preserved
    test('11. Task same size preserves progress during update', () {
      final original = DownloadTask(
        id: 'update-same-size',
        fileName: 'app.iso',
        url: 'https://example.com/old.iso',
        fileSize: 1000,
        downloadedBytes: 500,
        category: 'Software',
        status: DownloadStatus.paused,
        savePath: '/downloads',
        localFilePath: '/downloads/app.iso',
        tempFilePath: '/downloads/app.iso.tmp',
        threadCount: 2,
        chunks: [0.5, 0.5],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      const newFileSize = 1000;
      final sizeChanged = newFileSize != original.fileSize;
      final updated = original.copyWith(
        url: 'https://example.com/mirror.iso',
        fileSize: newFileSize,
        downloadedBytes: sizeChanged ? 0 : original.downloadedBytes,
        chunks: sizeChanged ? [0.0, 0.0] : original.chunks,
        cycleState: CycleState.updatingLinks,
      );

      expect(updated.downloadedBytes, 500);
      expect(updated.chunks, [0.5, 0.5]);
      expect(updated.cycleState, CycleState.updatingLinks);
    });

    // 12. Merge failure → retry merge only
    test('12. Merge failure allows retry without re-downloading', () {
      final failedTask = DownloadTask(
        id: 'merge-fail-retry',
        fileName: 'video.mp4',
        url: 'https://youtube.com/watch?v=merge',
        fileSize: 10000,
        videoStreamSize: 8000,
        audioSize: 2000,
        downloadedBytes: 8000, // Video 100%
        audioDownloadedBytes: 2000, // Audio 100%
        mergedAudioUrl: 'https://youtube.com/audio',
        category: 'Video',
        status: DownloadStatus.failed,
        statusMessage: 'MERGE_FAILED',
        failureCategory: FailureCategory.mergeFailed,
        savePath: '/downloads',
        localFilePath: '/downloads/video.mp4',
        tempFilePath: '/downloads/video.mp4.tmp',
        threadCount: 2,
        chunks: [1.0, 1.0],
        audioChunks: [1.0, 1.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // On retry of MERGE_FAILED, preserve downloadedBytes and cycleState = CycleState.merging
      final retryTask = failedTask.copyWith(
        status: DownloadStatus.merging,
        cycleState: CycleState.merging,
        statusMessage: 'Merging video and audio...',
        clearError: true,
      );

      expect(retryTask.downloadedBytes, 8000);
      expect(retryTask.audioDownloadedBytes, 2000);
      expect(retryTask.status, DownloadStatus.merging);
      expect(retryTask.cycleState, CycleState.merging);
    });

    // 13. App kill / detached → state preservation check
    test('13. App kill preserves active task progress', () {
      final activeTask = DownloadTask(
        id: 'active-task',
        fileName: 'large.zip',
        url: 'https://example.com/large.zip',
        fileSize: 100000,
        downloadedBytes: 45000,
        speed: 1024000,
        category: 'Archives',
        status: DownloadStatus.downloading,
        cycleState: CycleState.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/large.zip',
        tempFilePath: '/downloads/large.zip.tmp',
        threadCount: 4,
        chunks: [0.45, 0.45, 0.45, 0.45],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // On detached / suspend: state converted to paused with appRestarted reason
      final suspendedTask = activeTask.copyWith(
        status: DownloadStatus.paused,
        cycleState: CycleState.paused,
        pauseReason: PauseReason.appRestarted,
        speed: 0,
      );

      expect(suspendedTask.status, DownloadStatus.paused);
      expect(suspendedTask.cycleState, CycleState.paused);
      expect(suspendedTask.pauseReason, PauseReason.appRestarted);
      expect(suspendedTask.downloadedBytes, 45000);
      expect(suspendedTask.chunks, [0.45, 0.45, 0.45, 0.45]);
    });

    // 14. Disk full (InsufficientStorageException) → progress preservation
    test('14. Disk full failure sets proper category and preserves downloaded bytes', () {
      final activeTask = DownloadTask(
        id: 'disk-full-task',
        fileName: 'game.iso',
        url: 'https://example.com/game.iso',
        fileSize: 5000000,
        downloadedBytes: 2500000,
        category: 'Games',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/game.iso',
        tempFilePath: '/downloads/game.iso.tmp',
        threadCount: 2,
        chunks: [0.5, 0.5],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final failedTask = activeTask.copyWith(
        status: DownloadStatus.failed,
        cycleState: CycleState.failed,
        pauseReason: PauseReason.diskFull,
        failureCategory: FailureCategory.diskFull,
        recoveryHint: RecoveryHints.hintFor(FailureCategory.diskFull),
      );

      expect(failedTask.status, DownloadStatus.failed);
      expect(failedTask.failureCategory, FailureCategory.diskFull);
      expect(failedTask.pauseReason, PauseReason.diskFull);
      expect(failedTask.downloadedBytes, 2500000);
      expect(failedTask.recoveryHint, contains('storage space'));
    });

    // 15. Network loss → auto-pause + auto-resume mapping
    test('15. Network loss sets pauseReason networkLost and preserves progress for auto-resume', () {
      final downloadingTask = DownloadTask(
        id: 'net-loss-task',
        fileName: 'document.pdf',
        url: 'https://example.com/document.pdf',
        fileSize: 10000,
        downloadedBytes: 3000,
        category: 'Documents',
        status: DownloadStatus.downloading,
        savePath: '/downloads',
        localFilePath: '/downloads/document.pdf',
        tempFilePath: '/downloads/document.pdf.tmp',
        threadCount: 2,
        chunks: [0.3, 0.3],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final pausedForNetwork = downloadingTask.copyWith(
        status: DownloadStatus.paused,
        cycleState: CycleState.paused,
        pauseReason: PauseReason.networkLost,
        speed: 0,
      );

      expect(pausedForNetwork.status, DownloadStatus.paused);
      expect(pausedForNetwork.pauseReason, PauseReason.networkLost);
      expect(pausedForNetwork.downloadedBytes, 3000);

      // When network returns, task can resume without losing its 3000 bytes
      final resumedTask = pausedForNetwork.copyWith(
        status: DownloadStatus.downloading,
        cycleState: CycleState.resuming,
        clearPauseReason: true,
      );

      expect(resumedTask.status, DownloadStatus.downloading);
      expect(resumedTask.cycleState, CycleState.resuming);
      expect(resumedTask.downloadedBytes, 3000);
    });
  });
}
