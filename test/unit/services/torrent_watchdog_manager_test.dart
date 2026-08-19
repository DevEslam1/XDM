import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/engine/torrent_watchdog_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTorrentService implements ITorrentService {
  bool isAlive = true;

  @override
  bool isTorrentAlive(int torrentId) => isAlive;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('TorrentWatchdogManager', () {
    test('starts and triggers periodic stall and aliveness checks', () async {
      final fakeService = _FakeTorrentService();
      var stallCount = 0;
      var alivenessLostCount = 0;

      final watchdog = TorrentWatchdogManager(
        fakeService,
        1,
        const Duration(milliseconds: 50),
      );

      watchdog.start(
        onStalled: () => stallCount++,
        onAlivenessLost: () => alivenessLostCount++,
      );

      expect(watchdog.isActive, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(stallCount >= 1, isTrue);
      expect(alivenessLostCount, 0);

      // Kill torrent alive state
      fakeService.isAlive = false;
      // Stop watchdog
      watchdog.stop();
      expect(watchdog.isActive, isFalse);
    });
  });
}
