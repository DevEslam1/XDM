import 'package:dmx/core/services/engine/torrent_watchdog_manager.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/fake_torrent_service.dart';

void main() {
  group('TorrentWatchdogManager', () {
    test('start throws when no stall callback is provided', () {
      final manager = TorrentWatchdogManager(
          FakeITorrentService(), 1, const Duration(seconds: 1));
      expect(
        () => manager.start(onAlivenessLost: () {}),
        throwsArgumentError,
      );
    });

    test('start sets active and fires the stall callback periodically', () {
      fakeAsync((async) {
        final service = FakeITorrentService();
        final manager =
            TorrentWatchdogManager(service, 1, const Duration(seconds: 5));
        var stalls = 0;
        manager.start(onStallCheck: () => stalls++, onAlivenessLost: () {});
        expect(manager.isActive, isTrue);
        expect(manager.stallTimer, isNotNull);
        expect(manager.alivenessTimer, isNotNull);

        async.elapse(const Duration(seconds: 16));
        expect(stalls, 3);

        manager.stop();
        expect(manager.isActive, isFalse);
        expect(manager.stallTimer, isNull);
        expect(manager.alivenessTimer, isNull);
      });
    });

    test('onStalled fallback callback is used when onStallCheck is absent', () {
      fakeAsync((async) {
        final manager = TorrentWatchdogManager(
            FakeITorrentService(), 1, const Duration(seconds: 5));
        var stalls = 0;
        manager.start(onStalled: () => stalls++, onAlivenessLost: () {});
        async.elapse(const Duration(seconds: 6));
        expect(stalls, 1);
        manager.dispose();
      });
    });

    test('isPausedByUser suppresses both stall and aliveness callbacks', () {
      fakeAsync((async) {
        final service = FakeITorrentService();
        final manager =
            TorrentWatchdogManager(service, 1, const Duration(seconds: 5));
        var stalls = 0;
        var aliveLost = 0;
        manager.start(
          onStallCheck: () => stalls++,
          onAlivenessLost: () => aliveLost++,
          isPausedByUser: () => true,
        );
        async.elapse(const Duration(seconds: 25));
        expect(stalls, 0);
        expect(aliveLost, 0);
        manager.stop();
      });
    });

    test('aliveness callback fires only when torrent is not alive', () {
      fakeAsync((async) {
        final service = FakeITorrentService();
        service.seedTorrent(id: 7, name: 'x', totalWanted: 100);
        final manager =
            TorrentWatchdogManager(service, 7, const Duration(seconds: 5));
        var aliveLost = 0;
        manager.start(onStallCheck: () {}, onAlivenessLost: () => aliveLost++);

        async.elapse(const Duration(seconds: 11));
        expect(aliveLost, 0, reason: 'torrent 7 is alive');

        service.removeTorrent(7);
        async.elapse(const Duration(seconds: 11));
        expect(aliveLost, greaterThan(0));
        manager.stop();
      });
    });
  });
}
