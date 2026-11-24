import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:dio/dio.dart';
import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/interfaces/i_download_engine.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/download_metrics.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/downloads/provider/network_monitor.dart';
import 'package:dmx/features/downloads/provider/notification_coordinator.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_download_engine.dart';
import '../../../helpers/fake_services.dart';

/// Drives [DownloadOrchestrator] end-to-end through [startTask] using a fake
/// engine that writes the output file, so the execute/finalize/error branches
/// are exercised without any real network or FFI.
class _FlowHost implements DownloadOrchestratorHost {
  _FlowHost({
    required this.engine,
    required this.settings,
  });

  final FakeIDownloadEngine engine;
  final SettingsProvider settings;
  @override
  final bool enableBackgroundTimers = false;

  final List<DownloadTask> tasks = [];
  final List<DownloadTask> saved = [];
  final List<String> urlResumes = [];
  final List<({String id, String url})> startOvers = [];
  int pumpCount = 0;
  int notifyCount = 0;
  int widgetTimerCount = 0;
  int stopWidgetTimerCount = 0;
  bool disposed = false;

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
  bool get providerDisposed => disposed;
  @override
  int get downloadingTasksCount => 0;
  @override
  int get activeOrSeedingCount => 0;

  @override
  SettingsProvider get providerSettingsProvider => settings;
  @override
  DatabaseService get providerDatabaseService => FakeDatabaseService();
  @override
  IDownloadEngine get downloadEngine => engine;
  final _FakeNetworkMonitor networkMonitorImpl = _FakeNetworkMonitor();
  @override
  NetworkMonitor get networkMonitor => networkMonitorImpl;
  @override
  NotificationCoordinator get notifications => _FakeNotifications();

