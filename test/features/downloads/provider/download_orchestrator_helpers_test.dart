import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/download_metrics.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal host so the orchestrator's @visibleForTesting helpers and static
/// classifiers can be exercised without the full DownloadProvider.
class _Host implements DownloadOrchestratorHost {
  final Map<String, DownloadTask> tasks = {};
  final List<DownloadTask> saved = [];
  final List<String> flushed = [];

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
  bool get providerDisposed => false;
  @override
  bool get enableBackgroundTimers => false;
  @override
  int get downloadingTasksCount => 0;
  @override
  int get activeOrSeedingCount => 0;

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
  Future<void> flushPendingProgress(String id) async {
    if (pendingProgressUpdates.remove(id)) flushed.add(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadTask _task(
  String id, {
  DownloadStatus status = DownloadStatus.downloading,
  String? url,
  int downloadedBytes = 0,
  String tempFilePath = '',
  String savePath = '',
  List<Map<String, dynamic>>? torrentFiles,
  String? statusMessage,
  List<String>? mirrorUrls,
}) {
  final now = DateTime(2026, 1, 1);
  return DownloadTask(
    id: id,
    fileName: '$id.zip',
    url: url ?? 'https://example.com/$id.zip',
    fileSize: 1000,
    downloadedBytes: downloadedBytes,
    category: 'Other',
    status: status,
    savePath: savePath,
    localFilePath: '/d/$id.zip',
    tempFilePath: tempFilePath,
    threadCount: 2,
    chunks: const [0.0, 0.0],
    createdAt: now,
    updatedAt: now,
    torrentFiles: torrentFiles,
    statusMessage: statusMessage,
    mirrorUrls: mirrorUrls,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Host host;
  late DownloadOrchestrator orch;

  setUp(() {
    host = _Host();
    orch = DownloadOrchestrator(host);
  });

  tearDown(() => orch.dispose());

  group('errorMessage', () {
    test('maps common HTTP status codes', () {
      DioException dio(int code) => DioException(
            type: DioExceptionType.badResponse,
            requestOptions: RequestOptions(path: '/'),
            response: Response(
              statusCode: code,
              requestOptions: RequestOptions(path: '/'),
            ),
            message: 'boom',
          );
      expect(orch.errorMessage(dio(401)), contains('401 Unauthorized'));
      expect(orch.errorMessage(dio(403)), contains('403 Forbidden'));
      expect(orch.errorMessage(dio(404)), contains('404 Not Found'));
      expect(orch.errorMessage(dio(410)), contains('410 Gone'));
      expect(orch.errorMessage(dio(416)), contains('416 Range'));
      expect(orch.errorMessage(dio(500)), contains('500 Internal'));
      expect(orch.errorMessage(dio(503)), contains('503 Service'));
      expect(orch.errorMessage(dio(418)), contains('HTTP Error 418'));
    });

    test('insufficient storage returns its message', () {
      const e = InsufficientStorageException('disk full');
      expect(orch.errorMessage(e), 'disk full');
    });

    test('download integrity error is prefixed', () {
      const e = DownloadIntegrityException('size mismatch');
      expect(orch.errorMessage(e), contains('integrity check failed'));
    });

    test('isolate spawn timeout returns its message', () {
      const e = IsolateSpawnTimeoutException('spawn timeout');
      expect(orch.errorMessage(e), 'spawn timeout');
    });

    test('dio without response falls back to Dio Error', () {
      final e = DioException(
        type: DioExceptionType.connectionTimeout,
        requestOptions: RequestOptions(path: '/'),
        message: 'timeout',
      );
      expect(orch.errorMessage(e), contains('Dio Error'));
    });

    test('generic error is prefixed', () {
      expect(orch.errorMessage(Exception('boom')), startsWith('Error:'));
    });
  });

  group('isRetryableError', () {
    test('rejects non-healing failures', () {
      expect(orch.isRetryableError(const InsufficientStorageException()),
          isFalse);
      expect(orch.isRetryableError(const UrlExpiredException('gone')),
          isFalse);
      expect(
        orch.isRetryableError(const FileSystemException('write failed')),
        isFalse,
      );
      expect(
        orch.isRetryableError(const PositionalFileWriterException('closed')),
        isFalse,
      );
      expect(
        orch.isRetryableError(Exception('Permission denied')),
        isFalse,
      );
      expect(
        orch.isRetryableError(Exception('file changed on server')),
        isFalse,
      );
      expect(
        orch.isRetryableError(Exception('ffmpeg merge failed')),
        isFalse,
      );
      expect(
        orch.isRetryableError(Exception('output file missing')),
        isFalse,
      );
      expect(
        orch.isRetryableError(Exception('resource not found here')),
        isFalse,
      );
    });

    test('treats network and YouTube transients as retryable', () {
      expect(orch.isRetryableError(Exception('html_instead_of_media')),
          isTrue);
      expect(orch.isRetryableError(Exception('Sign in to confirm')), isTrue);
      expect(
        orch.isRetryableError(DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(path: '/'),
        )),
        isTrue,
      );
      expect(
        orch.isRetryableError(DioException(
          type: DioExceptionType.cancel,
          requestOptions: RequestOptions(path: '/'),
        )),
        isFalse,
      );
      expect(
        orch.isRetryableError(DioException(
          type: DioExceptionType.unknown,
          requestOptions: RequestOptions(path: '/'),
          error: 'Torrent handle lost',
        )),
        isFalse,
      );
      expect(
        orch.isRetryableError(DioException(
          type: DioExceptionType.badResponse,
          requestOptions: RequestOptions(path: '/'),
          response: Response(
            statusCode: 404,
            requestOptions: RequestOptions(path: '/'),
          ),
        )),
        isFalse,
      );
      expect(
        orch.isRetryableError(DioException(
          type: DioExceptionType.badResponse,
          requestOptions: RequestOptions(path: '/'),
          response: Response(
            statusCode: 503,
            requestOptions: RequestOptions(path: '/'),
          ),
        )),
        isTrue,
      );
    });
  });

  group('youtube stream guards', () {
    test('youtubeMimeCompatible', () {
      const v = 'https://x/videoplayback?mime=video%2Fmp4';
      const a = 'https://x/videoplayback?mime=audio%2Fmp4';
      expect(orch.youtubeMimeCompatible(v, v), isTrue);
      expect(orch.youtubeMimeCompatible(v, a), isFalse);
      expect(orch.youtubeMimeCompatible('https://x/a', v), isTrue);
    });

    test('youtubeStreamRequiresMuxing', () {
      expect(orch.youtubeStreamRequiresMuxing('video_only'), isTrue);
      expect(orch.youtubeStreamRequiresMuxing('video'), isTrue);
      expect(orch.youtubeStreamRequiresMuxing(' VIDEO_ONLY '), isTrue);
      expect(orch.youtubeStreamRequiresMuxing('combined'), isFalse);
      expect(orch.youtubeStreamRequiresMuxing(null), isFalse);
    });

    test('shouldRejectResolvedYoutubeUrl', () {
      expect(orch.shouldRejectResolvedYoutubeUrl(null), isTrue);
      expect(orch.shouldRejectResolvedYoutubeUrl('   '), isTrue);
      expect(
        orch.shouldRejectResolvedYoutubeUrl(
          'https://www.youtube.com/watch?v=abc',
        ),
        isTrue,
      );
      expect(
        orch.shouldRejectResolvedYoutubeUrl(
          'https://rr1.googlevideo.com/videoplayback?itag=22',
        ),
        isFalse,
      );
    });

    test('isYouTubePageUrl', () {
      expect(DownloadOrchestrator.isYouTubePageUrl(''), isFalse);
      expect(
        DownloadOrchestrator.isYouTubePageUrl('https://example.com'),
        isFalse,
      );
      expect(
        DownloadOrchestrator.isYouTubePageUrl('https://youtu.be/abcdefghijk'),
        isTrue,
      );
      expect(
        DownloadOrchestrator.isYouTubePageUrl('https://www.youtube.com/'),
        isTrue,
      );
      expect(
        DownloadOrchestrator.isYouTubePageUrl(
          'https://youtube.com/videoplayback?itag=22',
        ),
        isFalse,
      );
    });
  });

  group('cancel outcome helpers', () {
    test('cancelPauseOutcome maps reasons', () {
      expect(DownloadOrchestrator.cancelPauseOutcome('paused:user').isUserPause,
          isTrue);
      expect(
        DownloadOrchestrator.cancelPauseOutcome('networkLost').waitingMessage,
        DownloadStatusMessages.waitingNetwork,
      );
      expect(
        DownloadOrchestrator.cancelPauseOutcome('network_lost').waitingMessage,
        DownloadStatusMessages.waitingNetwork,
      );
      expect(
        DownloadOrchestrator.cancelPauseOutcome('wifi_only_pause').waitingMessage,
        DownloadStatusMessages.waitingWifi,
      );
      final other = DownloadOrchestrator.cancelPauseOutcome('something');
      expect(other.isUserPause, isFalse);
      expect(other.waitingMessage, isNull);
      expect(
        DownloadOrchestrator.cancelPauseOutcome(null, alreadyUserPaused: true)
            .isUserPause,
        isTrue,
      );
    });

    test('cancelReasonOf reads error and cancel token', () {
      final token = CancelToken();
      final err = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.cancel,
        error: 'paused:user',
      );
      expect(DownloadOrchestrator.cancelReasonOf(err, token), 'paused:user');

      final token2 = CancelToken();
      final err2 = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.cancel,
        message: 'network_lost',
      );
      expect(DownloadOrchestrator.cancelReasonOf(err2, token2), 'network_lost');
      expect(
        DownloadOrchestrator.cancelReasonOf(Exception('x'), token),
        isNull,
      );
    });

    test('retryBackoffSeconds caps and clamps', () {
      expect(DownloadOrchestrator.retryBackoffSeconds(0, 3), 0);
      expect(DownloadOrchestrator.retryBackoffSeconds(-1, 0), 0);
      expect(DownloadOrchestrator.retryBackoffSeconds(5, -2), 5);
      expect(DownloadOrchestrator.retryBackoffSeconds(5, 3), 40);
      expect(DownloadOrchestrator.retryBackoffSeconds(5, 20), 300);
    });
  });

  group('normalizeChunks', () {
    test('returns input for empty or zero-size', () {
      expect(DownloadOrchestrator.normalizeChunks([], 100, 0), isEmpty);
      final chunks = [0.5, 0.5];
      expect(DownloadOrchestrator.normalizeChunks(chunks, 0, 0), chunks);
    });

    test('sanitises NaN / Infinity', () {
      final result = DownloadOrchestrator.normalizeChunks(
        [double.nan, double.infinity, 0.5],
        1000,
        1000,
      );
      expect(result.length, 3);
      expect(result.every((c) => c.isFinite), isTrue);
    });

    test('locks completed chunks and re-distributes the rest', () {
      final result = DownloadOrchestrator.normalizeChunks(
        [0.2, 0.3],
        1000,
        1000,
      );
      expect(result, [0.8, 1.0]);
    });

    test('keeps fully locked chunks when target is already met', () {
      final result = DownloadOrchestrator.normalizeChunks(
        [1.0, 0.0],
        1000,
        500,
      );
      expect(result, [1.0, 0.0]);
    });

    test('returns locked list when all unlocked are zero', () {
      final result = DownloadOrchestrator.normalizeChunks(
        [1.0, 0.0],
        1000,
        1000,
      );
      expect(result, [1.0, 0.0]);
    });
  });

  group('cookie cache eviction', () {
    test('evicts stale entries and keeps fresh ones', () {
      final stale = DateTime.now().subtract(const Duration(minutes: 10));
      orch.cookieCache['stale'] = (cookie: 'a', timestamp: stale);
      orch.cookieCache['fresh'] = (cookie: 'b', timestamp: DateTime.now());
      orch.evictStaleCookies();
      expect(orch.cookieCache.containsKey('stale'), isFalse);
      expect(orch.cookieCache.containsKey('fresh'), isTrue);
    });

    test('evicts the oldest entry when at capacity', () {
      final oldest = DateTime.now().subtract(const Duration(minutes: 4));
      orch.cookieCache['oldest'] = (cookie: 'a', timestamp: oldest);
      for (var i = 0; i < 50; i++) {
        orch.cookieCache['s$i'] = (cookie: 'c', timestamp: DateTime.now());
      }
      orch.evictStaleCookies();
      expect(orch.cookieCache.containsKey('oldest'), isFalse);
    });
  });

  group('pending progress flush', () {
    test('flushes downloading tasks and drops stale entries', () async {
      host.tasks['a'] = _task('a', downloadedBytes: 10);
      host.tasks['b'] = _task('b', status: DownloadStatus.paused);
      host.pendingProgressUpdates.addAll(['a', 'b']);
      await orch.flushPendingProgressToDatabase();
      expect(host.flushed, ['a']);
      expect(host.pendingProgressUpdates, isEmpty);
    });
  });

  group('failTaskIfNoRetryScheduled', () {
    test('keeps queued task when a retry timer exists', () async {
      host.tasks['a'] = _task('a', status: DownloadStatus.queued);
      host.retryTimers['a'] = Timer(const Duration(seconds: 5), () {});
      await orch.failTaskIfNoRetryScheduled('a');
      expect(host.saved, isEmpty);
      host.retryTimers['a']!.cancel();
    });

    test('fails queued task without a retry timer', () async {
      host.tasks['a'] = _task('a', status: DownloadStatus.queued);
      await orch.failTaskIfNoRetryScheduled('a');
      expect(host.tasks['a']!.status, DownloadStatus.failed);
    });
  });

  group('validateResumeState', () {
    test('torrent with missing save directory fails', () async {
      final task = _task(
        't1',
        status: DownloadStatus.paused,
        url: 'magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709',
        savePath: 'build/definitely-missing-${DateTime.now().microsecondsSinceEpoch}',
        torrentFiles: [
          {'name': 'a.bin', 'length': 1},
        ],
      );
      final result = await orch.validateResumeState(task);
      expect(result.status, DownloadStatus.failed);
      expect(result.errorMessage, contains('save directory missing'));
    });

    test('torrent with invalid file entries clears torrent files', () async {
      final dir = Directory.systemTemp.createTempSync('dmx_orch_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final task = _task(
        't2',
        status: DownloadStatus.paused,
        url: 'magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709',
        savePath: dir.path,
        torrentFiles: [
          {'name': '', 'length': -1},
        ],
      );
      final result = await orch.validateResumeState(task);
      expect(result.torrentFiles, anyOf(isNull, isEmpty));
    });

    test('http task with no progress is returned unchanged', () async {
      final task = _task('h1', status: DownloadStatus.paused);
      final result = await orch.validateResumeState(task);
      expect(result.status, DownloadStatus.paused);
    });
  });

  group('cleanup helpers', () {
    test('cleanupTempFiles deletes sidecars', () async {
      final dir = Directory.systemTemp.createTempSync('dmx_clean_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final temp = '${dir.path}/file.dmxpart';
      File('$temp.journal').writeAsStringSync('j');
      File('$temp.dmxdone').writeAsStringSync('d');
      File(temp).writeAsStringSync('part');
      final task = _task('c1', tempFilePath: temp);

      await orch.cleanupTempFiles(task);
      expect(File('$temp.journal').existsSync(), isFalse);
      expect(File(temp).existsSync(), isFalse);
    });

    test('cleanupTempFiles with preserveParts keeps the main part', () async {
      final dir = Directory.systemTemp.createTempSync('dmx_clean_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final temp = '${dir.path}/file.dmxpart';
      File(temp).writeAsStringSync('part');
      final task = _task('c2', tempFilePath: temp);
      await orch.cleanupTempFiles(task, preserveParts: true);
      expect(File(temp).existsSync(), isTrue);
    });

    test('cleanupHttpArtifacts removes part files', () async {
      final dir = Directory.systemTemp.createTempSync('dmx_clean_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final temp = '${dir.path}/file.dmxpart';
      File('$temp.part0').writeAsStringSync('0');
      File('$temp.part1').writeAsStringSync('1');
      final task = _task('c3', tempFilePath: temp).copyWith(threadCount: 2);
      await orch.cleanupHttpArtifacts(task);
      expect(File('$temp.part0').existsSync(), isFalse);
      expect(File('$temp.part1').existsSync(), isFalse);
    });

    test('cleanupAllArtifacts routes torrents to torrent cleanup', () async {
      final dir = Directory.systemTemp.createTempSync('dmx_clean_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final temp = '${dir.path}/t.torrent';
      File('$temp.torrent').writeAsStringSync('x');
      final task = _task('c4', tempFilePath: temp, torrentFiles: [
        {'name': 'a', 'length': 1},
      ]);
      await orch.cleanupAllArtifacts(task);
      expect(File('$temp.torrent').existsSync(), isFalse);
    });

    test('cleanupPartFiles delegates to cleanupAllArtifacts', () async {
      final dir = Directory.systemTemp.createTempSync('dmx_clean_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final temp = '${dir.path}/p.dmxpart';
      File('$temp.journal').writeAsStringSync('j');
      final task = _task('c5', tempFilePath: temp);
      await orch.cleanupPartFiles(task);
      expect(File('$temp.journal').existsSync(), isFalse);
    });
  });

  group('static classifiers on the provider surface', () {
    test('retryBackoffSeconds stays bounded', () {
      for (var i = 0; i < 30; i++) {
        expect(DownloadOrchestrator.retryBackoffSeconds(10, i),
            lessThanOrEqualTo(300));
      }
    });
  });
}
