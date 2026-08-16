import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:dmx/core/services/engine/torrent_download_handler.dart';
import 'package:dmx/core/services/engines/http_download_engine.dart';
import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/service_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockTorrentService extends Fake implements ITorrentService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Low-End Device Resource Hygiene Integration Test (P2-12)', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      PowerMonitor.setLowEndDevice(true);
    });

    tearDown(() async {
      PowerMonitor.setLowEndDevice(false);
    });

    test('10 concurrent HTTP downloads + 2 torrents on low-end device assert no timer leak', () async {
      final initialServiceCount = ServiceRegistry.activeServicesCount;
      final mirrorStore = MirrorHealthStore();
      final profileManager = ServerProfileManager();
      final benchmarkService = MirrorBenchmarkService();

      expect(PowerMonitor.isLowEndDevice, isTrue);

      final httpEngine = HttpDownloadEngine();
      final governors = <BandwidthGovernor>[];
      final torrentHandlers = <TorrentDownloadHandler>[];

      // Spawn 10 simulated HTTP download workloads
      for (int i = 0; i < 10; i++) {
        final taskId = 'http-task-$i';
        final governor = BandwidthGovernor(500 * 1024);
        governor.registerConsumer();
        governors.add(governor);

        httpEngine.startAdaptiveMonitorForTask(taskId, 2);
        httpEngine.recordSample(taskId, 250000.0, 2);
      }

      // Spawn 2 simulated Torrent downloads
      for (int i = 0; i < 2; i++) {
        final handler = TorrentDownloadHandler(torrentService: _MockTorrentService());
        handler.cachedAccurateFiles = [
          {'name': 'torrent_$i.iso', 'length': 1000000, 'completed': 500000},
        ];
        handler.lastStateLabel = 'Seeding';
        torrentHandlers.add(handler);
      }

      // Assert active trackers and active governor timers
      expect(httpEngine.activeTrackerCount, equals(10));
      expect(httpEngine.monitorTimerForTesting, isNotNull);
      for (final gov in governors) {
        expect(gov.domainCleanupTimerForTesting, isNotNull);
      }

      // Complete and teardown all 10 HTTP downloads
      for (int i = 0; i < 10; i++) {
        final taskId = 'http-task-$i';
        httpEngine.stopFor(taskId);
        governors[i].unregisterConsumer();
        governors[i].dispose();
      }

      // Complete and teardown 2 torrents
      for (int i = 0; i < 2; i++) {
        torrentHandlers[i].removeActiveTorrent(i);
      }

      // Verify timers are completely shut down
      expect(httpEngine.activeTrackerCount, equals(0));
      expect(httpEngine.monitorTimerForTesting, isNull);
      for (final gov in governors) {
        expect(gov.domainCleanupTimerForTesting, isNull);
      }
      for (final handler in torrentHandlers) {
        expect(handler.cachedAccurateFiles, isNull);
        expect(handler.lastStateLabel, isEmpty);
      }

      // Teardown singleton test services
      await mirrorStore.dispose();
      await profileManager.dispose();
      await benchmarkService.dispose();

      // Assert no orphaned services leaked in ServiceRegistry
      expect(ServiceRegistry.activeServicesCount, equals(initialServiceCount));
    });
  });
}
