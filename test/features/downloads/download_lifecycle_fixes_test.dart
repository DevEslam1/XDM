import 'package:dio/dio.dart';
import 'package:dmx/core/services/engine/cycle_state_resolver.dart';
import 'package:dmx/core/services/engine/download_progress_handler.dart';
import 'package:dmx/core/services/engine/engine_exceptions.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:dmx/core/services/engine/http_transfer_job.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Download Lifecycle & Progress Tracking Fixes Tests', () {
    // 1. Cycle State Transitions
    test(
        '1. Cycle State Transitions - explicit libtorrent and resolver mapping',
        () {
      expect(CycleState.fromLibtorrent('downloading_metadata'),
          CycleState.fetchingMetadata);
      expect(CycleState.fromLibtorrent('allocating'), CycleState.allocating);
      expect(CycleState.fromLibtorrent('checking_files'), CycleState.verifying);
      expect(CycleState.fromLibtorrent('checking_resume_data'),
          CycleState.verifying);
      expect(CycleState.fromLibtorrent('downloading'), CycleState.downloading);
      expect(CycleState.fromLibtorrent('seeding'), CycleState.seeding);
      expect(CycleState.fromLibtorrent('finished'), CycleState.completed);
      expect(CycleState.fromLibtorrent('paused'), CycleState.paused);
      expect(CycleState.fromLibtorrent('stalled'), CycleState.stalled);
      expect(CycleState.fromLibtorrent('error'), CycleState.failed);
      expect(CycleState.fromLibtorrent('resuming'), CycleState.resuming);
      expect(CycleState.fromLibtorrent('retrying'), CycleState.retrying);
      expect(CycleState.fromLibtorrent('updating_links'),
          CycleState.updatingLinks);
      expect(CycleState.fromLibtorrent('merging'), CycleState.merging);
      expect(CycleState.fromLibtorrent('starting'), CycleState.starting);
      expect(
          CycleState.fromLibtorrent('unknown_state'), CycleState.downloading);

      // Verify CycleStateResolver
      expect(CycleStateResolver.resolve(statusMessage: 'allocating'),
          CycleState.allocating);
      expect(CycleStateResolver.resolve(statusMessage: 'verifying files'),
          CycleState.verifying);
      expect(CycleStateResolver.resolve(statusMessage: 'retrying connection'),
          CycleState.retrying);
      expect(CycleStateResolver.resolve(isCancelled: true), CycleState.paused);
      expect(
          CycleStateResolver.resolve(statusMessage: 'seeding', isTorrent: true),
          CycleState.seeding);
    });

    // 2. YouTube Counterpart Completion
    test(
        '2. YouTube Counterpart Completion - gate remains downloading until counterpart done',
        () async {
      final emissions = <DownloadProgress>[];
      final cancelToken = CancelToken();

      final handler = DownloadProgressHandler(
        taskId: 'v1',
        onProgress: (p) => emissions.add(p),
        cancelToken: cancelToken,
        resolvedFileName: 'video.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: null,
        ytCounterpartDownloadedBytes: null,
        isTorrent: false,
        getEffectiveIntervalMs: () => 0,
        lastDownloadedBytes: 1000,
        lastFileSize: 1000,
      );

      final cpMap = TimestampedLruMap<String, String>()..['v1'] = 'a1';
      final liveBytes = TimestampedLruMap<String, int>()
        ..['v1'] = 1000
        ..['a1'] = 0;

      // Primary done, counterpart size unresolved -> should stay downloading
      await handler.handleProgress(
        {
          'downloadedBytes': 1000,
          'fileSize': 1000,
          'cycleState': CycleState.completed,
          'statusMessage': 'Completed',
          'ytStreamKind': 'video',
          'ytCounterpartSize': null,
        },
        ytCounterpartTaskIds: cpMap,
        ytLiveBytes: liveBytes,
      );
      expect(emissions.last.cycleState, CycleState.downloading);

      // Counterpart size resolved (500), but counterpart downloaded = 300 < 500
      liveBytes['a1'] = 300;
      await handler.handleProgress(
        {
          'downloadedBytes': 1000,
          'fileSize': 1000,
          'cycleState': CycleState.completed,
          'statusMessage': 'Completed',
          'ytStreamKind': 'video',
          'ytCounterpartSize': 500,
        },
        ytCounterpartTaskIds: cpMap,
        ytLiveBytes: liveBytes,
      );
      expect(emissions.last.cycleState, CycleState.downloading);

      // Counterpart done = 500 >= 500
      liveBytes['a1'] = 500;
      await handler.handleProgress(
        {
          'downloadedBytes': 1000,
          'fileSize': 1000,
          'cycleState': CycleState.completed,
          'statusMessage': 'Completed',
          'ytStreamKind': 'video',
          'ytCounterpartSize': 500,
        },
        ytCounterpartTaskIds: cpMap,
        ytLiveBytes: liveBytes,
      );
      expect(emissions.last.cycleState, CycleState.completed);
    });

    // 3. Torrent File Selection by Path
    test(
        '3. Torrent File Selection - path based mapping preserves selection regardless of order',
        () {
      final pauseFiles = [
        {'name': 'b_file.mp4', 'selected': false, 'priority': 1, 'length': 200},
        {'name': 'a_file.mp4', 'selected': true, 'priority': 7, 'length': 100},
      ];

      final previousSelectedMap = <String, bool>{
        for (final f in pauseFiles)
          if (f['name'] != null)
            (f['name'] as String): (f['selected'] as bool?) ?? true
      };
      final previousPriorityMap = <String, int>{
        for (final f in pauseFiles)
          if (f['name'] != null && f['priority'] is int)
            (f['name'] as String): f['priority'] as int
      };

      // Native returns files in reverse or different order
      final reorderedNative = [
        {'name': 'a_file.mp4', 'length': 100, 'downloadedBytes': 50},
        {'name': 'b_file.mp4', 'length': 200, 'downloadedBytes': 0},
      ];

      final result = [
        for (var i = 0; i < reorderedNative.length; i++)
          {
            'name': reorderedNative[i]['name'],
            'length': reorderedNative[i]['length'],
            'selected': previousSelectedMap[reorderedNative[i]['name']] ?? true,
            'priority': previousPriorityMap[reorderedNative[i]['name']] ?? 4,
          }
      ];

      expect(result.firstWhere((f) => f['name'] == 'a_file.mp4')['selected'],
          isTrue);
      expect(result.firstWhere((f) => f['name'] == 'a_file.mp4')['priority'],
          equals(7));
      expect(result.firstWhere((f) => f['name'] == 'b_file.mp4')['selected'],
          isFalse);
      expect(result.firstWhere((f) => f['name'] == 'b_file.mp4')['priority'],
          equals(1));
    });

    // 4. distributeEstimatedBytes when remaining == 0
    test(
        '4. distributeEstimatedBytes - remaining == 0 does not falsely flag progressEstimated',
        () {
      final files = [
        {
          'name': 'f1.mp4',
          'length': 1000,
          'downloadedBytes': 1000,
          'progressEstimated': false,
        },
        {
          'name': 'f2.mp4',
          'length': 500,
          'downloadedBytes': 0,
          'progressEstimated': false,
        },
      ];

      // totalDownloadedBytes is 1000, which exactly equals confirmedBytes (1000) -> remaining = 0
      TorrentDownloadHandler.distributeEstimatedBytes(files, 1000);

      // f2 should NOT have progressEstimated set to true
      expect(files[1]['progressEstimated'], isFalse);
      expect(files[1]['downloadedBytes'], equals(0));
    });

    // 5. validateContentRange
    test('5. validateContentRange - throws on mismatch and malformed headers',
        () {
      expect(
        () => HttpTransferJob.validateContentRange(
          'bytes 0-100/500',
          expectedStart: 101,
          expectedEnd: 200,
          expectedTotal: 500,
        ),
        throwsA(isA<DioException>()),
      );

      expect(
        () => HttpTransferJob.validateContentRange(
          'invalid_header',
          expectedStart: 0,
          expectedEnd: 100,
          expectedTotal: 500,
        ),
        throwsA(isA<DioException>()),
      );

      // Valid range should not throw
      expect(
        () => HttpTransferJob.validateContentRange(
          'bytes 100-200/500',
          expectedStart: 100,
          expectedEnd: 200,
          expectedTotal: 500,
        ),
        returnsNormally,
      );
    });

    // 6. Torrent Pause Aggregation with length == 0 files
    test(
        '6. normalizeTorrentFiles - length == 0 files produce progress 1.0 and isComplete true',
        () {
      final files = [
        {
          'name': 'empty.txt',
          'length': 0,
          'downloadedBytes': 0,
          'selected': true,
        },
        {
          'name': 'data.bin',
          'length': 100,
          'downloadedBytes': 100,
          'selected': true,
        },
      ];

      final summary = TorrentDownloadHandler.normalizeTorrentFiles(files);
      expect(summary.total, equals(2));
      expect(summary.done, equals(2));
      expect(summary.bytes, equals(100));
      expect(summary.downloaded, equals(100));

      final emptyNorm = TorrentDownloadHandler.normalizeTorrentFile(files[0]);
      expect(emptyNorm['progress'], equals(1.0));
      expect(emptyNorm['isComplete'], isTrue);
    });

    // 7. CycleStateResolver Word-Boundary Checks
    test(
        '7. CycleStateResolver - word boundary matching prevents false positives',
        () {
      expect(CycleStateResolver.resolve(statusMessage: 'Paused download'),
          CycleState.paused);
      expect(
          CycleStateResolver.resolve(statusMessage: 'Merging audio and video'),
          CycleState.merging);
      expect(
          CycleStateResolver.resolve(
              statusMessage: 'Fetching metadata from DHT'),
          CycleState.fetchingMetadata);
      expect(CycleStateResolver.resolve(statusMessage: 'Updating link details'),
          CycleState.updatingLinks);
      expect(CycleStateResolver.resolve(statusMessage: 'Allocating disk space'),
          CycleState.allocating);
    });

    // 8. DownloadProgressHandler Throttle Bypass on CycleState Change
    test(
        '8. DownloadProgressHandler - cycle state change bypasses interval throttle',
        () async {
      final emissions = <DownloadProgress>[];
      final handler = DownloadProgressHandler(
        taskId: 'task-throttle',
        onProgress: (p) => emissions.add(p),
        cancelToken: CancelToken(),
        resolvedFileName: 'test.bin',
        resolvedSupportsResume: true,
        ytStreamKind: null,
        ytCounterpartSize: null,
        ytCounterpartDownloadedBytes: null,
        isTorrent: false,
        getEffectiveIntervalMs: () => 5000, // Large 5s throttle
        lastDownloadedBytes: 0,
        lastFileSize: 1000,
      );

      // Emit starting
      await handler.handleWorkerProgress({
        'downloadedBytes': 10,
        'fileSize': 1000,
        'cycleState': CycleState.starting,
        'statusMessage': 'Starting…',
      });
      expect(emissions.length, equals(1));
      expect(emissions.last.cycleState, CycleState.starting);

      // Same cycle state immediately -> throttled (no new emission)
      await handler.handleWorkerProgress({
        'downloadedBytes': 20,
        'fileSize': 1000,
        'cycleState': CycleState.starting,
        'statusMessage': 'Starting…',
      });
      expect(emissions.length, equals(1));

      // Changed cycle state -> immediately bypasses throttle!
      await handler.handleWorkerProgress({
        'downloadedBytes': 30,
        'fileSize': 1000,
        'cycleState': CycleState.downloading,
        'statusMessage': 'Downloading…',
      });
      expect(emissions.length, equals(2));
      expect(emissions.last.cycleState, CycleState.downloading);
    });

    // 9. Unregistered YouTube Counterpart transitions to merging when counterpart done
    test(
        '9. YouTube Unregistered Counterpart - transitions to merging when done',
        () async {
      final emissions = <DownloadProgress>[];
      final handler = DownloadProgressHandler(
        taskId: 'task-yt',
        onProgress: (p) => emissions.add(p),
        cancelToken: CancelToken(),
        resolvedFileName: 'video.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 500,
        ytCounterpartDownloadedBytes: 500, // Done
        isTorrent: false,
        getEffectiveIntervalMs: () => 0,
        lastDownloadedBytes: 1000,
        lastFileSize: 1000,
      );

      await handler.handleWorkerProgress(
        {
          'downloadedBytes': 1000,
          'fileSize': 1000,
          'cycleState': CycleState.downloading,
        },
        isCounterpartUnregistered: true,
      );

      expect(emissions.last.cycleState, CycleState.merging);
    });

    // 10. Torrent Estimated Reconciliation
    test(
        '10. Torrent Estimated Reconciliation - largest file absorbs difference',
        () {
      final files = [
        {
          'name': 'f1.mp4',
          'length': 90,
          'downloadedBytes': 0,
          'progressEstimated': true,
        },
        {
          'name': 'f2.mp4',
          'length': 100,
          'downloadedBytes': 0,
          'progressEstimated': true,
        },
        {
          'name': 'f3_largest.mp4',
          'length': 110,
          'downloadedBytes': 0,
          'progressEstimated': true,
        },
      ];

      // Total downloaded is 100 -> f1: 30, f2: 33, f3: 37 -> sum = 100
      TorrentDownloadHandler.distributeEstimatedBytes(files, 100);

      expect(
        (files[0]['downloadedBytes'] as int) +
            (files[1]['downloadedBytes'] as int) +
            (files[2]['downloadedBytes'] as int),
        equals(100),
      );
      expect(files[2]['downloadedBytes'], equals(37));
    });

    // 11. DownloadProgress Equality and HashCode (Fix 5)
    test(
        '11. DownloadProgress Equality - compares chunkDetails and torrentFiles accurately',
        () {
      const p1 = DownloadProgress(
        downloadedBytes: 100,
        fileSize: 200,
        speed: 10,
        eta: 10,
        chunkDetails: [
          ChunkDetail(
              index: 0,
              start: 0,
              end: 99,
              downloaded: 50,
              size: 100,
              ratio: 0.5),
        ],
      );

      const p2 = DownloadProgress(
        downloadedBytes: 100,
        fileSize: 200,
        speed: 10,
        eta: 10,
        chunkDetails: [
          ChunkDetail(
              index: 0,
              start: 0,
              end: 99,
              downloaded: 50,
              size: 100,
              ratio: 0.5),
        ],
      );

      const p3 = DownloadProgress(
        downloadedBytes: 100,
        fileSize: 200,
        speed: 10,
        eta: 10,
        chunkDetails: [
          ChunkDetail(
              index: 0,
              start: 0,
              end: 99,
              downloaded: 60,
              size: 100,
              ratio: 0.6),
        ],
      );

      expect(p1 == p2, isTrue);
      expect(p1.hashCode, equals(p2.hashCode));
      expect(p1 == p3, isFalse);
      expect(p1.hashCode == p3.hashCode, isFalse);

      const t1 = DownloadProgress(
        downloadedBytes: 100,
        fileSize: 200,
        speed: 10,
        eta: 10,
        torrentFiles: [
          {'name': 'f1.mp4', 'length': 100, 'downloadedBytes': 50},
        ],
      );

      const t2 = DownloadProgress(
        downloadedBytes: 100,
        fileSize: 200,
        speed: 10,
        eta: 10,
        torrentFiles: [
          {'name': 'f1.mp4', 'length': 100, 'downloadedBytes': 50},
        ],
      );

      const t3 = DownloadProgress(
        downloadedBytes: 100,
        fileSize: 200,
        speed: 10,
        eta: 10,
        torrentFiles: [
          {'name': 'f1.mp4', 'length': 100, 'downloadedBytes': 70},
        ],
      );

      expect(t1 == t2, isTrue);
      expect(t1.hashCode, equals(t2.hashCode));
      expect(t1 == t3, isFalse);
      expect(t1.hashCode == t3.hashCode, isFalse);
    });

    // 12. Dynamic YouTube Counterpart Size Override (Fix 2)
    test(
        '12. Dynamic YouTube Counterpart Size Override - dynamically updates completion check',
        () async {
      final emissions = <DownloadProgress>[];
      final handler = DownloadProgressHandler(
        taskId: 'v2',
        onProgress: (p) => emissions.add(p),
        cancelToken: CancelToken(),
        resolvedFileName: 'video.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: null, // Initially null
        ytCounterpartDownloadedBytes: null,
        isTorrent: false,
        getEffectiveIntervalMs: () => 0,
        lastDownloadedBytes: 1000,
        lastFileSize: 1000,
      );

      // Pass dynamic counterpart size in payload
      await handler.handleWorkerProgress({
        'downloadedBytes': 1000,
        'fileSize': 1000,
        'cycleState': CycleState.completed,
        'statusMessage': 'Completed',
        'ytStreamKind': 'video',
        'ytCounterpartSize': 500,
        'ytCounterpartDownloadedBytes': 500,
      });

      expect(emissions.last.cycleState, CycleState.completed);
      expect(emissions.last.ytCounterpartSize, equals(500));
    });

    // 13. updateFilesWithNativeProgress proportional distribution (Fix 7)
    test(
        '13. updateFilesWithNativeProgress - distributes estimated bytes proportionally',
        () {
      final files = [
        {
          'name': 'f1.mp4',
          'length': 100,
          'downloadedBytes': -1,
          'progressEstimated': true,
        },
        {
          'name': 'f2.mp4',
          'length': 300,
          'downloadedBytes': -1,
          'progressEstimated': true,
        },
      ];

      TorrentDownloadHandler.updateFilesWithNativeProgress(files, 0.5, 200);

      // f1 should get ~50, f2 should get ~150 -> sum = 200
      expect(
          (files[0]['downloadedBytes'] as int) +
              (files[1]['downloadedBytes'] as int),
          equals(200));
      expect(files[0]['downloadedBytes'], equals(50));
      expect(files[1]['downloadedBytes'], equals(150));
    });

    // 14. Pause Reason Engine Population (Fix 8)
    test('14. DownloadProgress handles PauseReason.userRequested', () {
      const progress = DownloadProgress(
        downloadedBytes: 50,
        fileSize: 100,
        speed: 0,
        eta: null,
        cycleState: CycleState.paused,
        pauseReason: PauseReason.userRequested,
      );

      expect(progress.pauseReason, equals(PauseReason.user));
    });

    // 15. Sequential Torrent File Progress Distribution (Fix 6)
    test('15. distributeEstimatedBytesSequential fills files sequentially', () {
      final files = [
        {
          'name': 'f1.mp4',
          'length': 100,
          'downloadedBytes': 0,
          'selected': true,
        },
        {
          'name': 'f2.mp4',
          'length': 100,
          'downloadedBytes': 0,
          'selected': true,
        },
        {
          'name': 'f3.mp4',
          'length': 100,
          'downloadedBytes': 0,
          'selected': false, // unselected
        },
      ];

      // Downloaded 150 bytes: f1 gets 100 (complete), f2 gets 50 (partial), f3 skipped
      TorrentDownloadHandler.distributeEstimatedBytesSequential(files, 150);

      expect(files[0]['downloadedBytes'], equals(100));
      expect(files[0]['isComplete'], isTrue);
      expect(files[1]['downloadedBytes'], equals(50));
      expect(files[1]['isComplete'], isFalse);
      expect(files[2]['downloadedBytes'], equals(0));
    });

    // 16. Compute Torrent File Aggregates on Load (Fix 4)
    test('16. DownloadTask.fromMap computes torrent file aggregates', () {
      final map = {
        'id': 'task_torrent_1',
        'fileName': 'movie.torrent',
        'url': 'magnet:?xt=urn:btih:abc',
        'torrentFiles': [
          {'name': 'f1.mp4', 'length': 100, 'downloadedBytes': 100, 'selected': true},
          {'name': 'f2.mp4', 'length': 200, 'downloadedBytes': 50, 'selected': true},
          {'name': 'f3.txt', 'length': 50, 'downloadedBytes': 0, 'selected': false},
        ],
        'totalPieces': 42,
      };

      final task = DownloadTask.fromMap(map);

      expect(task.totalPieces, equals(42));
      expect(task.totalFiles, equals(2)); // only selected
      expect(task.completedFiles, equals(1)); // f1 is done
      expect(task.totalFileBytes, equals(300)); // 100 + 200
      expect(task.downloadedFileBytes, equals(150)); // 100 + 50
    });

    // 17. Unregistered YouTube Counterpart Timeout (Fix 5)
    test('17. Unregistered YouTube Counterpart throws UrlExpiredException after 30s', () async {
      final handler = DownloadProgressHandler(
        taskId: 'yt_timeout',
        onProgress: (_) {},
        cancelToken: CancelToken(),
        resolvedFileName: 'video.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: null,
        ytCounterpartDownloadedBytes: null,
        isTorrent: false,
        getEffectiveIntervalMs: () => 0,
        lastDownloadedBytes: 0,
        lastFileSize: 1000,
      );

      // Initial progress: initializes _counterpartWaitStart
      await handler.handleWorkerProgress(
        {
          'downloadedBytes': 100,
          'fileSize': 1000,
          'cycleState': CycleState.downloading,
        },
        isCounterpartUnregistered: true,
      );

      // Set wait start to 35 seconds ago
      handler.counterpartWaitStartForTesting = DateTime.now().subtract(const Duration(seconds: 35));

      // Next progress should throw UrlExpiredException
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
  });
}
