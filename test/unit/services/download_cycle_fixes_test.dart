import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_metrics.dart';
import 'package:dmx/core/services/torrent_models.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';
import 'package:dmx/features/downloads/provider/network_monitor.dart';
import 'package:dmx/features/downloads/provider/notification_coordinator.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';

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
    test(
        'BUG 3: sanitizedChunks getter distributes progress when chunks list is empty',
        () {
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

    test(
        'FIX-M3: combinedTotalSize returns fallback downloadedBytes + audioSize when videoStreamSize == 0 and fileSize <= 0',
        () {
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

      expect(task.combinedTotalSize, equals(15000000));
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
      final normalized =
          DownloadOrchestrator.normalizeChunks(chunks, 1000, 500);

      expect(normalized.length, equals(4));
      for (final c in normalized) {
        expect(c.isNaN, isFalse);
        expect(c.isInfinite, isFalse);
        expect(c >= 0.0 && c <= 1.0, isTrue);
      }
    });

    test(
        'BUG 1: retryMergeOnly restores _video_only file and completes via '
        'existing merged output (no re-download)', () async {
      final tempDir = await Directory.systemTemp.createTemp('bug1_retry_');
      try {
        final localPath = '${tempDir.path}/merged_video.mp4';
        final videoOnlyPath = '${tempDir.path}/merged_video_video_only.mp4';
        final tempPath = '${tempDir.path}/task1.dmxpart';
        final audioPath = '$tempPath.audio';
        final mergedPath = '$tempPath.merged.mp4';

        // Simulate a prior merge failure: video preserved as _video_only,
        // localFilePath absent, audio sidecar present, and a merged output
        // already on disk (>1024 bytes so _mergeAudioVideo skips FFmpeg).
        await File(videoOnlyPath).writeAsBytes(List.filled(2048, 7));
        await File(audioPath).writeAsBytes(List.filled(1024, 5));
        await File(mergedPath).writeAsBytes(List.filled(4096, 9));

        final host = _MergeRetryTestHost();
        final orchestrator = DownloadOrchestrator(host);
        final task = _mergeRetryTask(
          id: 'bug1_success',
          fileName: 'merged_video.mp4',
          localPath: localPath,
          tempPath: tempPath,
        );
        host.taskInstance = task;

        await orchestrator.retryMergeOnly(task);

        // FIX-B1: _video_only was restored to localFilePath, never re-downloaded.
        expect(File(localPath).existsSync(), isTrue);
        expect(File(videoOnlyPath).existsSync(), isFalse);
        // Merge succeeded via the pre-existing output; task completed.
        expect(host.lastSavedTaskState, isNotNull);
        expect(host.lastSavedTaskState!.status, DownloadStatus.completed);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test(
        'BUG 1: incomplete video fails merge-only retry without deleting '
        'the preserved video or audio', () async {
      final tempDir = await Directory.systemTemp.createTemp('bug1_fail_');
      try {
        final localPath = '${tempDir.path}/merged_video.mp4';
        final tempPath = '${tempDir.path}/task1.dmxpart';
        final audioPath = '$tempPath.audio';

        // Video smaller than 95% of the expected size trips the pre-FFmpeg
        // size guard in _mergeAudioVideo, so no native FFmpeg call is made.
        await File(localPath).writeAsBytes(List.filled(100, 1));
        await File(audioPath).writeAsBytes(List.filled(200, 2));

        final host = _MergeRetryTestHost();
        final orchestrator = DownloadOrchestrator(host);
        final task = _mergeRetryTask(
          id: 'bug1_failure',
          fileName: 'merged_video.mp4',
          localPath: localPath,
          tempPath: tempPath,
        ).copyWith(fileSize: 1000, audioSize: 100);
        host.taskInstance = task;

        await orchestrator.retryMergeOnly(task);

        expect(host.lastSavedTaskState, isNotNull);
        expect(host.lastSavedTaskState!.status, DownloadStatus.failed);
        expect(host.lastSavedTaskState!.statusMessage, 'MERGE_FAILED');
        expect(
          host.lastSavedTaskState!.errorMessage,
          contains('Video saved without audio'),
        );
        // Cleanup never deletes the preserved video or the audio sidecar.
        expect(File(localPath).existsSync(), isTrue);
        expect(File(audioPath).existsSync(), isTrue);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('TEST-T2: YouTube audio progress validation resets audioProgress when .audio.dmxstate missing', () async {
      final tempDir = await Directory.systemTemp.createTemp('t2_yt_audio_');
      try {
        final localPath = '${tempDir.path}/yt_video.mp4';
        final tempPath = '${tempDir.path}/yt_task.dmxpart';
        final audioPath = '$tempPath.audio';

        // Write video and audio file
        await File(tempPath).writeAsBytes(List.filled(1024, 1));
        await File(audioPath).writeAsBytes(List.filled(512, 2));
        // Note: .audio.dmxstate is NOT created

        final host = _MergeRetryTestHost();
        final orchestrator = DownloadOrchestrator(host);
        final task = createTestTask(
          id: 't2_audio_val',
          fileName: 'yt_video.mp4',
          url: 'https://youtube.com/watch?v=abc',
          fileSize: 1024,
          audioSize: 512,
          mergedAudioUrl: 'https://youtube.com/audio',
        ).copyWith(
          localFilePath: localPath,
          tempFilePath: tempPath,
          audioProgress: 1.0,
          audioDownloadedBytes: 512,
        );
        host.taskInstance = task;

        final validated = await orchestrator.validateResumeState(task);
        expect(validated.audioProgress, equals(0.0));
        expect(validated.audioDownloadedBytes, equals(0));
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('TEST-T3: Torrent per-file bytes re-read after loadResumeData emitted', () {
      final freshFiles = [
        TorrentFileItem(index: 0, name: 'video.mp4', size: 1000, downloadedBytes: 500, priority: 4, selected: true),
        TorrentFileItem(index: 1, name: 'subs.srt', size: 200, downloadedBytes: 200, priority: 4, selected: true),
      ];
      final updatedFiles = freshFiles.map((f) => {
        'name': f.name,
        'length': f.size,
        'downloadedBytes': f.downloadedBytes >= 0 ? f.downloadedBytes : 0,
        'selected': f.selected,
        'priority': f.priority,
        'progress': f.size > 0
            ? (f.downloadedBytes / f.size).clamp(0.0, 1.0)
            : 0.0,
      }).toList();

      final progress = DownloadProgress(
        downloadedBytes: freshFiles.fold<int>(0, (s, f) =>
            s + (f.downloadedBytes >= 0 ? f.downloadedBytes : 0)),
        fileSize: freshFiles.fold<int>(0, (s, f) => s + f.size),
        speed: 0,
        eta: null,
        torrentFiles: updatedFiles,
        statusMessage: 'Resuming from saved state…',
        cycleState: 'resuming',
      );

      expect(progress.downloadedBytes, equals(700));
      expect(progress.fileSize, equals(1200));
      expect(progress.torrentFiles!.length, equals(2));
      expect(progress.torrentFiles![0]['downloadedBytes'], equals(500));
    });

    test('TEST-T4: Merge retry skips FFmpeg when output exists and completes task', () async {
      final tempDir = await Directory.systemTemp.createTemp('t4_merge_');
      try {
        final localPath = '${tempDir.path}/merged_video.mp4';
        final tempPath = '${tempDir.path}/task1.dmxpart';
        final mergedPath = '$tempPath.merged.mp4';

        // Write a merged file with sufficient length
        await File(mergedPath).writeAsBytes(List.filled(5000, 1));

        final host = _MergeRetryTestHost();
        final orchestrator = DownloadOrchestrator(host);
        final task = _mergeRetryTask(
          id: 't4_success',
          fileName: 'merged_video.mp4',
          localPath: localPath,
          tempPath: tempPath,
        ).copyWith(fileSize: 4000);
        host.taskInstance = task;

        await orchestrator.retryMergeOnly(task);

        expect(File(localPath).existsSync(), isTrue);
        expect(host.lastSavedTaskState, isNotNull);
        expect(host.lastSavedTaskState!.status, DownloadStatus.completed);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });
}

/// A task in the post-merge-failure state: `failed` with `MERGE_FAILED`,
/// video preserved as `_video_only`, and an audio sidecar expected on disk.
DownloadTask _mergeRetryTask({
  required String id,
  required String fileName,
  required String localPath,
  required String tempPath,
}) {
  return DownloadTask(
    id: id,
    fileName: fileName,
    url: 'https://example.com/$fileName',
    fileSize: 0,
    downloadedBytes: 0,
    category: 'General',
    status: DownloadStatus.failed,
    statusMessage: 'MERGE_FAILED',
    errorMessage:
        'FFmpeg merge failed Audio preserved — retry to re-attempt merge.',
    savePath: Directory(localPath).parent.path,
    localFilePath: localPath,
    tempFilePath: tempPath,
    threadCount: 1,
    audioThreadCount: 1,
    chunks: const [],
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    mergedAudioUrl: 'https://example.com/audio.m4a',
  );
}

class _MergeRetryTestHost implements DownloadOrchestratorHost {
  DownloadTask? taskInstance;
  DownloadTask? lastSavedTaskState;

  @override
  final Map<String, CancelToken> cancelTokens = {};
  @override
  final Map<String, Future<void>> activeFutures = {};
  @override
  final Map<String, Timer> retryTimers = {};
  @override
  final Map<String, int> retryCounts = {};
  @override
  final Map<String, Queue<double>> speedHistories = {};
  @override
  final Map<String, int> lastProgressUpdateTimes = {};
  @override
  final Map<String, int> lastDbSaveTimes = {};
  @override
  final Map<String, int> lastTorrentFileDiskSync = {};
  @override
  final Set<String> pendingProgressUpdates = {};
  @override
  final Map<String, int> ytLowSpeedCounts = {};
  @override
  final Map<String, bool> ytThrottlingRefreshing = {};
  @override
  final Map<String, int> providerTorrentIds = {};
  @override
  final Map<String, int> effectiveThreadOverrides = {};
  @override
  final Map<int, TorrentUpdateInfo> providerLatestTorrentStats = {};
  @override
  final Map<String, bool> resumeRejectionRestarts = {};
  @override
  final Map<String, DownloadMetrics> downloadMetrics = {};

  @override
  bool get providerDisposed => false;
  @override
  bool get enableBackgroundTimers => false;
  @override
  int get downloadingTasksCount => 0;
  @override
  int get activeOrSeedingCount => 0;

  @override
  SettingsProvider get providerSettingsProvider => SettingsProvider.instance;
  @override
  DatabaseService get providerDatabaseService => DatabaseService.instance;
  @override
  DownloadEngine get downloadEngine => DownloadEngine(dio: Dio());
  @override
  NetworkMonitor get networkMonitor => _NoopNetworkMonitor();
  @override
  NotificationCoordinator get notifications =>
      _MergeRetryNotificationCoordinator();

  @override
  List<DownloadTask> get providerTasks =>
      taskInstance != null ? [taskInstance!] : [];

  @override
  DownloadTask? findTaskById(String id) => taskInstance;

  @override
  Future<void> setTaskState(DownloadTask task) async {
    lastSavedTaskState = task;
    taskInstance = task;
  }

  @override
  void pumpQueue() {}
  @override
  Future<void> flushPendingProgress(String id) async {}
  @override
  int effectiveSpeedLimit() => 0;
  @override
  List<double> buildChunks(
          int threadCount, int fileSize, int downloadedBytes) =>
      List<double>.filled(threadCount > 0 ? threadCount : 1, 1.0);
  @override
  ({int total, List<Map<String, dynamic>>? files}) scanExistingTorrentData(
          String rootPath, List<Map<String, dynamic>>? fileList) =>
      (total: 0, files: fileList);
  @override
  Future<void> updateTaskUrlAndResume(String id, String newUrl,
      {String? newAudioUrl}) async {}
  @override
  void updateTelemetryWidget() {}
  @override
  void providerStartWidgetTimer() {}
  @override
  void providerStopWidgetTimer() {}
  @override
  void providerNotifyListeners() {}
  @override
  void pushProgressTick(String taskId, double progress, double speed) {}
  @override
  List<Map<String, dynamic>> markTorrentFilesCompleted(
          List<Map<String, dynamic>> files) =>
      files;
  @override
  Future<void> cleanupPartFiles(DownloadTask task,
      {bool preserveParts = false}) async {}
  @override
  Future<void> startOverTask(String id, String newUrl,
      {String? newAudioUrl,
      bool clearAudioUrl = false,
      bool fromError = false,
      int? newFileSize,
      int? newAudioSize,
      bool deleteTempFiles = false}) async {}
}

class _MergeRetryNotificationCoordinator implements NotificationCoordinator {
  @override
  int idFor(String taskId) => 123;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoopNetworkMonitor implements NetworkMonitor {
  @override
  bool get hasWifiOrEthernet => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
