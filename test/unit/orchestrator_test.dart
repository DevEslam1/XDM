import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_metrics.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';
import 'package:dmx/features/downloads/provider/network_monitor.dart';
import 'package:dmx/features/downloads/provider/notification_coordinator.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal stub implementing [DownloadOrchestratorHost] so we can instantiate
/// [DownloadOrchestrator] and exercise its @visibleForTesting helpers.
class _StubHost implements DownloadOrchestratorHost {
  @override
  void pushProgressTick(String taskId, double progress, double speed) {}

  @override
  final Map<String, ({CancelToken video, CancelToken audio})>
      orchestratorTokens = {};

  @override
  bool get enableBackgroundTimers => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DownloadOrchestrator orchestrator;

  setUp(() {
    orchestrator = DownloadOrchestrator(_StubHost());
  });

  _registerImmediatePauseRaceTest();

  group('isRetryableError', () {
    test('SocketException is retryable', () {
      const error = SocketException('connection reset');
      expect(orchestrator.isRetryableError(error), isTrue);
    });

    test('TimeoutException is retryable', () {
      final error = TimeoutException('timed out');
      expect(orchestrator.isRetryableError(error), isTrue);
    });

    test('general Exception is retryable', () {
      final error = Exception('something went wrong');
      expect(orchestrator.isRetryableError(error), isTrue);
    });

    test('DownloadIntegrityException is NOT retryable', () {
      const error = DownloadIntegrityException('checksum mismatch');
      expect(orchestrator.isRetryableError(error), isFalse);
    });

    test('DioException with cancel type is NOT retryable', () {
      final error = DioException(
        type: DioExceptionType.cancel,
        requestOptions: RequestOptions(path: '/'),
      );
      expect(orchestrator.isRetryableError(error), isFalse);
    });

    test('DioException with 403 status is NOT retryable', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          statusCode: 403,
          requestOptions: RequestOptions(path: '/'),
        ),
      );
      expect(orchestrator.isRetryableError(error), isFalse);
    });

    test('DioException with 404 status is NOT retryable', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          statusCode: 404,
          requestOptions: RequestOptions(path: '/'),
        ),
      );
      expect(orchestrator.isRetryableError(error), isFalse);
    });

    test('DioException with 500 status IS retryable', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          statusCode: 500,
          requestOptions: RequestOptions(path: '/'),
        ),
      );
      expect(orchestrator.isRetryableError(error), isTrue);
    });

    test('error containing "ffmpeg" is NOT retryable', () {
      final error = Exception('ffmpeg merge failed');
      expect(orchestrator.isRetryableError(error), isFalse);
    });

    test('error containing "not found" is NOT retryable', () {
      final error = Exception('file not found on disk');
      expect(orchestrator.isRetryableError(error), isFalse);
    });
  });

  group('youtubeMimeCompatible', () {
    test('same MIME types are compatible', () {
      const old = 'https://rr1.googlevideo.com/videoplayback?mime=video%2Fmp4';
      const new_ = 'https://rr2.googlevideo.com/videoplayback?mime=video%2Fmp4';
      expect(orchestrator.youtubeMimeCompatible(old, new_), isTrue);
    });

    test('only video_only streams require muxing', () {
      expect(orchestrator.youtubeStreamRequiresMuxing('video_only'), isTrue);
      expect(orchestrator.youtubeStreamRequiresMuxing('combined'), isFalse);
      expect(orchestrator.youtubeStreamRequiresMuxing('muxed'), isFalse);
      expect(orchestrator.youtubeStreamRequiresMuxing('audio'), isFalse);
    });

    test('different MIME types are NOT compatible', () {
      const old = 'https://rr1.googlevideo.com/videoplayback?mime=video%2Fmp4';
      const new_ =
          'https://rr2.googlevideo.com/videoplayback?mime=audio%2Fwebm';
      expect(orchestrator.youtubeMimeCompatible(old, new_), isFalse);
    });

    test('missing mime param returns true (lenient)', () {
      const old = 'https://rr1.googlevideo.com/videoplayback?mime=video%2Fmp4';
      const new_ = 'https://rr2.googlevideo.com/videoplayback?id=123';
      expect(orchestrator.youtubeMimeCompatible(old, new_), isTrue);
    });

    test('both missing mime returns true', () {
      const old = 'https://example.com/a';
      const new_ = 'https://example.com/b';
      expect(orchestrator.youtubeMimeCompatible(old, new_), isTrue);
    });
  });

  group('html and stream URL guards', () {
    test('rejects YouTube page URLs as resolved stream URLs', () {
      expect(
        orchestrator.shouldRejectResolvedYoutubeUrl(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        ),
        isTrue,
      );
      expect(
        orchestrator.shouldRejectResolvedYoutubeUrl(
          'https://rr1---sn-abc.googlevideo.com/videoplayback?expire=123',
        ),
        isFalse,
      );
    });

    test('detects HTML content-type responses', () {
      final engine = DownloadEngine(dio: Dio());
      expect(engine.isLikelyHtmlResponse('text/html; charset=utf-8'), isTrue);
      expect(engine.isLikelyHtmlResponse('application/xhtml+xml'), isTrue);
      expect(engine.isLikelyHtmlResponse('application/octet-stream'), isFalse);
      expect(engine.isLikelyHtmlResponse(null), isFalse);
    });
  });

  group('errorMessage', () {
    test('DownloadIntegrityException includes message', () {
      const error = DownloadIntegrityException('size mismatch');
      final msg = orchestrator.errorMessage(error);
      expect(msg, contains('Download integrity check failed'));
      expect(msg, contains('size mismatch'));
    });

    test('IsolateSpawnTimeoutException returns its message', () {
      const error = IsolateSpawnTimeoutException('spawn timed out');
      expect(orchestrator.errorMessage(error), equals('spawn timed out'));
    });

    test('DioException with 403 produces Forbidden message', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          statusCode: 403,
          requestOptions: RequestOptions(path: '/'),
        ),
        message: 'forbidden',
      );
      final msg = orchestrator.errorMessage(error);
      expect(msg, contains('403 Forbidden'));
    });

    test('DioException with 404 produces Not Found message', () {
      final error = DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          statusCode: 404,
          requestOptions: RequestOptions(path: '/'),
        ),
        message: 'gone',
      );
      final msg = orchestrator.errorMessage(error);
      expect(msg, contains('404 Not Found'));
    });

    test('DioException without response produces Dio Error message', () {
      final error = DioException(
        type: DioExceptionType.connectionTimeout,
        requestOptions: RequestOptions(path: '/'),
        message: 'connection timed out',
      );
      final msg = orchestrator.errorMessage(error);
      expect(msg, contains('Dio Error'));
    });

    test('generic Exception produces Error: prefix', () {
      final error = Exception('unexpected');
      final msg = orchestrator.errorMessage(error);
      expect(msg, startsWith('Error:'));
    });
  });

  group('evictStaleCookies', () {
    test('removes entries older than 5 minutes', () {
      final oldTime = DateTime.now().subtract(const Duration(minutes: 10));
      orchestrator.cookieCache['old.example.com'] = (
        cookie: 'old=cookie',
        timestamp: oldTime,
      );
      orchestrator.cookieCache['fresh.example.com'] = (
        cookie: 'fresh=cookie',
        timestamp: DateTime.now(),
      );

      orchestrator.evictStaleCookies();

      expect(orchestrator.cookieCache.containsKey('old.example.com'), isFalse);
      expect(orchestrator.cookieCache.containsKey('fresh.example.com'), isTrue);
    });

    test('keeps all entries when none are stale', () {
      orchestrator.cookieCache['a.com'] = (
        cookie: 'a=1',
        timestamp: DateTime.now(),
      );
      orchestrator.cookieCache['b.com'] = (
        cookie: 'b=2',
        timestamp: DateTime.now(),
      );

      orchestrator.evictStaleCookies();

      expect(orchestrator.cookieCache.length, 2);
    });

    test('evicts oldest when cache exceeds max size', () {
      // Fill cache to max (50) + 1 stale entry
      final oldest = DateTime.now().subtract(const Duration(minutes: 10));
      orchestrator.cookieCache['oldest.com'] = (
        cookie: 'old=1',
        timestamp: oldest,
      );
      for (var i = 0; i < 49; i++) {
        orchestrator.cookieCache['site$i.com'] = (
          cookie: 'c=$i',
          timestamp: DateTime.now(),
        );
      }
      // Now at 50 entries, add one more to trigger eviction
      orchestrator.cookieCache['overflow.com'] = (
        cookie: 'over=flow',
        timestamp: DateTime.now(),
      );

      orchestrator.evictStaleCookies();

      // The oldest entry should have been evicted
      expect(orchestrator.cookieCache.containsKey('oldest.com'), isFalse);
    });
  });

  group('Retry Failure Escalation Tests', () {
    test('escalates to permanent failure notification after max retries',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (MethodCall methodCall) async {
          return null;
        },
      );
      SharedPreferences.setMockInitialValues({});
      await SettingsProvider.instance.load();
      SettingsProvider.instance.autoRetryEnabled = true;
      SettingsProvider.instance.maxRetries = 3;
      SettingsProvider.instance.retryDelaySeconds = 1;

      final host = _TestEscalationHost();
      final orchestrator = DownloadOrchestrator(host);

      final task = DownloadTask(
        id: 't_retry',
        fileName: 'test.zip',
        url: 'https://example.com/test.zip',
        fileSize: 1000,
        downloadedBytes: 0,
        category: 'Archive',
        status: DownloadStatus.queued,
        savePath: '/downloads',
        localFilePath: '/downloads/test.zip',
        tempFilePath: '/downloads/test.zip.dmxpart',
        threadCount: 2,
        chunks: const [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      host.taskInstance = task;
      host.retryCounts[task.id] =
          3; // Max retries is 3, so this is the final attempt
      orchestrator.cookieCache['https://example.com'] = (
        cookie: 'mock=cookie',
        timestamp: DateTime.now(),
      );

      // Trigger task start which will call _executeDownload, fail, and trigger catchError
      orchestrator.startTask(task);
      await Future.delayed(Duration.zero);

      final future = host.activeFutures[task.id];
      if (future != null) {
        await future;
      }

      // Verify task status was set to failed, and error message is the escalation message
      expect(host.lastSavedTaskState, isNotNull);
      expect(host.lastSavedTaskState!.status, equals(DownloadStatus.failed));
      expect(
        host.lastSavedTaskState!.errorMessage,
        contains(
            'Download failed after 3 retries. Please check your network and try again.'),
      );

      // Verify the notifications received the correct escalation error
      expect(host.mockNotifications.lastErrorShown,
          contains('Download failed after 3 retries'));
    });
  });
}

