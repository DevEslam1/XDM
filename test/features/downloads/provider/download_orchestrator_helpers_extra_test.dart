import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_metrics.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';
import 'package:dmx/features/downloads/provider/network_monitor.dart';
import 'package:dmx/features/downloads/provider/notification_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Recording host that satisfies [DownloadOrchestratorHost] and tracks the
/// provider callbacks the extra helper tests care about.
class _RecordingHost implements DownloadOrchestratorHost {
  final Map<String, DownloadTask> tasks = {};
  final List<DownloadTask> saved = [];
  final List<String> flushed = [];
  bool disposed = false;
  int notifyCount = 0;
  int pumpCount = 0;

  @override
  final Map<String, int> retryCounts = {};
  @override
  final Map<String, Timer> retryTimers = {};
  @override
  final Map<String, CancelToken> cancelTokens = {};
  @override
  final Map<String, ({CancelToken video, CancelToken audio})>
      orchestratorTokens = {};
  @override
  final Map<String, Future<void>> activeFutures = {};
  @override
  final Map<String, Queue<double>> speedHistories = {};
  @override
  final Map<String, int> lastProgressUpdateTimes = {};
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
  bool get providerDisposed => disposed;
  @override
  bool get enableBackgroundTimers => false;
  @override
  int get downloadingTasksCount => 0;
  @override
  int get activeOrSeedingCount => 0;

  @override
  NotificationCoordinator get notifications => _FakeNotifications();
  @override
  NetworkMonitor get networkMonitor => _FakeNetworkMonitor();

  @override
  List<DownloadTask> get providerTasks => tasks.values.toList();
  @override
  DownloadTask? findTaskById(String id) => tasks[id];

  @override
  Future<void> setTaskState(DownloadTask task) async {
    saved.add(task);
    tasks[task.id] = task;
  }

  @override
  void providerNotifyListeners() => notifyCount++;
  @override
  void pumpQueue() => pumpCount++;
  @override
  void updateProgressTask(DownloadTask updated) => tasks[updated.id] = updated;

