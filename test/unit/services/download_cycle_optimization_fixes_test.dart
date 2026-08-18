import 'package:dio/dio.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/engine/download_progress_handler.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Download Cycle State & Data Tracking Optimizations', () {
    test('Fix 1: YouTube counterpart status disambiguates starting vs retrying', () async {
      DownloadProgress? lastEmitted;
      final handler = DownloadProgressHandler(
        taskId: 'yt_fix1_test',
        onProgress: (p) => lastEmitted = p,
        cancelToken: CancelToken(),
        resolvedFileName: 'video.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 50000,
        ytCounterpartDownloadedBytes: 0,
        isTorrent: false,
        getEffectiveIntervalMs: () => 0,
        lastDownloadedBytes: 100,
        lastFileSize: 1000,
      );

      // <= 30s -> CycleState.starting, 'Preparing counterpart stream…'
      handler.counterpartWaitStartForTesting =
          DateTime.now().subtract(const Duration(seconds: 15));
      await handler.handleWorkerProgress(
        {
          'downloadedBytes': 100,
          'fileSize': 1000,
          'cycleState': CycleState.downloading,
        },
        isCounterpartUnregistered: true,
      );
      expect(lastEmitted?.cycleState, equals(CycleState.starting));
      expect(lastEmitted?.statusMessage, equals('Preparing counterpart stream…'));

      // > 30s -> CycleState.retrying, 'Retrying counterpart stream…'
      handler.counterpartWaitStartForTesting =
          DateTime.now().subtract(const Duration(seconds: 45));
      await handler.handleWorkerProgress(
        {
          'downloadedBytes': 100,
          'fileSize': 1000,
          'cycleState': CycleState.downloading,
        },
        isCounterpartUnregistered: true,
      );
      expect(lastEmitted?.cycleState, equals(CycleState.retrying));
      expect(lastEmitted?.statusMessage, equals('Retrying counterpart stream…'));

      handler.dispose();
    });

    test('Fix 3: URL expiration sliding window bypass prevented by total retry limit', () {
      final handler = DownloadProgressHandler(
        taskId: 'yt_fix3_test',
        onProgress: (_) {},
        cancelToken: CancelToken(),
        resolvedFileName: 'video.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 50000,
        ytCounterpartDownloadedBytes: 0,
        isTorrent: false,
        getEffectiveIntervalMs: () => 0,
        lastDownloadedBytes: 100,
        lastFileSize: 1000,
      );

      // Emulate 4 retries spaced 6 minutes apart (so 5min window resets each time)
      for (var i = 0; i < 4; i++) {
        handler.urlExpireWindowStartForTesting =
            DateTime.now().subtract(const Duration(minutes: 6));
        handler.handleUrlExpired();
      }
      expect(handler.totalUrlExpireRetriesForTesting, equals(4));

      // 5th retry must throw DownloadIntegrityException regardless of window
      handler.urlExpireWindowStartForTesting =
          DateTime.now().subtract(const Duration(minutes: 6));
      expect(
        () => handler.handleUrlExpired(),
        throwsA(isA<DownloadIntegrityException>().having(
          (e) => e.message,
          'message',
          contains('Exceeded maximum total URL expiration retries'),
        )),
      );

      handler.dispose();
    });

    test('Fix 5: Chunk detail hash differs when index changes despite identical metrics', () async {
      final handler = DownloadProgressHandler(
        taskId: 'chunk_hash_test',
        onProgress: (_) {},
        cancelToken: CancelToken(),
        resolvedFileName: 'file.bin',
        resolvedSupportsResume: true,
        ytStreamKind: null,
        ytCounterpartSize: null,
        ytCounterpartDownloadedBytes: null,
        isTorrent: false,
        torrentId: null,
        getEffectiveIntervalMs: () => 0,
        lastDownloadedBytes: 100,
        lastFileSize: 1000,
      );

      // Chunk with index 0
      await handler.handleWorkerProgress(
        {
          'downloadedBytes': 250,
          'fileSize': 1000,
          'chunkDetails': [
            {
              'index': 0,
              'start': 0,
              'end': 500,
              'downloaded': 250,
              'size': 501,
              'ratio': 0.5,
            }
          ],
        },
      );
      final hash0 = handler.chunkFingerprint;

      // Chunk with index 1 but identical range/metrics
      await handler.handleWorkerProgress(
        {
          'downloadedBytes': 250,
          'fileSize': 1000,
          'chunkDetails': [
            {
              'index': 1,
              'start': 0,
              'end': 500,
              'downloaded': 250,
              'size': 501,
              'ratio': 0.5,
            }
          ],
        },
      );
      final hash1 = handler.chunkFingerprint;

      expect(hash0, isNot(equals(0)));
      expect(hash1, isNot(equals(0)));
      expect(hash0, isNot(equals(hash1)));
      handler.dispose();
    });

    test('Fix 4: Torrent stall error flag prevents pause race', () {
      final handler = TorrentDownloadHandler();
      expect(handler.stallErrorEmittedForTesting, isFalse);

      handler.stallErrorEmittedForTesting = true;
      expect(handler.stallErrorEmittedForTesting, isTrue);

      handler.removeActiveTorrent(999);
      expect(handler.stallErrorEmittedForTesting, isFalse);
    });

    test('Fix 7: Torrent fetchingMetadata produces null file list & totals', () {
      // Simulate progress emitted during fetchingMetadata
      const progressWithFiles = DownloadProgress(
        downloadedBytes: 0,
        fileSize: 0,
        speed: 0,
        eta: null,
        cycleState: CycleState.fetchingMetadata,
        torrentFiles: [
          {'name': 'dummy.dat', 'length': 100, 'downloadedBytes': 0}
        ],
        totalFiles: 1,
        totalFileBytes: 100,
      );

      final sanitized = DownloadProgress(
        downloadedBytes: progressWithFiles.downloadedBytes,
        fileSize: progressWithFiles.fileSize,
        speed: progressWithFiles.speed,
        eta: progressWithFiles.eta,
        fileName: progressWithFiles.fileName,
        torrentFiles: null,
        totalFiles: null,
        completedFiles: null,
        totalFileBytes: null,
        downloadedFileBytes: null,
        cycleState: CycleState.fetchingMetadata,
      );

      expect(sanitized.torrentFiles, isNull);
      expect(sanitized.totalFiles, isNull);
      expect(sanitized.totalFileBytes, isNull);
    });
  });
}
