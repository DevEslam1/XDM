import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/services/engine/torrent_session_events.dart';
import 'package:dmx/core/services/engine/torrent_session_state.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:dmx/core/services/torrent_models.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PROMPT ARCH-2: Alert-Driven Engine Contract Tests', () {
    late FakeTorrentNative fakeNative;

    setUp(() {
      fakeNative = FakeTorrentNative();
      TorrentService.setNativeForTesting(fakeNative);
    });

    test('1. Full alert -> event mapping table covered (including fastresumeRejected & torrentError)', () async {
      var state = const TorrentSessionState(torrentId: 1, name: 'TestTorrent');

      // 1a. metadataReceived
      final metadataEvent = MetadataReceivedEvent(
        torrentId: 1,
        timestamp: DateTime.now(),
        name: 'Resolved Torrent Name',
        totalWanted: 1000000,
        files: [
          {'name': 'file1.bin', 'length': 500000, 'selected': true, 'priority': 4},
          {'name': 'file2.bin', 'length': 500000, 'selected': true, 'priority': 4},
        ],
      );
      state = TorrentSessionState.reduce(state, metadataEvent);
      expect(state.name, 'Resolved Torrent Name');
      expect(state.hasMetadata, isTrue);
      expect(state.totalWanted, 1000000);
      expect(state.files.length, 2);

      // 1b. pieceFinished
      final pieceEvent = PieceFinishedEvent(
        torrentId: 1,
        timestamp: DateTime.now(),
        pieceIndex: 0,
        totalWantedDone: 250000,
        piecesHave: 1,
        piecesTotal: 4,
        pieceBitfield: [true, false, false, false],
      );
      state = TorrentSessionState.reduce(state, pieceEvent);
      expect(state.totalWantedDone, 250000);
      expect(state.piecesHave, 1);
      expect(state.piecesTotal, 4);
      expect(state.progress, 0.25);
      expect(state.pieceBitfield, [true, false, false, false]);

      // 1c. trackerReply
      final trackerReplyEvent = TrackerReplyEvent(
        torrentId: 1,
        timestamp: DateTime.now(),
        trackerUrl: 'http://tracker.test/announce',
        numPeers: 12,
      );
      state = TorrentSessionState.reduce(state, trackerReplyEvent);
      expect(state.numPeers, 12);

      // 1d. trackerError
      final trackerErrorEvent = TrackerErrorEvent(
        torrentId: 1,
        timestamp: DateTime.now(),
        trackerUrl: 'http://tracker.test/announce',
        error: 'Connection refused',
      );
      state = TorrentSessionState.reduce(state, trackerErrorEvent);
      expect(state.numPeers, 12); // unchanged

      // 1e. stoppedAnnounce
      final stoppedAnnounceEvent = StoppedAnnounceEvent(
        torrentId: 1,
        timestamp: DateTime.now(),
      );
      state = TorrentSessionState.reduce(state, stoppedAnnounceEvent);
      expect(state.stoppedAnnounceReceived, isTrue);

      // 1f. torrentPaused
      final pausedEvent = TorrentPausedAlertEvent(
        torrentId: 1,
        timestamp: DateTime.now(),
      );
      state = TorrentSessionState.reduce(state, pausedEvent);
      expect(state.isPaused, isTrue);
      expect(state.stateLabel, 'Paused');
      expect(state.downloadRate, 0);

      // 1g. torrentResumed
      final resumedEvent = TorrentResumedAlertEvent(
        torrentId: 1,
        timestamp: DateTime.now(),
      );
      state = TorrentSessionState.reduce(state, resumedEvent);
      expect(state.isPaused, isFalse);
      expect(state.stateLabel, 'Downloading');
      expect(state.stoppedAnnounceReceived, isFalse);

      // 1h. fastresumeRejected
      final fastresumeRejectedEvent = FastresumeRejectedEvent(
        torrentId: 1,
        timestamp: DateTime.now(),
        reason: 'mismatched file allocation table',
      );
      state = TorrentSessionState.reduce(state, fastresumeRejectedEvent);
      expect(state.errorMessage, contains('Fastresume rejected'));

      // 1i. torrentError
      final torrentErrorEvent = TorrentErrorAlertEvent(
        torrentId: 1,
        timestamp: DateTime.now(),
        error: 'Disk I/O failure on drive D:',
      );
      state = TorrentSessionState.reduce(state, torrentErrorEvent);
      expect(state.errorMessage, 'Disk I/O failure on drive D:');
      expect(state.stateLabel, 'Error');
    });

    test('2. Selective-priority torrent: deselecting half the files DROPS displayed bytes immediately (no monotonic floor)', () async {
      await TorrentService.init();

      final files = [
        const NativeFileInfo(index: 0, name: 'video1.mp4', path: 'video1.mp4', size: 100 * 1024 * 1024, isStreamable: true),
        const NativeFileInfo(index: 1, name: 'video2.mp4', path: 'video2.mp4', size: 100 * 1024 * 1024, isStreamable: true),
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

    test('3. Graceful pause completes with stopped-announce event before confirmation', () async {
      await TorrentService.init();

      final files = [
        const NativeFileInfo(index: 0, name: 'file.bin', path: 'file.bin', size: 10 * 1024 * 1024, isStreamable: false),
      ];
      fakeNative.seedTorrent(id: 2, name: 'GracefulPauseTorrent', files: files);
      await Future.delayed(const Duration(milliseconds: 50));

      final receivedAlerts = <TorrentAlertEvent>[];
      final sub = TorrentService.alertUpdates.listen(receivedAlerts.add);

      await TorrentService.pauseTorrent(2);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(receivedAlerts.any((a) => a.category == 'stoppedAnnounce'), isTrue,
          reason: 'stopped-announce must be emitted during graceful pause');
      expect(receivedAlerts.any((a) => a.category == 'torrentPaused'), isTrue,
          reason: 'torrentPaused must be emitted during graceful pause');

      final status = fakeNative.getTorrentStatus(2)!;
      expect(status.isPaused, isTrue);
      expect(status.downloadRate, 0);

      await sub.cancel();
    });

    test('4. Graceful pause timeout falls back to force-stop safely', () async {
      await TorrentService.init();

      final files = [
        const NativeFileInfo(index: 0, name: 'stuck.bin', path: 'stuck.bin', size: 10 * 1024 * 1024, isStreamable: false),
      ];
      fakeNative.seedTorrent(id: 3, name: 'StuckPauseTorrent', files: files);
      fakeNative.simulateGracefulPauseTimeout = true;

      // When graceful pause times out, forceStopTorrent stops the torrent handle
      await TorrentService.forceStopTorrent(3);

      expect(TorrentService.activeTorrentIds.contains(3), isFalse);
    });
  });
}
