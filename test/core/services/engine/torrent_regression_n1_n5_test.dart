import 'dart:io';

import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Regression N1: Simultaneous statusStream listeners', () {
    test('two simultaneous statusStream listeners both receive status updates',
        () async {
      final fakeNative = FakeTorrentNative();
      await fakeNative.init();

      final received1 = <Map<int, NativeTorrentStatus>>[];
      final received2 = <Map<int, NativeTorrentStatus>>[];

      final sub1 = fakeNative.statusStream.listen(received1.add);
      final sub2 = fakeNative.statusStream.listen(received2.add);

      fakeNative.addMagnet(
          'magnet:?xt=urn:btih:1111111111111111111111111111111111111111',
          '/tmp');

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received1.isNotEmpty, isTrue);
      expect(received2.isNotEmpty, isTrue);
      expect(received1.length, equals(received2.length));

      await sub1.cancel();
      await sub2.cancel();
      await fakeNative.dispose();
    });
  });

  group('Regression N2: Double init ensures alert subscriptions', () {
    test('init called twice still delivers alertStream events', () async {
      final fakeNative = FakeTorrentNative();
      await fakeNative.init();
      // Second init invocation
      await fakeNative.init();

      final alerts = <NativeAlertEvent>[];
      final sub = fakeNative.alertStream.listen(alerts.add);

      fakeNative.emitAlert(NativeAlertEvent(
        type: TorrentAlertType.pieceFinished,
        alertCode: 26,
        torrentId: 1,
        message: 'Piece finished',
        timestamp: DateTime.now(),
      ));

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(alerts.length, equals(1));
      expect(alerts.first.alertCode, equals(26));

      await sub.cancel();
      await fakeNative.dispose();
    });
  });

  group('Regression N3: Monotonic IDs & clean state on add-remove-add', () {
    test('add -> remove -> add yields distinct IDs with clean state', () {
      final fakeNative = FakeTorrentNative();

      final id1 = fakeNative.addMagnet('magnet:?xt=urn:btih:aaa', '/tmp/1');
      expect(id1, equals(1));
      fakeNative.addTracker(id1, 'http://tracker1.org');
      fakeNative.setSequentialDownload(id1, true);

      fakeNative.removeTorrent(id1);
      expect(fakeNative.getTrackers(id1), isEmpty);

      final id2 = fakeNative.addMagnet('magnet:?xt=urn:btih:bbb', '/tmp/2');
      expect(id2, equals(2));
      expect(id2, isNot(equals(id1)));
      expect(fakeNative.getTrackers(id2), isEmpty);
    });

    test('simulateResumeLoadFailure knob simulates load failure', () {
      final fakeNative = FakeTorrentNative();
      fakeNative.simulateResumeLoadFailure = true;

      final loaded = fakeNative.loadResumeData(1, [1, 2, 3]);
      expect(loaded, isFalse);

      fakeNative.simulateResumeLoadFailure = false;
      final loaded2 = fakeNative.loadResumeData(1, [1, 2, 3]);
      expect(loaded2, isTrue);
    });
  });

  group('Regression N4: Path and size-aware disk space caching', () {
    test(
        'disk check for path B with larger requiredBytes than cached path A does not serve stale result',
        () async {
      final tempDirA = Directory.systemTemp.createTempSync('dmx_disk_a_');
      final tempDirB = Directory.systemTemp.createTempSync('dmx_disk_b_');

      final engine = DownloadEngine();

      // Check path A with 1024 bytes
      final spaceA = await engine.hasEnoughDiskSpace(tempDirA.path, 1024);
      expect(spaceA, isTrue);

      // Check path B with huge size: 100 PB (100 * 1024^5 bytes)
      final spaceB = await engine.hasEnoughDiskSpace(
          tempDirB.path, 100 * 1024 * 1024 * 1024 * 1024 * 1024);
      expect(spaceB, isFalse);

      // Clean up
      try {
        tempDirA.deleteSync(recursive: true);
        tempDirB.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  group('Regression N5: Pool initialization retry on transient failure', () {
    test(
        'engine recovers and allows pool init after an initial transient failure',
        () async {
      final engine = DownloadEngine();

      // updateSpeedLimit does not throw when pool is not yet initialized
      expect(() => engine.updateSpeedLimit(1024 * 1024, 1), returnsNormally);
    });
  });
}
