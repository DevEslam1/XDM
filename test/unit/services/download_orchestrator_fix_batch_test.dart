import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:dio/dio.dart';
import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_metrics.dart';
import 'package:dmx/core/services/permission_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/downloads/provider/network_monitor.dart';
import 'package:dmx/features/downloads/provider/notification_coordinator.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression tests for the orchestrator/provider fix batch (BUG1–BUG10).
///
/// Unit-level tests use a recording [DownloadOrchestratorHost]; lifecycle
/// tests drive the real [DownloadProvider] against a scripted engine so the
/// retry / failover / pause machinery is exercised end-to-end.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ────────────────────────────────────────────────────────────────────────
  // Unit-level tests (recording host)
  // ────────────────────────────────────────────────────────────────────────
  group('orchestrator fix batch — unit', () {
    DownloadTask taskOf(
      String id,
      DownloadStatus status, {
      int downloadedBytes = 0,
      List<String>? mirrorUrls,
      String url = 'https://example.com/file.zip',
    }) {
      final now = DateTime.now();
      return DownloadTask(
        id: id,
        fileName: '$id.zip',
        url: url,
        fileSize: 1000,
        downloadedBytes: downloadedBytes,
        category: 'General',
        status: status,
        savePath: '/downloads',
        localFilePath: '/downloads/$id.zip',
        tempFilePath: '/downloads/$id.zip.dmxpart',
        threadCount: 1,
        chunks: const [],
        createdAt: now,
        updatedAt: now,
        mirrorUrls: mirrorUrls,
      );
    }

    test('BUG1: a scheduled resolution retry keeps the task queued', () async {
      final host = _RecordingHost();
      host.tasks['t1'] = taskOf('t1', DownloadStatus.queued);
      // A retry timer is pending (as _resolveStreamUrl schedules before
      // returning null on the retry path).
      host.retryTimers['t1'] = Timer(const Duration(seconds: 30), () {});
      final orch = DownloadOrchestrator(host);

      await orch.failTaskIfNoRetryScheduled('t1');

      expect(host.tasks['t1']!.status, DownloadStatus.queued,
          reason: 'the auto-retry must not be overwritten with failed');
      expect(host.savedTasks, isEmpty);
      host.retryTimers['t1']!.cancel();
    });

    test('BUG1: a queued task with no retry timer is failed', () async {
      final host = _RecordingHost();
      host.tasks['t2'] = taskOf('t2', DownloadStatus.queued);
      final orch = DownloadOrchestrator(host);

      await orch.failTaskIfNoRetryScheduled('t2');

      expect(host.tasks['t2']!.status, DownloadStatus.failed);
      expect(host.tasks['t2']!.errorMessage,
          'Failed to resolve download stream.');
    });

    test('BUG1: non-queued tasks are left untouched', () async {
      final host = _RecordingHost();
      host.tasks['t3'] = taskOf('t3', DownloadStatus.failed);
      final orch = DownloadOrchestrator(host);

      await orch.failTaskIfNoRetryScheduled('t3');

      expect(host.savedTasks, isEmpty);
    });

    test(
        'BUG6: flushPendingProgressToDatabase flushes downloading tasks and '
        'drops stale non-downloading entries', () async {
      final host = _RecordingHost();
      host.tasks['t6'] = taskOf('t6', DownloadStatus.downloading,
          downloadedBytes: 500);
      host.tasks['t6b'] = taskOf('t6b', DownloadStatus.paused);
      host.pendingProgressUpdates.addAll(['t6', 't6b']);
      final orch = DownloadOrchestrator(host);

      await orch.flushPendingProgressToDatabase();

      expect(host.flushedIds, ['t6']);
      expect(host.pendingProgressUpdates.contains('t6'), isFalse,
          reason: 'flushPendingProgress consumed the entry');
      expect(host.pendingProgressUpdates.contains('t6b'), isFalse,
          reason: 'stale entries for non-downloading tasks are dropped');
      expect(host.flushedIds.contains('t6b'), isFalse);
    });

    test('BUG7: retry backoff doubles per attempt and caps at 5 minutes', () {
      expect(DownloadOrchestrator.retryBackoffSeconds(3, 0), 3);
      expect(DownloadOrchestrator.retryBackoffSeconds(3, 1), 6);
      expect(DownloadOrchestrator.retryBackoffSeconds(3, 2), 12);
      expect(DownloadOrchestrator.retryBackoffSeconds(3, 4), 48);
      expect(DownloadOrchestrator.retryBackoffSeconds(3, 12), 300,
          reason: 'hard cap at 300s');
      expect(DownloadOrchestrator.retryBackoffSeconds(60, 8), 300,
          reason: 'hard cap at 300s');
      expect(DownloadOrchestrator.retryBackoffSeconds(0, 3), 0);
    });

    test('BUG7: disk / permission / expired-link errors are not retryable',
        () {
      final orch = DownloadOrchestrator(_RecordingHost());
      // Disk full (errno 28).
      const diskFull = FileSystemException(
          'Write failed', '/tmp/f', OSError('No space left on device', 28));
      expect(orch.isRetryableError(diskFull), isFalse);
      expect(orch.isRetryableError(const InsufficientStorageException()),
          isFalse);
      expect(orch.isRetryableError(const UrlExpiredException('410 Gone')),
          isFalse);
      expect(
          orch.isRetryableError(Exception('Access is denied. (errno = 13)')),
          isFalse);
      // Network / timeout / 5xx stay retryable.
      expect(
          orch.isRetryableError(DioException(
            requestOptions: RequestOptions(path: '/'),
            type: DioExceptionType.connectionError,
          )),
          isTrue);
      expect(
          orch.isRetryableError(DioException(
            requestOptions: RequestOptions(path: '/'),
            type: DioExceptionType.badResponse,
            response: Response(
                requestOptions: RequestOptions(path: '/'), statusCode: 503),
          )),
          isTrue);
    });

    test('BUG10: cancel reasons map to the right pause outcome', () {
      // User pause.
      final user = DownloadOrchestrator.cancelPauseOutcome('paused:user');
      expect(user.isUserPause, isTrue);
      expect(user.waitingMessage, isNull);
      // Network-driven cancels stay auto-resumable.
      final netLost = DownloadOrchestrator.cancelPauseOutcome('network_lost');
      expect(netLost.isUserPause, isFalse);
      expect(netLost.waitingMessage, DownloadStatusMessages.waitingNetwork);
      final wifiOnly =
          DownloadOrchestrator.cancelPauseOutcome('wifi_only_pause');
      expect(wifiOnly.isUserPause, isFalse);
      expect(wifiOnly.waitingMessage, DownloadStatusMessages.waitingWifi);
      // Unknown / unrelated reasons never become user pauses.
      final unknown = DownloadOrchestrator.cancelPauseOutcome(null);
      expect(unknown.isUserPause, isFalse);
      // An already user-paused task keeps its user pause regardless of the
      // cancel reason.
      final already =
          DownloadOrchestrator.cancelPauseOutcome('network_lost',
              alreadyUserPaused: true);
      expect(already.isUserPause, isTrue);
    });

    test('BUG10: cancel reason is extracted from the cancel error', () {
      final token = CancelToken();
      final err = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.cancel,
        error: 'network_lost',
      );
      expect(DownloadOrchestrator.cancelReasonOf(err, token), 'network_lost');
      expect(
          DownloadOrchestrator.cancelReasonOf(
              const InsufficientStorageException(), token),
          isNull);
    });

    test('BUG8: resolution-phase retries use a separate counter', () async {
      final host = _RecordingHost();
      host.tasks['t8'] = taskOf('t8', DownloadStatus.queued);
      final orch = DownloadOrchestrator(host);
      // BUG8 removes the resolution counter when a start attempt ends —
      // verify the helper does not consume the shared download-phase budget.
      await orch.failTaskIfNoRetryScheduled('t8');
      expect(host.retryCounts['t8'], isNull);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // Lifecycle tests (real provider + scripted engine)
  // ────────────────────────────────────────────────────────────────────────
  group('orchestrator fix batch — lifecycle', () {
    late DatabaseService database;
    late SettingsProvider settings;
    late _ScriptedEngine engine;
    late DownloadProvider provider;

    setUpAll(() {
      drift.driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      Hive.init('build/test_hive_orch_fix_batch');
      ConnectivityPlatform.instance = _MockConnectivityPlatform();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.example.dmx/widget'),
        (methodCall) async => null,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (methodCall) async => null,
      );
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      if (!Hive.isBoxOpen(DatabaseService.downloadsBoxName)) {
        await Hive.openBox<dynamic>(DatabaseService.downloadsBoxName);
      }
      await Hive.box<dynamic>(DatabaseService.downloadsBoxName).clear();
      database = DatabaseService.forSubclass();
      await database.init(testPath: 'build/test_hive_orch_fix_batch');
      settings = SettingsProvider();
      await settings.load();
      settings.autoStart = false;
      settings.retryDelaySeconds = 1;
      engine = _ScriptedEngine();
      provider = DownloadProvider(
        databaseService: database,
        settingsProvider: settings,
        downloadEngine: engine,
        permissionService: _FakePermissionService(),
      );
    });

    tearDown(() async {
      provider.dispose();
      if (Hive.isBoxOpen(DatabaseService.downloadsBoxName)) {
        await Hive.box<dynamic>(DatabaseService.downloadsBoxName).clear();
      }
    });

    test('BUG1/BUG7: transient failure keeps the task queued and the retry '
        'timer fires it back into the queue', () async {
      engine.enqueueThrow(_transientError());
      engine.enqueueSuccess();
      final id = (await provider.addDownload(
        url: 'https://example.com/bug1.zip',
        name: 'bug1.zip',
      ))!;

      await _waitUntil(() => engine.startedUrls.isNotEmpty,
          what: 'first engine start');
      // The failure path must park the task in `queued` behind a retry
      // timer — not `failed`.
      await _waitUntil(() => provider.isTaskWaitingForRetry(id),
          what: 'retry timer to be scheduled');
      expect(provider.taskById(id)!.status, DownloadStatus.queued);

      // The retry timer fires and pumps the queue into a second attempt.
      await _waitUntil(() => engine.startedUrls.length >= 2,
          what: 'retry to start a second attempt');
      expect(engine.startedUrls[0], 'https://example.com/bug1.zip');
      expect(engine.startedUrls[1], 'https://example.com/bug1.zip');

      await _waitUntil(
          () => provider.taskById(id)!.status == DownloadStatus.completed,
          what: 'second attempt to complete');
    });

    test('BUG7c: pauseTask cancels the pending retry timer so manual retry '
        'starts immediately', () async {
      engine.enqueueThrow(_transientError());
      engine.enqueueSuccess();
      engine.enqueueSuccess();
      final id = (await provider.addDownload(
        url: 'https://example.com/bug7.zip',
        name: 'bug7.zip',
      ))!;

      await _waitUntil(() => provider.isTaskWaitingForRetry(id),
          what: 'retry timer to be scheduled');

      await provider.pauseTask(id);

      expect(provider.isTaskWaitingForRetry(id), isFalse,
          reason: 'BUG7: pauseTask must cancel the pending retry timer');
      expect(provider.taskById(id)!.status, DownloadStatus.paused);

      // Manual retry resumes immediately (well inside the old 1s timer
      // window) and the engine is started again.
      await provider.resumeTask(id);
      await _waitUntil(() => engine.startedUrls.length >= 2,
          what: 'manual retry to start the engine');
    });

    test('BUG3: pause flushes pending progress and persists receivedBytes',
        () async {
      engine.enqueueWaitCancel();
      final id = (await provider.addDownload(
        url: 'https://example.com/bug3.zip',
        name: 'bug3.zip',
      ))!;
      await _waitUntil(
          () => provider.taskById(id)!.status == DownloadStatus.downloading,
          what: 'task to start downloading');

      // Progress-only update: parks in _pendingProgressUpdates without a
      // DB write (BUG6 pre-condition).
      final live = provider.taskById(id)!;
      await provider.updateTask(live.copyWith(downloadedBytes: 700));
      var row = (await database.loadTasks()).firstWhere((t) => t.id == id);
      expect(row.downloadedBytes, 0, reason: 'progress-only update is parked');

      // pauseTask flushes the pending progress before publishing paused.
      await provider.pauseTask(id);
      expect(provider.taskById(id)!.status, DownloadStatus.paused);
      row = (await database.loadTasks()).firstWhere((t) => t.id == id);
      expect(row.downloadedBytes, 700,
          reason: 'BUG3: pause must persist the latest known bytes');
    });

    test('BUG5: non-YouTube expired link fails over to the mirror and '
        'completes', () async {
      engine.enqueueThrow(const UrlExpiredException('HTTP 410 Gone'));
      engine.enqueueSuccess();
      final id = (await provider.addDownload(
        url: 'https://example.com/bug5.zip',
        name: 'bug5.zip',
        mirrorUrls: ['https://mirror.example.org/bug5.zip'],
      ))!;

      await _waitUntil(() => engine.startedUrls.length >= 2,
          what: 'mirror failover to start');
      expect(engine.startedUrls[1], 'https://mirror.example.org/bug5.zip');
      expect(provider.taskById(id)!.url,
          'https://mirror.example.org/bug5.zip');

      await _waitUntil(
          () => provider.taskById(id)!.status == DownloadStatus.completed,
          what: 'mirror attempt to complete');
    });

    test('BUG5: expired link without mirrors fails with a refresh hint',
        () async {
      engine.enqueueThrow(const UrlExpiredException('HTTP 410 Gone'));
      final id = (await provider.addDownload(
        url: 'https://example.com/bug5b.zip',
        name: 'bug5b.zip',
      ))!;

      await _waitUntil(
          () => provider.taskById(id)!.status == DownloadStatus.failed,
          what: 'task to fail');
      final t = provider.taskById(id)!;
      expect(t.errorMessage, contains('Link expired'));
      expect(t.failureCategory, FailureCategory.authError);
      expect(t.recoveryHint, contains('URL expired'));
    });

    test('BUG10: network-driven policy pause stays auto-resumable on '
        'reconnect (never pausedByUser)', () async {
      engine.enqueueWaitCancel();
      engine.enqueueSuccess();
      final id = (await provider.addDownload(
        url: 'https://example.com/bug10.zip',
        name: 'bug10.zip',
      ))!;
      await _waitUntil(
          () => provider.taskById(id)!.status == DownloadStatus.downloading,
          what: 'task to start downloading');

      // NetworkMonitor policy pause: cancel with the network reason and let
      // the monitor publish the pause state.
      provider.networkMonitor.setConnectivityForTesting(
        [ConnectivityResult.none],
      );
      await provider.networkMonitor.checkNetworkConnectivity();

      await _waitUntil(
          () => provider.taskById(id)!.status == DownloadStatus.paused,
          what: 'task to be paused by the network monitor');
      final pausedTask = provider.taskById(id)!;
      expect(pausedTask.pausedByUser, isFalse,
          reason: 'a network_lost pause must not be labeled as user pause');
      expect(pausedTask.errorMessage, DownloadStatusMessages.waitingNetwork);

      // Reconnect: the policy-paused task must be re-queued automatically
      // and the engine started again.
      provider.networkMonitor.setConnectivityForTesting(
        [ConnectivityResult.wifi],
      );
      await provider.networkMonitor.checkNetworkConnectivity();

      await _waitUntil(() => engine.startedUrls.length >= 2,
          what: 'auto-resume to restart the download');
      expect(
        provider.taskById(id)!.status,
        isNot(DownloadStatus.paused),
      );
    });

    test('BUG6: pending progress is flushed to the DB on the orchestrator '
        'cadence helper', () async {
      engine.enqueueWaitCancel();
      final id = (await provider.addDownload(
        url: 'https://example.com/bug6.zip',
        name: 'bug6.zip',
      ))!;
      await _waitUntil(
          () => provider.taskById(id)!.status == DownloadStatus.downloading,
          what: 'task to start downloading');

      final live = provider.taskById(id)!;
      await provider.updateTask(live.copyWith(downloadedBytes: 900));
      expect(provider.pendingProgressUpdates.contains(id), isTrue);

      await provider.flushPendingProgress(id);
      expect(provider.pendingProgressUpdates.contains(id), isFalse);
      final row =
          (await database.loadTasks()).firstWhere((t) => t.id == id);
      expect(row.downloadedBytes, 900);
    });
  });
}

// ──────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────

Object _transientError() => DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.connectionError,
      error: const SocketException('Simulated network failure'),
    );