  @override
  List<DownloadTask> get providerTasks => tasks;
  @override
  DownloadTask? findTaskById(String id) {
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  @override
  Future<void> setTaskState(DownloadTask task) async {
    final i = tasks.indexWhere((t) => t.id == task.id);
    if (i == -1) {
      tasks.add(task);
    } else {
      tasks[i] = task;
    }
    saved.add(task);
  }

  @override
  void updateProgressTask(DownloadTask updated) {
    final i = tasks.indexWhere((t) => t.id == updated.id);
    if (i != -1) tasks[i] = updated;
  }

  @override
  void pumpQueue() => pumpCount++;
  @override
  void providerNotifyListeners() => notifyCount++;
  @override
  void providerStartWidgetTimer() => widgetTimerCount++;
  @override
  void providerStopWidgetTimer() => stopWidgetTimerCount++;
  @override
  void updateTelemetryWidget() {}
  @override
  void pushProgressTick(String taskId, double progress, double speed) {}
  @override
  int effectiveSpeedLimit() => 0;
  @override
  List<double> buildChunks(int count, int size, int bytes) =>
      List<double>.filled(count > 0 ? count : 1, 0.0);
  @override
  ({int total, List<Map<String, dynamic>>? files}) scanExistingTorrentData(
          String rootPath, List<Map<String, dynamic>>? fileList) =>
      (total: 0, files: fileList);
  @override
  List<Map<String, dynamic>> markTorrentFilesCompleted(
          List<Map<String, dynamic>> files) =>
      files;

  @override
  Future<void> flushPendingProgress(String id) async {
    pendingProgressUpdates.remove(id);
  }

  @override
  Future<void> updateTaskUrlAndResume(String id, String newUrl,
      {String? newAudioUrl}) async {
    urlResumes.add(newUrl);
    final i = tasks.indexWhere((t) => t.id == id);
    if (i != -1) {
      tasks[i] = tasks[i].copyWith(url: newUrl, status: DownloadStatus.queued);
    }
  }

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
      bool deleteTempFiles = false}) async {
    startOvers.add((id: id, url: newUrl));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeNetworkMonitor implements NetworkMonitor {
  bool wifi = true;
  bool cellular = false;

  @override
  bool get hasWifiOrEthernet => wifi;
  @override
  bool get isCellular => cellular;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeNotifications implements NotificationCoordinator {
  @override
  int idFor(String taskId) => 99;
  @override
  String opaqueHandleFor(String taskId) => 'handle:$taskId';
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Fake engine that can succeed (writing the output file), emit progress, or
/// throw a scripted error on the next call.
class _FileEngine extends FakeIDownloadEngine {
  final List<String> startedUrls = [];
  Object? nextError;
  bool emitProgressTicks = false;
  bool skipWrite = false;
  int? writeBytes;

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
    final error = nextError;
    if (error != null) {
      nextError = null;
      throw error;
    }
    final total = writeBytes ?? (knownFileSize > 0 ? knownFileSize : 4096);
    if (emitProgressTicks) {
      onProgress(DownloadProgress(
        downloadedBytes: total,
        fileSize: total,
        speed: 1024 * 1024,
        eta: 1,
        chunks: const [1.0],
      ));
      await Future<void>.delayed(Duration.zero);
    }
    if (skipWrite) return;
    final out = File(localFilePath);
    await out.parent.create(recursive: true);
    await out.writeAsBytes(List<int>.filled(total, 7));
  }
}

DownloadTask _httpTask(
  String id, {
  required Directory dir,
  DownloadStatus status = DownloadStatus.queued,
  int fileSize = 4096,
  int downloadedBytes = 0,
  String category = 'Other',
  List<String>? mirrorUrls,
  String? mergedAudioUrl,
  int audioSize = 0,
  String? expectedSha256,
}) {
  final now = DateTime.now();
  return DownloadTask(
    id: id,
    fileName: '$id.bin',
    url: 'https://example.com/$id.bin',
    fileSize: fileSize,
    downloadedBytes: downloadedBytes,
    category: category,
    status: status,
    savePath: dir.path,
    localFilePath: '${dir.path}/$id.bin',
    tempFilePath: '${dir.path}/$id.dmxpart',
    threadCount: 1,
    chunks: const [0.0],
    supportsResume: true,
    createdAt: now,
    updatedAt: now,
    mirrorUrls: mirrorUrls,
    mergedAudioUrl: mergedAudioUrl,
    audioSize: audioSize,
    expectedSha256: expectedSha256,
  );
}

Future<void> _waitFor(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw StateError('Timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late SettingsProvider settings;
  late _FileEngine engine;
  late _FlowHost host;
  late DownloadOrchestrator orch;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (methodCall) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.dmx.app/media'),
      (methodCall) async => null,
    );
  });

  setUp(() async {
    DownloadEngine.appInForeground = true;
    PowerMonitor.screenOff = false;
    SharedPreferences.setMockInitialValues({});
    settings = SettingsProvider.instance;
    await settings.load();
    settings.autoRetryEnabled = false;
    settings.autoVerifyChecksum = false;
    settings.vibration = false;
    settings.wifiOnly = false;
    settings.pauseOnCellular = false;
    settings.downloadOnlyWhileCharging = false;
    settings.customUserAgent = '';
    settings.adaptiveThreads = false;
    dir = Directory.systemTemp.createTempSync('dmx_orch_flow_');
    engine = _FileEngine();
    host = _FlowHost(engine: engine, settings: settings);
    orch = DownloadOrchestrator(host);
  });

  tearDown(() {
    orch.dispose();
    for (final t in host.retryTimers.values) {
      t.cancel();
    }
    host.disposed = true;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
    DownloadEngine.appInForeground = true;
    PowerMonitor.screenOff = false;
  });

  group('startTask success flow', () {
    test('completes a plain HTTP download and finalizes the task', () async {
      final task = _httpTask('ok', dir: dir, fileSize: 4096);
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(
          () => host.findTaskById('ok')?.status == DownloadStatus.completed);

      final done = host.findTaskById('ok')!;
      expect(done.status, DownloadStatus.completed);
      expect(done.downloadedBytes, 4096);
      expect(engine.startedUrls, hasLength(1));
      expect(host.pumpCount, greaterThan(0));
      expect(host.cancelTokens.containsKey('ok'), isFalse);
    });

    test('finalizes after emitting progress', () async {
      engine.emitProgressTicks = true;
      final task = _httpTask('prog', dir: dir, fileSize: 8192);
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(
          () => host.findTaskById('prog')?.status == DownloadStatus.completed);
      expect(host.findTaskById('prog')!.status, DownloadStatus.completed);
    });

    test('fails when the engine cannot confirm disk space', () async {
      engine.simulatedHasEnoughSpace = false;
      final task = _httpTask('nospace', dir: dir);
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(
          () => host.findTaskById('nospace')?.status == DownloadStatus.failed);
      final failed = host.findTaskById('nospace')!;
      expect(failed.errorMessage, contains('Not enough storage space'));
      expect(engine.startedUrls, isEmpty);
    });
  });

  group('startTask policy pauses', () {
    test('wifiOnly without wifi pauses the task', () async {
      settings.wifiOnly = true;
      host.networkMonitorImpl.wifi = false;
      final task = _httpTask('wifi', dir: dir);
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(
          () => host.findTaskById('wifi')?.status == DownloadStatus.paused);
      expect(host.findTaskById('wifi')!.errorMessage,
          DownloadStatusMessages.waitingWifi);
      expect(engine.startedUrls, isEmpty);
    });

    test('pauseOnCellular on a cellular link pauses the task', () async {
      settings.pauseOnCellular = true;
      host.networkMonitorImpl.cellular = true;
      final task = _httpTask('cell', dir: dir);
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(
          () => host.findTaskById('cell')?.status == DownloadStatus.paused);
      expect(host.findTaskById('cell')!.errorMessage,
          DownloadStatusMessages.waitingWifi);
    });

    test('downloadOnlyWhileCharging pauses when unplugged', () async {
      settings.downloadOnlyWhileCharging = true;
      PowerMonitor.setBatteryStateForTesting(BatteryState.discharging);
      final task = _httpTask('charge', dir: dir);
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(
          () => host.findTaskById('charge')?.status == DownloadStatus.paused);
      expect(host.findTaskById('charge')!.errorMessage,
          DownloadStatusMessages.waitingCharging);
    });
  });

  group('startTask failure handling', () {
    test('transient failure schedules a retry and stays queued', () async {
      settings.autoRetryEnabled = true;
      settings.maxRetries = 1;
      settings.retryDelaySeconds = 1;
      engine.nextError = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionError,
      );
      final task = _httpTask('retry', dir: dir);
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(() => host.retryTimers.containsKey('retry'));
      final live = host.findTaskById('retry')!;
      expect(live.status, DownloadStatus.queued);
      expect(live.errorMessage, contains('Retrying in'));
      host.retryTimers['retry']!.cancel();
    });

    test('non-retryable failure fails permanently and cleans up', () async {
      engine.nextError = const InsufficientStorageException('disk full');
      final task = _httpTask('perm', dir: dir);
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(
          () => host.findTaskById('perm')?.status == DownloadStatus.failed);
      final failed = host.findTaskById('perm')!;
      expect(failed.status, DownloadStatus.failed);
      expect(failed.errorMessage, 'disk full');
    });

    test('expired URL fails over to a mirror', () async {
      settings.autoRetryEnabled = false;
      engine.nextError = const UrlExpiredException('HTTP 410 Gone');
      final task = _httpTask(
        'expired',
        dir: dir,
        mirrorUrls: ['https://mirror.example.org/expired.bin'],
      );
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(() => host.urlResumes.isNotEmpty);
      expect(host.urlResumes.first, 'https://mirror.example.org/expired.bin');
    });

    test('resume rejection performs a start-over', () async {
      engine.nextError =
          Exception('Server rejected resume: expected HTTP 206.');
      final task = _httpTask('resume', dir: dir);
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(() => host.startOvers.isNotEmpty);
      expect(host.startOvers.first.id, 'resume');
    });
  });

  group('resolve guards', () {
    test('startTask rejects a task that already has a cancel token', () {
      final task = _httpTask('tok', dir: dir);
      host.tasks.add(task);
      host.cancelTokens['tok'] = CancelToken();
      expect(orch.startTask(task), isFalse);
    });

    test('failTaskIfNoRetryScheduled leaves a failed task untouched', () async {
      final task = _httpTask('done', dir: dir, status: DownloadStatus.failed);
      host.tasks.add(task);
      await orch.failTaskIfNoRetryScheduled('done');
      expect(host.saved, isEmpty);
    });
  });

  group('provider static helpers', () {
    test('calculateDownloadedFromState prefers explicit bytes', () {
      expect(
        DownloadProvider.calculateDownloadedFromState({'downloadedBytes': 55}),
        55,
      );
    });

    test('calculateDownloadedFromState sums fractional and absolute progress',
        () {
      expect(
        DownloadProvider.calculateDownloadedFromState({
          'totalSize': 1000,
          'progress': [0.5, 0.5],
        }),
        500,
      );
      expect(
        DownloadProvider.calculateDownloadedFromState({
          'totalSize': 1000,
          'progress': [200, 300],
        }),
        500,
      );
    });

    test('calculateDownloadedFromState returns zero without progress info', () {
      expect(DownloadProvider.calculateDownloadedFromState({}), 0);
      expect(
        DownloadProvider.calculateDownloadedFromState({'progress': 'x'}),
        0,
      );
    });

    test('torrent byte and size helpers ignore unselected files', () {
      final files = [
        {'length': 100, 'downloadedBytes': 40, 'selected': true},
        {'length': 900, 'downloadedBytes': 800, 'selected': false},
      ];
      expect(DownloadProvider.torrentBytesFromFiles(files), 40);
      expect(DownloadProvider.torrentSelectedFilesTotalSize(files), 100);
      expect(DownloadProvider.torrentBytesFromFiles(null), 0);
      expect(DownloadProvider.torrentSelectedFilesTotalSize(null), 0);
    });

    test('youtubeStreamIdentityChanged detects id/docid rotation', () {
      expect(
        DownloadProvider.youtubeStreamIdentityChanged(
          'https://x/videoplayback?id=aaa',
          'https://x/videoplayback?id=bbb',
        ),
        isTrue,
      );
      expect(
        DownloadProvider.youtubeStreamIdentityChanged(null, 'https://x/a'),
        isFalse,
      );
      expect(
        DownloadProvider.youtubeStreamIdentityChanged(
          'not a url',
          'https://x/a',
        ),
        isFalse,
      );
    });
  });

  group('finalize guards', () {
    test('fails when the output file never appears', () async {
      engine.skipWrite = true;
      final task = _httpTask('nofile', dir: dir, fileSize: 2048);
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(
          () => host.findTaskById('nofile')?.status == DownloadStatus.failed);
      expect(host.findTaskById('nofile')!.errorMessage,
          contains('Output file missing'));
    });

    test('fails when the downloaded payload is short', () async {
      engine.writeBytes = 10;
      final task = _httpTask('short', dir: dir, fileSize: 4096);
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(
          () => host.findTaskById('short')?.status == DownloadStatus.failed);
      expect(host.findTaskById('short')!.errorMessage,
          contains('Download incomplete'));
    });

    test('rejects a tiny Video payload as an error page', () async {
      engine.writeBytes = 1024;
      final task =
          _httpTask('tiny', dir: dir, fileSize: 1024, category: 'Video');
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(
          () => host.findTaskById('tiny')?.status == DownloadStatus.failed);
      expect(host.findTaskById('tiny')!.errorMessage,
          contains('likely an error page'));
    });

    test('fails when the expected checksum does not match', () async {
      final task = _httpTask(
        'sha',
        dir: dir,
        fileSize: 2048,
        expectedSha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
      );
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(
          () => host.findTaskById('sha')?.status == DownloadStatus.failed);
      expect(host.findTaskById('sha')!.errorMessage,
          contains('Checksum verification failed'));
    });
  });

  group('retry exhaustion', () {
    test('permanent failure after the retry budget is spent', () async {
      settings.autoRetryEnabled = true;
      settings.maxRetries = 1;
      settings.retryDelaySeconds = 1;
      engine.nextError = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionError,
      );
      final task = _httpTask('exhaust', dir: dir);
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(() => host.retryTimers.containsKey('exhaust'));
      host.retryTimers['exhaust']!.cancel();

      engine.nextError = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionError,
      );
      expect(orch.startTask(host.findTaskById('exhaust')!), isTrue);
      await _waitFor(
          () => host.findTaskById('exhaust')?.status == DownloadStatus.failed);
      expect(host.findTaskById('exhaust')!.errorMessage,
          contains('Download failed after 1 retries'));
    });
  });

  group('resume validation', () {
    test('clears audio progress when merged audio has no state', () async {
      final task = _httpTask(
        'audio-nostate',
        dir: dir,
        downloadedBytes: 500,
        mergedAudioUrl: 'https://example.com/a.m4a',
        audioSize: 1000,
      );
      final result = await orch.validateResumeState(task);
      expect(result.audioProgress, 0.0);
      expect(result.audioDownloadedBytes, 0);
    });

    test('recomputes audio progress when a state file exists', () async {
      final task = _httpTask(
        'audio-state',
        dir: dir,
        downloadedBytes: 500,
        mergedAudioUrl: 'https://example.com/a.m4a',
        audioSize: 1000,
      );
      final audioPath = '${task.tempFilePath}.audio';
      await StateStore.loadOrCreate(
        audioPath,
        url: task.mergedAudioUrl!,
        threadCount: 1,
        knownFileSize: 1000,
        taskId: task.id,
      );
      final result = await orch.validateResumeState(task);
      expect(result.audioProgress, isNotNull);
    });
  });

  group('more finalize branches', () {
    test('renames a leftover video-only file before download', () async {
      final task = _httpTask('vidonly', dir: dir, fileSize: 2048);
      final videoOnly = '${dir.path}/vidonly_video_only.bin';
      File(videoOnly).writeAsBytesSync(List<int>.filled(2048, 5));
      engine.skipWrite = true;
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(() =>
          host.findTaskById('vidonly')?.status == DownloadStatus.completed);
      expect(File('${dir.path}/vidonly.bin').existsSync(), isTrue);
    });

    test('auto-verifies the checksum when enabled', () async {
      settings.autoVerifyChecksum = true;
      final task = _httpTask('auto-sha', dir: dir, fileSize: 2048);
      host.tasks.add(task);

      expect(orch.startTask(task), isTrue);
      await _waitFor(() =>
          host.findTaskById('auto-sha')?.status == DownloadStatus.completed);
      final done = host.findTaskById('auto-sha')!;
      expect(done.expectedSha256, isNotNull);
      expect(done.expectedSha256, isNotEmpty);
    });
  });

  group('merge retry paths', () {
    test('short-circuits to finalize when the merged output already exists',
        () async {
      final task = _httpTask(
        'merge-c6',
        dir: dir,
        fileSize: 10000,
        mergedAudioUrl: 'https://example.com/a.m4a',
        audioSize: 2000,
        status: DownloadStatus.failed,
      );
      final mergedPath = '${task.tempFilePath}.merged.bin';
      File(mergedPath).writeAsBytesSync(List<int>.filled(10000, 3));
      final videoOnly = '${dir.path}/merge-c6_video_only.bin';
      File(videoOnly).writeAsStringSync('v');
      host.tasks.add(task);

      await orch.retryMergeOnly(task);

      final done = host.findTaskById('merge-c6')!;
      expect(done.status, DownloadStatus.completed);
      expect(File(task.localFilePath).existsSync(), isTrue);
      expect(File(videoOnly).existsSync(), isFalse);
    });

    test('returns true when the merge output is already complete', () async {
      final task = _httpTask(
        'merge-done',
        dir: dir,
        fileSize: 10000,
        mergedAudioUrl: 'https://example.com/a.m4a',
        audioSize: 2000,
        status: DownloadStatus.failed,
      );
      File(task.tempFilePath).writeAsBytesSync(List<int>.filled(10000, 1));
      File('${task.tempFilePath}.audio')
          .writeAsBytesSync(List<int>.filled(2000, 2));
      // The merge path resolves to a different output name than the FIX-C6
      // shortcut because localFilePath is absent.
      File('${dir.path}/merge-done.dmxpart.merged.dmxpart')
          .writeAsBytesSync(List<int>.filled(10000, 3));
      host.tasks.add(task);

      await orch.retryMergeOnly(task);

      expect(
        host.saved.any((t) => t.isMergeInProgress),
        isTrue,
      );
      expect(host.findTaskById('merge-done')!.status, DownloadStatus.failed);
    });
  });

  group('cleanup helpers', () {
    test('cleanupTempFiles removes audio sidecars when merged audio present',
        () async {
      final task = _httpTask(
        'clean-audio',
        dir: dir,
        mergedAudioUrl: 'https://example.com/a.m4a',
      );
      File('${task.tempFilePath}.audio').writeAsStringSync('a');
      File('${task.tempFilePath}.audio.dmxstate').writeAsStringSync('{}');

      await orch.cleanupTempFiles(task);
      expect(File('${task.tempFilePath}.audio').existsSync(), isFalse);
    });

    test('cleanupTorrentArtifacts removes torrent sidecars', () async {
      final task = _httpTask('clean-torrent', dir: dir);
      File('${task.tempFilePath}.torrent').writeAsStringSync('t');
      File('${task.tempFilePath}.journal').writeAsStringSync('j');

      await orch.cleanupTorrentArtifacts(task);
      expect(File('${task.tempFilePath}.torrent').existsSync(), isFalse);
      expect(File('${task.tempFilePath}.journal').existsSync(), isFalse);
    });

    test('cleanupAllArtifacts full HTTP cleanup removes part files', () async {
      final task = _httpTask('clean-http', dir: dir).copyWith(threadCount: 2);
      File('${task.tempFilePath}.part0').writeAsStringSync('0');
      File('${task.tempFilePath}.part1').writeAsStringSync('1');

      await orch.cleanupAllArtifacts(task);
      expect(File('${task.tempFilePath}.part0').existsSync(), isFalse);
    });
  });
}
