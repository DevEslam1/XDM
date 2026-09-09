import 'package:dmx/core/services/engine/torrent_session_events.dart';
import 'package:dmx/core/services/engine/torrent_session_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TorrentSessionState Truthfulness & Reducer Tests', () {
    const tid = 101;
    final now = DateTime(2026, 1, 1, 12, 0, 0);

    test(
        'progress at 99.9% does not prematurely mark finished if wanted bytes remain',
        () {
      const initial = TorrentSessionState(
        torrentId: tid,
        totalWanted: 10000,
        totalWantedDone: 9990,
        progress: 0.9990,
        piecesTotal: 100,
        piecesHave: 99,
      );

      final next = TorrentSessionState.reduce(
        initial,
        StatusTickEvent(
          torrentId: tid,
          timestamp: now,
          progress: 0.9990,
          downloadRate: 500,
          uploadRate: 0,
          totalDone: 9990,
          totalWanted: 10000,
          totalWantedDone: 9990,
          numPeers: 5,
          numSeeds: 2,
          piecesHave: 99,
          piecesTotal: 100,
          stateLabel: 'Downloading',
        ),
      );

      expect(next.isFinished, isFalse);
      expect(next.isSeeding, isFalse);
      expect(next.stateLabel, 'Downloading');
    });

    test(
        'completion occurs deterministically when totalWantedDone >= totalWanted',
        () {
      const initial = TorrentSessionState(
        torrentId: tid,
        totalWanted: 10000,
        totalWantedDone: 9990,
        progress: 0.9990,
      );

      final next = TorrentSessionState.reduce(
        initial,
        PieceFinishedEvent(
          torrentId: tid,
          timestamp: now,
          pieceIndex: 99,
          totalWantedDone: 10000,
          piecesHave: 100,
          piecesTotal: 100,
          pieceBitfield: const [],
        ),
      );

      expect(next.isFinished, isTrue);
      expect(next.isSeeding, isTrue);
      expect(next.stateLabel, 'Seeding');
      expect(next.progress, 1.0);
    });

    test('piecesHave >= piecesTotal marks finished when totalWanted is 0', () {
      const initial = TorrentSessionState(
        torrentId: tid,
        totalWanted: 0,
        totalWantedDone: 0,
        piecesTotal: 50,
        piecesHave: 49,
      );

      final next = TorrentSessionState.reduce(
        initial,
        StatusTickEvent(
          torrentId: tid,
          timestamp: now,
          progress: 1.0,
          downloadRate: 0,
          uploadRate: 0,
          totalDone: 50000,
          totalWanted: 0,
          totalWantedDone: 0,
          numPeers: 2,
          numSeeds: 1,
          piecesHave: 50,
          piecesTotal: 50,
          stateLabel: 'Downloading',
        ),
      );

      expect(next.isFinished, isTrue);
      expect(next.isSeeding, isTrue);
      expect(next.stateLabel, 'Seeding');
    });

    test('zero-piece torrent falls back to progress >= 0.9999 for completion',
        () {
      const initial = TorrentSessionState(
        torrentId: tid,
        totalWanted: 0,
        totalWantedDone: 0,
        piecesTotal: 0,
        piecesHave: 0,
      );

      final next = TorrentSessionState.reduce(
        initial,
        StatusTickEvent(
          torrentId: tid,
          timestamp: now,
          progress: 0.99995,
          downloadRate: 0,
          uploadRate: 0,
          totalDone: 0,
          totalWanted: 0,
          totalWantedDone: 0,
          numPeers: 0,
          numSeeds: 0,
          piecesHave: 0,
          piecesTotal: 0,
          stateLabel: 'Downloading',
        ),
      );

      expect(next.isFinished, isTrue);
      expect(next.isSeeding, isTrue);
    });

    test(
        'paused + finished transitions produce "Finished" stateLabel instead of "Seeding"',
        () {
      const finished = TorrentSessionState(
        torrentId: tid,
        totalWanted: 5000,
        totalWantedDone: 5000,
        isFinished: true,
        isSeeding: true,
        stateLabel: 'Seeding',
      );

      final paused = TorrentSessionState.reduce(
        finished,
        TorrentPausedAlertEvent(torrentId: tid, timestamp: now),
      );

      expect(paused.isPaused, isTrue);
      expect(paused.isFinished, isTrue);
      expect(paused.isSeeding, isFalse);
      expect(paused.stateLabel, 'Finished');

      final resumed = TorrentSessionState.reduce(
        paused,
        TorrentResumedAlertEvent(torrentId: tid, timestamp: now),
      );

      expect(resumed.isPaused, isFalse);
      expect(resumed.isFinished, isTrue);
      expect(resumed.isSeeding, isTrue);
      expect(resumed.stateLabel, 'Seeding');
    });

    test(
        'fastresume rejection transitions to paused error state with failure reason',
        () {
      const state = TorrentSessionState(
        torrentId: tid,
        stateLabel: 'Downloading',
        isPaused: false,
      );

      final next = TorrentSessionState.reduce(
        state,
        FastresumeRejectedEvent(
          torrentId: tid,
          timestamp: now,
          reason: 'mismatched file size on disk',
        ),
      );

      expect(next.isPaused, isTrue);
      expect(next.isSeeding, isFalse);
      expect(next.stateLabel, 'Error');
      expect(next.errorMessage, contains('mismatched file size on disk'));
    });

    test('torrent error alert marks error and disables seeding', () {
      const state = TorrentSessionState(
        torrentId: tid,
        isFinished: true,
        isSeeding: true,
        stateLabel: 'Seeding',
      );

      final next = TorrentSessionState.reduce(
        state,
        TorrentErrorAlertEvent(
          torrentId: tid,
          timestamp: now,
          error: 'Disk full / write error',
        ),
      );

      expect(next.stateLabel, 'Error');
      expect(next.isSeeding, isFalse);
      expect(next.errorMessage, 'Disk full / write error');
    });

    test('tracker reply with 0 peers authoritatively updates numPeers to 0',
        () {
      const state = TorrentSessionState(
        torrentId: tid,
        numPeers: 12,
      );

      final next = TorrentSessionState.reduce(
        state,
        TrackerReplyEvent(
          torrentId: tid,
          timestamp: now,
          trackerUrl: 'http://tracker.example.com/announce',
          numPeers: 0,
        ),
      );

      expect(next.numPeers, 0);
    });

    test(
        'authoritative 0 values in StatusTickEvent for pieces and peers are not ignored',
        () {
      const state = TorrentSessionState(
        torrentId: tid,
        numPeers: 7,
        piecesHave: 10,
        piecesTotal: 20,
      );

      final next = TorrentSessionState.reduce(
        state,
        StatusTickEvent(
          torrentId: tid,
          timestamp: now,
          progress: 0.0,
          downloadRate: 0,
          uploadRate: 0,
          totalDone: 0,
          totalWanted: 100,
          totalWantedDone: 0,
          numPeers: 0,
          numSeeds: 0,
          piecesHave: 0,
          piecesTotal: 20,
          stateLabel: 'Downloading',
        ),
      );

      expect(next.numPeers, 0);
      expect(next.piecesHave, 0);
      expect(next.piecesTotal, 20);
    });
  });
}
