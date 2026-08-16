import 'package:dio/dio.dart';
import 'package:dmx/core/di/injection.dart';
import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/engine/cycle_state_resolver.dart';
import 'package:dmx/core/services/engine/download_progress_handler.dart';
import 'package:dmx/core/services/engine/engine_exceptions.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/site_intelligence/site_intelligence_service.dart';
import 'package:dmx/features/details/widgets/torrent_files_panel.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/network_monitor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeNetworkMonitor extends NetworkMonitor {
  bool _mockHasConnection = true;

  FakeNetworkMonitor({bool hasConnection = true})
      : _mockHasConnection = hasConnection,
        super(
          tasks: () => [],
          torrentIds: () => {},
          cancelTokens: () => {},
          wifiOnly: () => false,
          setTask: (_) async {},
          pumpQueue: () {},
        );

  @override
  bool get hasConnection => _mockHasConnection;

  set mockHasConnection(bool val) => _mockHasConnection = val;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Fix 1: TorrentFilesPanel Widget Tests', () {
    testWidgets('renders file items, progress bar and estimated badge correctly', (tester) async {
      final sampleFiles = [
        {
          'name': 'Ubuntu-Server-22.04.iso',
          'length': 1000000,
          'downloadedBytes': 500000,
          'progress': 0.5,
          'progressEstimated': true,
          'selected': true,
        },
        {
          'name': 'README.txt',
          'length': 1000,
          'downloadedBytes': 1000,
          'progress': 1.0,
          'progressEstimated': false,
          'selected': true,
          'isComplete': true,
        },
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TorrentFilesPanel(
                torrentFiles: sampleFiles,
                isDark: true,
                isDownloading: true,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Ubuntu-Server-22.04.iso'), findsOneWidget);
      expect(find.text('README.txt'), findsOneWidget);
      expect(find.text('ESTIMATED'), findsOneWidget);
      expect(find.text('≈50%'), findsOneWidget);
      expect(find.text('100.0%'), findsOneWidget);
    });
  });

  group('Fix 2: App Restart State Recovery', () {
    test('allocating and stalled cycle states map to paused on restart', () {
      final dbService = DatabaseService();

      final allocatingRow = DbDownloadTask(
        id: 'task_alloc',
        fileName: 'file.mkv',
        url: 'https://example.com/file.mkv',
        fileSize: 100000,
        downloadedBytes: 10000,
        speed: 0.0,
        category: 'video',
        status: DownloadStatus.downloading.name,
        cycleState: CycleState.allocating.name,
        savePath: '/downloads/file.mkv',
        localFilePath: '/downloads/file.mkv',
        tempFilePath: '/downloads/file.mkv.dmx',
        threadCount: 1,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        supportsResume: true,
        speedLimitKbps: 0,
        seedingEnabled: false,
        seedingLimited: false,
        seedingLimitKbps: 0,
        audioSize: 0,
        audioDownloadedBytes: 0,
        videoStreamSize: 0,
        audioProgress: 0.0,
        pausedByUser: false,
        isAppUpdate: false,
        uploadedBytes: 0,
        priority: 0,
        queueOrder: 0,
      );

      final stalledRow = DbDownloadTask(
        id: 'task_stalled',
        fileName: 'file2.mkv',
        url: 'https://example.com/file2.mkv',
        fileSize: 100000,
        downloadedBytes: 10000,
        speed: 0.0,
        category: 'video',
        status: DownloadStatus.downloading.name,
        cycleState: CycleState.stalled.name,
        savePath: '/downloads/file2.mkv',
        localFilePath: '/downloads/file2.mkv',
        tempFilePath: '/downloads/file2.mkv.dmx',
        threadCount: 1,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        supportsResume: true,
        speedLimitKbps: 0,
        seedingEnabled: false,
        seedingLimited: false,
        seedingLimitKbps: 0,
        audioSize: 0,
        audioDownloadedBytes: 0,
        videoStreamSize: 0,
        audioProgress: 0.0,
        pausedByUser: false,
        isAppUpdate: false,
        uploadedBytes: 0,
        priority: 0,
        queueOrder: 0,
      );

      final taskAlloc = dbService.rowToTaskForTesting(allocatingRow);
      expect(taskAlloc.status, equals(DownloadStatus.paused));
      expect(taskAlloc.cycleState, equals(CycleState.paused));
      expect(taskAlloc.pauseReason, equals(PauseReason.appRestarted));

      final taskStalled = dbService.rowToTaskForTesting(stalledRow);
      expect(taskStalled.status, equals(DownloadStatus.paused));
      expect(taskStalled.cycleState, equals(CycleState.paused));
      expect(taskStalled.pauseReason, equals(PauseReason.appRestarted));
    });
  });

  group('Fix 3 & Fix 4: SiteIntelligence & HTTP Failed Error Message', () {
    test('SiteIntelligenceService detects signed/expired URLs', () {
      final service = SiteIntelligenceService();
      final signedResult = service.analyzeUrl('https://example-storage.com/file?token=123&expire=99999999');
      expect(signedResult.isExpiredOrSigned, isTrue);
    });
  });

  group('Fix 5: Torrent Pause Reason Inference', () {
    setUp(() {
      if (getIt.isRegistered<NetworkMonitor>()) {
        getIt.unregister<NetworkMonitor>();
      }
    });

    tearDown(() {
      if (getIt.isRegistered<NetworkMonitor>()) {
        getIt.unregister<NetworkMonitor>();
      }
    });

    test('infers networkLost when NetworkMonitor reports no connection', () {
      final fakeNet = FakeNetworkMonitor(hasConnection: false);
      getIt.registerSingleton<NetworkMonitor>(fakeNet);

      final inferred = TorrentDownloadHandler.inferPauseReasonForTesting();
      expect(inferred, equals(PauseReason.networkLost));
    });

    test('defaults to userRequested when network and battery are fine', () {
      final fakeNet = FakeNetworkMonitor(hasConnection: true);
      getIt.registerSingleton<NetworkMonitor>(fakeNet);

      final inferred = TorrentDownloadHandler.inferPauseReasonForTesting();
      expect(inferred, equals(PauseReason.userRequested));
    });
  });

  group('Fix 6: Torrent Resume Verifying State', () {
    test('verifying cycle state exists in enum and displays properly', () {
      expect(CycleState.verifying.name, equals('verifying'));
    });
  });

  group('Fix 7: YouTube Counterpart Slow-Start Decoupling', () {
    test('DownloadProgressHandler emits retrying at 35s and extends timeout to 5min', () async {
      DownloadProgress? lastEmitted;
      final handler = DownloadProgressHandler(
        taskId: 'yt_test',
        onProgress: (p) => lastEmitted = p,
        cancelToken: CancelToken(),
        resolvedFileName: 'yt_video.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 50000,
        ytCounterpartDownloadedBytes: 0,
        isTorrent: false,
        getEffectiveIntervalMs: () => 0,
        lastDownloadedBytes: 100,
        lastFileSize: 1000,
      );

      // 35s slow start -> retrying state with 'Waiting for counterpart stream…'
      handler.counterpartWaitStartForTesting = DateTime.now().subtract(const Duration(seconds: 35));
      await handler.handleWorkerProgress(
        {
          'downloadedBytes': 100,
          'fileSize': 1000,
          'cycleState': CycleState.downloading,
        },
        isCounterpartUnregistered: true,
      );
      expect(lastEmitted?.cycleState, equals(CycleState.retrying));
      expect(lastEmitted?.statusMessage, equals('Waiting for counterpart stream…'));

      // 200s (under 5min) -> should still be retrying, NOT throwing UrlExpiredException
      handler.counterpartWaitStartForTesting = DateTime.now().subtract(const Duration(seconds: 200));
      await handler.handleWorkerProgress(
        {
          'downloadedBytes': 100,
          'fileSize': 1000,
          'cycleState': CycleState.downloading,
        },
        isCounterpartUnregistered: true,
      );
      expect(lastEmitted?.cycleState, equals(CycleState.retrying));

      // 305s (> 5min) -> throws UrlExpiredException
      handler.counterpartWaitStartForTesting = DateTime.now().subtract(const Duration(seconds: 305));
      expect(
        () => handler.handleWorkerProgress(
          {
            'downloadedBytes': 100,
            'fileSize': 1000,
            'cycleState': CycleState.downloading,
          },
          isCounterpartUnregistered: true,
        ),
        throwsA(isA<UrlExpiredException>()),
      );
    });

    test('_handleUrlExpired emits failed progress on max retries reached', () {
      DownloadProgress? lastEmitted;
      final handler = DownloadProgressHandler(
        taskId: 'yt_fail_test',
        onProgress: (p) => lastEmitted = p,
        cancelToken: CancelToken(),
        resolvedFileName: 'yt_video.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 50000,
        ytCounterpartDownloadedBytes: 0,
        isTorrent: false,
        getEffectiveIntervalMs: () => 0,
        lastDownloadedBytes: 100,
        lastFileSize: 1000,
      );

      handler.handleUrlExpired(); // 1
      handler.handleUrlExpired(); // 2
      expect(
        () => handler.handleUrlExpired(), // 3 -> emits failed then throws DownloadIntegrityException
        throwsA(isA<DownloadIntegrityException>()),
      );
      expect(lastEmitted?.cycleState, equals(CycleState.failed));
      expect(lastEmitted?.statusMessage, contains('Failed: Counterpart stream lost'));
    });
  });

  group('Fix 2 (Widen updatingLinks Regex): CycleStateResolver', () {
    test('resolves updating mirrors and refreshing links/urls/mirrors to updatingLinks', () {
      expect(
        CycleStateResolver.resolve(statusMessage: 'Updating mirrors…'),
        equals(CycleState.updatingLinks),
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Refreshing links…'),
        equals(CycleState.updatingLinks),
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Refreshing URLs…'),
        equals(CycleState.updatingLinks),
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Refreshing mirrors…'),
        equals(CycleState.updatingLinks),
      );
    });
  });

  group('Fix 3 & Fix 7: Torrent Pause Reason & distributeEstimatedBytes', () {
    test('infers PauseReason.background when screen is off', () {
      PowerMonitor.screenOff = true;
      expect(
        TorrentDownloadHandler.inferPauseReasonForTesting(),
        equals(PauseReason.background),
      );
      PowerMonitor.screenOff = false;
    });

    test('distributeEstimatedBytes ignores zero-length files', () {
      final files = [
        {'name': 'zero.txt', 'length': 0, 'downloadedBytes': 0, 'progressEstimated': true, 'priority': 4},
        {'name': 'real.bin', 'length': 1000, 'downloadedBytes': 0, 'progressEstimated': true, 'priority': 4},
      ];
      TorrentDownloadHandler.distributeEstimatedBytes(files, 500);
      expect(files[0]['downloadedBytes'], equals(0));
      expect(files[1]['downloadedBytes'], equals(500));
    });
  });

  group('Fix 6: ytCombinedProgress in DownloadTask', () {
    test('computes combined video + audio progress accurately', () {
      final task = DownloadTask(
        id: 'yt_paired',
        fileName: 'yt_paired.mp4',
        url: 'https://youtube.com/watch?v=123',
        fileSize: 600,
        downloadedBytes: 300,
        speed: 0,
        category: 'video',
        status: DownloadStatus.downloading,
        savePath: '/downloads/yt_paired.mp4',
        localFilePath: '/downloads/yt_paired.mp4',
        tempFilePath: '/downloads/yt_paired.mp4.dmx',
        threadCount: 1,
        chunks: const [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        mergedAudioUrl: 'https://youtube.com/audio_stream',
        audioSize: 400,
        audioDownloadedBytes: 200,
      );

      // (300 + 200) / (600 + 400) = 500 / 1000 = 0.5
      expect(task.ytCombinedProgress, equals(0.5));
    });

    test('returns null for non-YouTube tasks', () {
      final task = DownloadTask(
        id: 'http_task',
        fileName: 'file.bin',
        url: 'https://example.com/file.bin',
        fileSize: 1000,
        downloadedBytes: 500,
        speed: 0,
        category: 'files',
        status: DownloadStatus.downloading,
        savePath: '/downloads/file.bin',
        localFilePath: '/downloads/file.bin',
        tempFilePath: '/downloads/file.bin.dmx',
        threadCount: 1,
        chunks: const [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(task.ytCombinedProgress, isNull);
    });
  });
}

