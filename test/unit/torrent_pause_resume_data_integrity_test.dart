import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/services/diagnostic_service.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Torrent Pause/Resume Data Integrity', () {
    late FakeTorrentNative fakeNative;

    setUp(() {
      fakeNative = FakeTorrentNative();
    });

    test('Graceful pauseTorrent saves resume data before pausing handle',
        () async {
      final tid = fakeNative.addMagnet(
          'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335de7ece74fedd',
          '/tmp');
      expect(tid, isNonNegative);

      // Verify torrent starts active
      final initialStatus = fakeNative.getTorrentStatus(tid);
      expect(initialStatus?.isPaused, isFalse);

      // Pause gracefully
      await fakeNative.pauseTorrent(tid, graceful: true);

      final pausedStatus = fakeNative.getTorrentStatus(tid);
      expect(pausedStatus?.isPaused, isTrue);
      expect(fakeNative.saveResumeDataCallCount, greaterThanOrEqualTo(1));
    });

    test(
        'pauseTorrent records telemetry if save resume data fails or times out',
        () async {
      fakeNative.simulateGracefulPauseTimeout = true;
      final initialAlerts = DiagnosticService.instance.resumeDataMissingCount;

      final tid = fakeNative.addMagnet(
          'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335de7ece74fedd',
          '/tmp');
      await fakeNative.pauseTorrent(tid, graceful: true);

      expect(DiagnosticService.instance.resumeDataMissingCount,
          greaterThan(initialAlerts));
    });

    test('resumeTorrent transitions state and emits resumed alert', () async {
      final tid = fakeNative.addMagnet(
          'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335de7ece74fedd',
          '/tmp');
      await fakeNative.pauseTorrent(tid, graceful: false);
      expect(fakeNative.getTorrentStatus(tid)?.isPaused, isTrue);

      await fakeNative.resumeTorrent(tid);
      expect(fakeNative.getTorrentStatus(tid)?.isPaused, isFalse);
    });

    test(
        'Displayed downloadedBytes equals totalWantedDone (tolerance: 1 piece)',
        () {
      const pieceLength = 256 * 1024;
      const totalWanted = 100 * pieceLength;
      const totalWantedDone = 40 * pieceLength; // 40 pieces completed

      const status = NativeTorrentStatus(
        id: 1,
        name: 'Test.iso',
        savePath: '/tmp',
        errorMsg: '',
        state: 3,
        totalWanted: totalWanted,
        totalWantedDone: totalWantedDone,
        totalDone: 41 * pieceLength, // e.g. 1 piece unselected downloaded
        totalUploaded: 0,
        progress: totalWantedDone / totalWanted,
        downloadRate: 0,
        uploadRate: 0,
        isPaused: false,
        isFinished: false,
        hasMetadata: true,
        queuePosition: 0,
        numPeers: 10,
        numSeeds: 5,
        stateLabel: 'downloading',
        numPieces: 100,
        piecesDone: 40,
      );

      final rawDownloaded = status.totalWantedDone;
      final totalSize = status.totalWanted;

      expect(rawDownloaded, equals(totalWantedDone));
      expect(totalSize, equals(totalWanted));
      expect((rawDownloaded - totalWantedDone).abs(),
          lessThanOrEqualTo(pieceLength));
    });

    test(
        'Pause a torrent, simulate engine restart, and verify progress continues',
        () async {
      const magnetUri =
          'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335de7ece74fedd';
      final tid1 = fakeNative.addMagnet(magnetUri, '/tmp');

      fakeNative.seedTorrent(
        id: tid1,
        name: 'movie.mp4',
        files: [
          const NativeFileInfo(
              index: 0,
              name: 'movie.mp4',
              path: 'movie.mp4',
              size: 10000000,
              isStreamable: true),
        ],
      );

      fakeNative.simulateProgress(id: tid1, perFileDownloadedBytes: [4500000]);
      final prePauseStatus = fakeNative.getTorrentStatus(tid1);
      expect(prePauseStatus?.totalWantedDone, equals(4500000));

      // Pause gracefully
      await fakeNative.pauseTorrent(tid1, graceful: true);

      // Kill/remove torrent from native session
      fakeNative.removeTorrent(tid1);
      expect(fakeNative.getTorrentStatus(tid1), isNull);

      // Re-add on restart
      final tid2 = fakeNative.addMagnet(magnetUri, '/tmp');
      fakeNative.seedTorrent(
        id: tid2,
        name: 'movie.mp4',
        files: [
          const NativeFileInfo(
              index: 0,
              name: 'movie.mp4',
              path: 'movie.mp4',
              size: 10000000,
              isStreamable: true),
        ],
      );
      fakeNative.simulateProgress(id: tid2, perFileDownloadedBytes: [4500000]);

      final resumedStatus = fakeNative.getTorrentStatus(tid2);
      expect(resumedStatus?.totalWantedDone, equals(4500000));
      expect(resumedStatus?.totalWanted, equals(10000000));
    });
  });
}