  @override
  Future<void> flushPendingProgress(String id) async {
    if (pendingProgressUpdates.remove(id)) flushed.add(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeNotifications implements NotificationCoordinator {
  @override
  int idFor(String taskId) => 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeNetworkMonitor implements NetworkMonitor {
  @override
  bool get hasWifiOrEthernet => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

DownloadTask _task(
  String id, {
  DownloadStatus status = DownloadStatus.queued,
  String? url,
  int fileSize = 1000,
  int downloadedBytes = 0,
  String tempFilePath = '',
  String savePath = '',
  String localFilePath = '',
  int audioSize = 0,
  List<Map<String, dynamic>>? torrentFiles,
}) {
  final now = DateTime(2026, 1, 1);
  return DownloadTask(
    id: id,
    fileName: '$id.zip',
    url: url ?? 'https://example.com/$id.zip',
    fileSize: fileSize,
    downloadedBytes: downloadedBytes,
    category: 'Other',
    status: status,
    savePath: savePath,
    localFilePath: localFilePath.isEmpty ? '/d/$id.zip' : localFilePath,
    tempFilePath: tempFilePath,
    threadCount: 2,
    chunks: const [0.0, 0.0],
    createdAt: now,
    updatedAt: now,
    torrentFiles: torrentFiles,
    audioSize: audioSize,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingHost host;
  late DownloadOrchestrator orch;

  setUp(() {
    DownloadEngine.appInForeground = true;
    PowerMonitor.screenOff = false;
    host = _RecordingHost();
    orch = DownloadOrchestrator(host);
  });

  tearDown(() {
    orch.dispose();
    DownloadEngine.appInForeground = true;
    PowerMonitor.screenOff = false;
  });

  group('cleanupTaskState', () {
    test('clears every per-task map and releases the retry timer', () {
      host.tasks['a'] = _task('a', tempFilePath: '/tmp/a.dmxpart');
      final timer = Timer(const Duration(minutes: 5), () {});
      host.retryTimers['a'] = timer;
      host.retryCounts['a'] = 3;
      host.speedHistories['a'] = Queue<double>();
      host.lastProgressUpdateTimes['a'] = 1;
      host.lastTorrentFileDiskSync['a'] = 1;
      host.pendingProgressUpdates.add('a');
      host.ytLowSpeedCounts['a'] = 1;
      host.ytThrottlingRefreshing['a'] = true;

      orch.cleanupTaskState('a');

      expect(host.retryTimers.containsKey('a'), isFalse);
      expect(host.retryCounts.containsKey('a'), isFalse);
      expect(host.speedHistories.containsKey('a'), isFalse);
      expect(host.lastProgressUpdateTimes.containsKey('a'), isFalse);
      expect(host.lastTorrentFileDiskSync.containsKey('a'), isFalse);
      expect(host.pendingProgressUpdates.contains('a'), isFalse);
      expect(host.ytLowSpeedCounts.containsKey('a'), isFalse);
      expect(host.ytThrottlingRefreshing.containsKey('a'), isFalse);
      timer.cancel();
    });

    test('is safe for unknown task ids', () {
      expect(() => orch.cleanupTaskState('missing'), returnsNormally);
    });
  });

  group('clear helpers', () {
    test('clearStartingFlag releases a pending-start marker', () {
      host.tasks['a'] = _task('a', status: DownloadStatus.queued);
      expect(orch.startTask(host.tasks['a']!), isTrue);
      expect(orch.isTaskPendingStart('a'), isTrue);

      orch.clearStartingFlag('a');
      expect(orch.isTaskPendingStart('a'), isFalse);
    });

    test('clearPushScheduled and clearSessionCachedTotalSize are safe', () {
      expect(() => orch.clearPushScheduled('a'), returnsNormally);
      expect(() => orch.clearSessionCachedTotalSize('a'), returnsNormally);
    });
  });

  group('onProgressTick', () {
    test('notifies listeners when pending work exists', () {
      host.pendingProgressUpdates.add('a');
      orch.onProgressTick();
      expect(host.notifyCount, 1);
    });

    test('does nothing when no work is pending', () {
      orch.onProgressTick();
      expect(host.notifyCount, 0);
    });

    test('skips the notify while backgrounded or disabled', () {
      host.pendingProgressUpdates.add('a');
      DownloadEngine.appInForeground = false;
      orch.onProgressTick();
      expect(host.notifyCount, 0);
    });

    test('skips the notify when the provider is disposed', () {
      host.pendingProgressUpdates.add('a');
      host.disposed = true;
      orch.onProgressTick();
      expect(host.notifyCount, 0);
    });
  });

  group('startTask', () {
    test('returns false when the task already has a cancel token', () {
      host.tasks['a'] = _task('a');
      host.cancelTokens['a'] = CancelToken();
      expect(orch.startTask(host.tasks['a']!), isFalse);
    });

    test('returns false when the task is already starting', () {
      host.tasks['a'] = _task('a', status: DownloadStatus.queued);
      expect(orch.startTask(host.tasks['a']!), isTrue);
      expect(orch.startTask(host.tasks['a']!), isFalse);
    });

    test('discards starts for tasks that vanished before execution', () async {
      final ghost = _task('ghost', status: DownloadStatus.queued);
      expect(orch.startTask(ghost), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(orch.isTaskPendingStart('ghost'), isFalse);
      expect(host.pumpCount, greaterThan(0));
    });
  });

  group('validateResumeState', () {
    test('dropped temp file resets phantom progress for an HTTP task',
        () async {
      final dir = Directory.systemTemp.createTempSync('dmx_orch_extra_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final temp = '${dir.path}/ghost.dmxpart';
      final task = _task(
        'h2',
        status: DownloadStatus.paused,
        downloadedBytes: 500,
        tempFilePath: temp,
        fileSize: 1000,
      );
      final result = await orch.validateResumeState(task);
      expect(result.downloadedBytes, 0);
    });

    test('torrent with a valid save directory is returned', () async {
      final dir = Directory.systemTemp.createTempSync('dmx_orch_extra_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final task = _task(
        't-ok',
        status: DownloadStatus.paused,
        url: 'magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709',
        savePath: dir.path,
        torrentFiles: [
          {'name': 'a.bin', 'length': 10},
        ],
      );
      final result = await orch.validateResumeState(task);
      expect(result.id, 't-ok');
      expect(result.torrentFiles, isNotEmpty);
    });
  });

  group('retryMergeOnly', () {
    test('fails when the video and audio parts are missing', () async {
      final dir = Directory.systemTemp.createTempSync('dmx_orch_merge_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final task = _task(
        'm1',
        status: DownloadStatus.failed,
        tempFilePath: '${dir.path}/v.dmxpart',
        localFilePath: '${dir.path}/v.mp4',
      );
      await orch.retryMergeOnly(task);
      expect(host.saved, isNotEmpty);
      final saved = host.saved.last;
      expect(saved.status, DownloadStatus.failed);
      expect(saved.statusMessage, 'MERGE_FAILED');
      expect(saved.errorMessage, contains('Missing video file'));
    });

    test('fails when the audio part is truncated', () async {
      final dir = Directory.systemTemp.createTempSync('dmx_orch_merge_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final temp = '${dir.path}/v.dmxpart';
      File(temp).writeAsBytesSync(List.filled(100, 1));
      File('$temp.audio').writeAsBytesSync(List.filled(10, 1));
      final task = _task(
        'm2',
        status: DownloadStatus.failed,
        tempFilePath: temp,
        localFilePath: '${dir.path}/v.mp4',
        audioSize: 1000,
      );
      await orch.retryMergeOnly(task);
      final saved = host.saved.last;
      expect(saved.status, DownloadStatus.failed);
      expect(saved.errorMessage, contains('Audio file is incomplete'));
    });
  });

  group('cleanup artifacts', () {
    test('cleanupTorrentArtifacts is a no-op without a temp path', () async {
      final task = _task('t-empty', tempFilePath: '');
      await expectLater(orch.cleanupTorrentArtifacts(task), completes);
    });

    test('cleanupAllArtifacts preserves HTTP parts when asked', () async {
      final dir = Directory.systemTemp.createTempSync('dmx_orch_clean_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final temp = '${dir.path}/f.dmxpart';
      File(temp).writeAsStringSync('x');
      File('$temp.journal').writeAsStringSync('j');
      final task = _task('h3', tempFilePath: temp);
      await orch.cleanupAllArtifacts(task, preserveParts: true);
      expect(File(temp).existsSync(), isTrue);
      expect(File('$temp.journal').existsSync(), isFalse);
    });
  });

  group('cancelReasonOf', () {
    test('reads the reason from the cancel token cancelError', () {
      final token = CancelToken();
      token.cancel('network_lost');
      expect(
        DownloadOrchestrator.cancelReasonOf(Exception('ignored'), token),
        'network_lost',
      );
    });

    test('returns null when the token has no cancel error', () {
      expect(
        DownloadOrchestrator.cancelReasonOf(
          Exception('ignored'),
          CancelToken(),
        ),
        isNull,
      );
    });
  });
}
