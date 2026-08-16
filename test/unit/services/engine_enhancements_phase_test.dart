import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dmx/core/di/injection.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/download_progress_handler.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:dmx/core/services/yt_counterpart_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Fix 1: YouTube Counterpart Live Tracking Gap', () {
    test('fetches live counterpart bytes via YtCounterpartCoordinator', () async {
      final coord = YtCounterpartCoordinator();
      if (getIt.isRegistered<YtCounterpartCoordinator>()) {
        getIt.unregister<YtCounterpartCoordinator>();
      }
      getIt.registerSingleton<YtCounterpartCoordinator>(coord);

      const mainTaskId = 'yt-video-101';
      const counterpartTaskId = 'yt-audio-101';

      coord.registerCounterpart(mainTaskId, counterpartTaskId);
      coord.updateLiveBytes(counterpartTaskId, 1024000);

      DownloadProgress? captured;
      final cancelToken = CancelToken();
      final handler = DownloadProgressHandler(
        taskId: mainTaskId,
        resolvedFileName: 'video.mp4',
        resolvedSupportsResume: true,
        cancelToken: cancelToken,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 5000000,
        ytCounterpartDownloadedBytes: 0,
        isTorrent: false,
        getEffectiveIntervalMs: () => 100,
        lastDownloadedBytes: 0,
        lastFileSize: 10000000,
        onProgress: (p) => captured = p,
      );

      await handler.handleWorkerProgress({
        'downloadedBytes': 2000000,
        'fileSize': 10000000,
        'speed': 500000.0,
        'statusMessage': 'Downloading',
        'cycleState': CycleState.downloading,
      });

      expect(captured, isNotNull);
      expect(captured!.ytCounterpartDownloadedBytes, equals(1024000));
    });
  });

  group('Fix 2: Large Torrent Adaptive Sync Intervals', () {
    test('returns 120 seconds interval for torrents with >10,000 files', () {
      expect(
        TorrentDownloadHandler.computeAdaptiveSyncInterval(100),
        equals(const Duration(seconds: 5)),
      );
      expect(
        TorrentDownloadHandler.computeAdaptiveSyncInterval(1500),
        equals(const Duration(seconds: 30)),
      );
      expect(
        TorrentDownloadHandler.computeAdaptiveSyncInterval(6000),
        equals(const Duration(seconds: 45)),
      );
      expect(
        TorrentDownloadHandler.computeAdaptiveSyncInterval(15000),
        equals(const Duration(seconds: 120)),
      );
    });
  });

  group('Fix 5: Disk Space Check for Torrent Pause Reason', () {
    test('PauseReason.diskFull is supported in enum and parses correctly', () {
      expect(PauseReason.fromName('diskFull'), equals(PauseReason.diskFull));
      expect(PauseReason.fromName('disk_full'), equals(PauseReason.diskFull));
    });
  });

  group('Fix 6: State Store SHA-256 Strict Dedup Default', () {
    test('stateSaveStrictDedup defaults to true', () {
      expect(StateStore.stateSaveStrictDedup, isTrue);
    });

    test('stateSaveStrictDedup skips redundant saves but allows status changes and durable saves', () async {
      final tempFile = File('test_state_dedup.tmp');
      try {
        final state1 = TransferState(
          status: DmxStateStatus.active,
          totalSize: 1000,
          threadCount: 1,
          chunks: [ChunkState(start: 0, end: 1000, downloaded: 100)],
        );

        await StateStore.save(tempFile.path, state1, durable: false);
        final loaded1 = await StateStore.load(tempFile.path);
        expect(loaded1, isNotNull);
        expect(loaded1!.downloadedBytes, equals(100));

        // Save identical state (non-durable, same status) -> should be deduplicated
        await StateStore.save(tempFile.path, state1, durable: false);

        // Status change -> should bypass dedup and save
        final state2 = TransferState(
          status: DmxStateStatus.paused,
          totalSize: 1000,
          threadCount: 1,
          chunks: [ChunkState(start: 0, end: 1000, downloaded: 100)],
        );
        await StateStore.save(tempFile.path, state2, durable: false);
        final loaded2 = await StateStore.load(tempFile.path);
        expect(loaded2?.status, equals(DmxStateStatus.paused));

        // Durable save -> should bypass dedup and save
        final state3 = TransferState(
          status: DmxStateStatus.paused,
          totalSize: 1000,
          threadCount: 1,
          chunks: [ChunkState(start: 0, end: 1000, downloaded: 200)],
        );
        await StateStore.save(tempFile.path, state3, durable: true);
        final loaded3 = await StateStore.load(tempFile.path);
        expect(loaded3?.downloadedBytes, equals(200));
      } finally {
        await StateStore.remove(tempFile.path);
        if (await tempFile.exists()) await tempFile.delete();
      }
    });
  });
}
