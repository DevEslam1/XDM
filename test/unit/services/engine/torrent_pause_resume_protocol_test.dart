import 'dart:async';
import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Torrent Pause/Resume Protocol Tests', () {
    late FakeTorrentNative fakeNative;

    setUp(() {
      fakeNative = FakeTorrentNative();
      TorrentService.setNativeForTesting(fakeNative);
    });

    test('saveResumeData triggers saveResumeData on native and returns blob', () async {
      const tid = 101;
      fakeNative.emitStatuses(const {
        tid: NativeTorrentStatus(
          id: tid,
          name: 'test_torrent',
          savePath: '/downloads',
          errorMsg: '',
          state: 4,
          stateLabel: 'downloading',
          progress: 0.5,
          downloadRate: 1000,
          uploadRate: 0,
          totalDone: 500,
          totalWanted: 1000,
          totalWantedDone: 500,
          totalUploaded: 0,
          numPeers: 5,
          numSeeds: 10,
          numComplete: 10,
          numIncomplete: 5,
          isPaused: false,
          isFinished: false,
          hasMetadata: true,
          queuePosition: 0,
        ),
      });

      await TorrentService.saveResumeData(tid);
      expect(fakeNative.saveResumeDataCallCount, greaterThan(0));
      final blob = TorrentService.resumeBlobFor(tid);
      expect(blob, isNotNull);
      expect(blob, isNotEmpty);
      expect(blob, equals([0x64, 0x31, 0x30, 0x3a, 0x66, 0x61, 0x73, 0x74, 0x65]));
    });

    test('removeTorrent unblocks any pending saveResumeData completer without throwing', () async {
      const tid = 102;
      fakeNative.emitStatuses(const {
        tid: NativeTorrentStatus(
          id: tid,
          name: 'test_torrent_remove',
          savePath: '/downloads',
          errorMsg: '',
          state: 4,
          stateLabel: 'downloading',
          progress: 0.1,
          downloadRate: 0,
          uploadRate: 0,
          totalDone: 100,
          totalWanted: 1000,
          totalWantedDone: 100,
          totalUploaded: 0,
          numPeers: 0,
          numSeeds: 0,
          isPaused: false,
          isFinished: false,
          hasMetadata: true,
          queuePosition: 0,
        ),
      });

      // Start saveResumeData but don't finish alert
      unawaited(TorrentService.saveResumeData(tid));
      await pumpEventQueue();

      // Removing the torrent must clean up state without hanging
      expect(() => TorrentService.removeTorrent(tid), returnsNormally);
    });
  });
}