Future<void> _waitUntil(bool Function() cond,
    {required String what, Duration timeout = const Duration(seconds: 12)}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) {
      throw StateError('Timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

class _MockConnectivityPlatform extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    return [ConnectivityResult.wifi];
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged {
    return const Stream.empty();
  }
}

class _FakePermissionService extends PermissionService {
  @override
  Future<String> defaultDownloadDirectory() async => 'build/test_dl_orchfix';

  @override
  Future<bool> ensureStorageAccess() async => true;
}

/// Scripted download engine: each `download()` call consumes the next
/// behavior from the queue (throw / wait-for-cancel / succeed).
class _ScriptedEngine extends DownloadEngine {
  _ScriptedEngine() : super(dio: Dio());

  final List<String> startedUrls = [];
  final Queue<Object> _behaviors = ListQueue<Object>();
  static const Object _succeed = 'succeed';
  static const Object _waitCancel = 'wait-cancel';

  void enqueueThrow(Object error) => _behaviors.add(error);
  void enqueueSuccess() => _behaviors.add(_succeed);
  void enqueueWaitCancel() => _behaviors.add(_waitCancel);

  @override
  Future<void> download({
    required String taskId,
    required String url,
    required String tempFilePath,
    required String localFilePath,
    required int knownFileSize,
    required bool supportsResume,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    required int Function() speedLimitBytesPerSecond,
    required int Function() activeDownloadCount,
    int threadCount = 0,
    String? customUserAgent,
    String? referer,
    String? cookies,
    String? oauthToken,
    String? authUsername,
    String? authPassword,
    Map<String, String>? customHeaders,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool isNameAutoGenerated = false,
    List<String>? mirrorUrls,
    bool adaptiveThreads = false,
    int speedLimitKbps = 0,
    YtStreamKind? ytStreamKind,
    int? ytCounterpartSize,
    int? ytCounterpartDownloadedBytes,
    bool isRetry = false,
    int? metadataTimeoutSeconds,
  }) async {
    startedUrls.add(url);
    final behavior =
        _behaviors.isNotEmpty ? _behaviors.removeFirst() : _succeed;
    if (identical(behavior, _waitCancel)) {
      final completer = Completer<void>();
      cancelToken.whenCancel.then((_) {
        if (!completer.isCompleted) {
          completer.completeError(DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
            error: 'cancelled',
          ));
        }
      });
      return completer.future;
    }
    if (behavior is Exception) throw behavior;
    // Success: write a small final file so the completion gate passes.
    final out = File(localFilePath);
    await out.parent.create(recursive: true);
    await out.writeAsBytes(List.filled(2048, 7));
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Recording DownloadOrchestratorHost for unit tests
// ──────────────────────────────────────────────────────────────────────────

class _RecordingHost implements DownloadOrchestratorHost {
  final Map<String, DownloadTask> tasks = {};
  final List<DownloadTask> savedTasks = [];
  final List<String> flushedIds = [];
  final List<({String id, String url})> urlResumes = [];
  int pumpCount = 0;

  @override
  final Map<String, CancelToken> cancelTokens = {};
  @override
  final Map<String, ({CancelToken video, CancelToken audio})>
      orchestratorTokens = {};
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
  NetworkMonitor get networkMonitor => _FakeNetworkMonitor();
  @override
  NotificationCoordinator get notifications => _FakeNotifications();

  @override
  List<DownloadTask> get providerTasks => tasks.values.toList();

  @override
  DownloadTask? findTaskById(String id) => tasks[id];

  @override
  Future<void> setTaskState(DownloadTask task) async {
    savedTasks.add(task);
    tasks[task.id] = task;
  }

  @override
  void pumpQueue() => pumpCount++;

  @override
  Future<void> flushPendingProgress(String id) async {
    if (pendingProgressUpdates.remove(id)) {
      flushedIds.add(id);
    }
  }

  @override
  Future<void> updateTaskUrlAndResume(String id, String newUrl,
      {String? newAudioUrl}) async {
    urlResumes.add((id: id, url: newUrl));
    final t = tasks[id];
    if (t != null) {
      tasks[id] = t.copyWith(url: newUrl, status: DownloadStatus.queued);
    }
  }

  @override
  int effectiveSpeedLimit() => 0;
  @override
  List<double> buildChunks(int threadCount, int fileSize, int downloadedBytes) =>
      List<double>.filled(threadCount > 0 ? threadCount : 1, 0.0);
  @override
  ({int total, List<Map<String, dynamic>>? files}) scanExistingTorrentData(
          String rootPath, List<Map<String, dynamic>>? fileList) =>
      (total: 0, files: fileList);
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

class _FakeNetworkMonitor implements NetworkMonitor {
  @override
  bool get hasWifiOrEthernet => true;

  @override
  bool get isCellular => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeNotifications implements NotificationCoordinator {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