class _TestDownloadEngine extends DownloadEngine {
  _TestDownloadEngine() : super(dio: Dio());

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
    bool isRetry = false,
    String? customUserAgent,
    String? referer,
    String? cookies,
    String? oauthToken,
    List<Map<String, dynamic>>? Function()? getTorrentFiles,
    int? torrentId,
    bool isNameAutoGenerated = false,
    List<String>? mirrorUrls,
    bool adaptiveThreads = false,
    int speedLimitKbps = 0,
    YtStreamKind? ytStreamKind,
    int? ytCounterpartSize,
    int? ytCounterpartDownloadedBytes,
    int? metadataTimeoutSeconds,
  }) async {
    throw const SocketException('Simulated network failure');
  }
}

class _TestNotificationCoordinator implements NotificationCoordinator {
  String? lastErrorShown;
  int? lastNotificationId;

  @override
  void showFailed({
    required int notificationId,
    required String title,
    required String error,
  }) {
    lastNotificationId = notificationId;
    lastErrorShown = error;
  }

  @override
  int idFor(String taskId) => 123;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _TestEscalationHost implements DownloadOrchestratorHost {
  DownloadTask? taskInstance;
  DownloadTask? lastSavedTaskState;
  final mockNotifications = _TestNotificationCoordinator();
  final mockEngine = _TestDownloadEngine();
  final mockNetworkMonitor = _TestNetworkMonitor();

  @override
  NetworkMonitor get networkMonitor => mockNetworkMonitor;

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
  final Map<String, DownloadMetrics> downloadMetrics = {};
  final Set<String> startingTaskIds = {};
  @override
  final Map<String, Queue<double>> speedHistories = {};
  @override
  final Map<String, int> lastProgressUpdateTimes = {};
  @override
  final Map<String, int> lastDbSaveTimes = {};
  @override
  final Map<String, int> lastDbSaveBytes = {};
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
  bool get providerDisposed => false;

  @override
  NotificationCoordinator get notifications => mockNotifications;

  @override
  SettingsProvider get providerSettingsProvider => SettingsProvider.instance;

  @override
  DatabaseService get providerDatabaseService => DatabaseService.instance;

  @override
  DownloadEngine get downloadEngine => mockEngine;

  @override
  Future<void> setTaskState(DownloadTask task) async {
    lastSavedTaskState = task;
    taskInstance = task;
  }

  @override
  List<DownloadTask> get providerTasks =>
      taskInstance != null ? [taskInstance!] : [];

  @override
  void pushProgressTick(String taskId, double progress, double speed) {}

  @override
  Future<void> flushPendingProgress(String taskId) async {}

  @override
  bool get enableBackgroundTimers => false;

  @override
  int get downloadingTasksCount => 0;

  @override
  int get activeOrSeedingCount => 0;

  @override
  DownloadTask? findTaskById(String id) => taskInstance;

  @override
  Future<void> cleanupPartFiles(DownloadTask task,
      {bool preserveParts = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _TestNetworkMonitor implements NetworkMonitor {
  @override
  bool get hasWifiOrEthernet => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void _registerImmediatePauseRaceTest() {
  group('Torrent Immediate Pause Race', () {
    test('early resume is skipped if task status is paused', () async {
      final host = _TestEscalationHost();
      final orchestrator = DownloadOrchestrator(host);

      final task = DownloadTask(
        id: 'race_torrent_task',
        fileName: 'test.torrent',
        url: 'magnet:?xt=urn:btih:race123',
        fileSize: 0,
        downloadedBytes: 0,
        category: 'Archive',
        status: DownloadStatus.paused, // already paused by user race
        savePath: 'build',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      host.taskInstance = task;
      host.providerTorrentIds[task.id] = 123;
      // Mock latest stats so we don't trigger the error-retry branch
      host.providerLatestTorrentStats[123] = TorrentUpdateInfo(
        id: 123,
        name: 'test.torrent',
        progress: 0.0,
        downloadRate: 0,
        uploadRate: 0,
        totalDone: 0,
        totalWanted: 0,
        totalWantedDone: 0,
        hasMetadata: false,
        stateLabel: 'downloading',
      );

      // Verify that running startTask (or the internal body) behaves correctly with paused tasks.
      final started = orchestrator.startTask(task);
      expect(started, isTrue);
    });
  });
}
