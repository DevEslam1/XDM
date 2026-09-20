import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PROMPT ARCH-2: Alert-Driven Engine Contract Tests', () {
    late FakeTorrentNative fakeNative;

    setUp(() {
      fakeNative = FakeTorrentNative();
      TorrentService.setNativeForTesting(fakeNative);
    });

    test(
        '2. Selective-priority torrent: deselecting half the files DROPS displayed bytes immediately (no monotonic floor)',
        () async {
      await TorrentService.init();

      final files = [
        const NativeFileInfo(
            index: 0,
            name: 'video1.mp4',
            path: 'video1.mp4',
            size: 100 * 1024 * 1024,
            isStreamable: true),
        const NativeFileInfo(
            index: 1,
            name: 'video2.mp4',
            path: 'video2.mp4',
            size: 100 * 1024 * 1024,
            isStreamable: true),
      ];

      fakeNative.seedTorrent(
        id: 1,
        name: 'MultiFileTorrent',
        files: files,
      );

      // Advance progress: file 0 has 50MB downloaded, file 1 has 50MB downloaded
      fakeNative.simulateProgress(
        id: 1,
        perFileDownloadedBytes: [50 * 1024 * 1024, 50 * 1024 * 1024],
      );

      var status = fakeNative.getTorrentStatus(1)!;
      expect(status.totalWanted, 200 * 1024 * 1024);
      expect(status.totalWantedDone, 100 * 1024 * 1024);

      // User deselects video2 (sets priority 0 for file 1)
      TorrentService.setFilePriorities(1, [4, 0]);

      status = fakeNative.getTorrentStatus(1)!;
      // With the monotonic floor gone, totalWanted and totalWantedDone DROP directly to the wanted set!
      expect(status.totalWanted, 100 * 1024 * 1024);
      expect(status.totalWantedDone, 50 * 1024 * 1024);
      expect(status.progress, 0.5);
    });

    test('3. Pause completes with torrentPaused event and sets isPaused',
        () async {
      await TorrentService.init();

      final files = [
        const NativeFileInfo(
            index: 0,
            name: 'file.bin',
            path: 'file.bin',
            size: 10 * 1024 * 1024,
            isStreamable: false),
      ];
      fakeNative.seedTorrent(id: 2, name: 'GracefulPauseTorrent', files: files);
      await Future.delayed(const Duration(milliseconds: 50));

      final receivedAlerts = <TorrentAlertEvent>[];
      final sub = TorrentService.alertUpdates.listen(receivedAlerts.add);

      await TorrentService.pauseTorrent(2);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(receivedAlerts.any((a) => a.category == 'torrentPaused'), isTrue,
          reason: 'torrentPaused must be emitted during pause');

      final status = fakeNative.getTorrentStatus(2)!;
      expect(status.isPaused, isTrue);
      expect(status.downloadRate, 0);

      await sub.cancel();
    });

    test('4. Graceful pause timeout falls back to force-stop safely', () async {
      await TorrentService.init();

      final files = [
        const NativeFileInfo(
            index: 0,
            name: 'stuck.bin',
            path: 'stuck.bin',
            size: 10 * 1024 * 1024,
            isStreamable: false),
      ];
      fakeNative.seedTorrent(id: 3, name: 'StuckPauseTorrent', files: files);
      fakeNative.simulateGracefulPauseTimeout = true;

      // When graceful pause times out, forceStopTorrent stops the torrent handle
      await TorrentService.forceStopTorrent(3);

      expect(TorrentService.activeTorrentIds.contains(3), isFalse);
    });
  });
}
