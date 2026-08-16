import 'package:battery_plus/battery_plus.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/torrent_resource_manager.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TorrentResourceManager Unit Tests (Phase 6 & 10)', () {
    test('maxConcurrentTorrents respects power and thermal constraints', () {
      PowerMonitor.setBatteryForTesting(
          level: 80, state: BatteryState.discharging);
      PowerMonitor.setThermalForTesting(ThermalStatus.none);
      expect(TorrentResourceManager.maxConcurrentTorrents(), 5);

      PowerMonitor.setBatteryForTesting(
          level: 30, state: BatteryState.discharging);
      expect(TorrentResourceManager.maxConcurrentTorrents(), 2);

      PowerMonitor.setBatteryForTesting(
          level: 10, state: BatteryState.discharging);
      expect(TorrentResourceManager.maxConcurrentTorrents(), 1);

      PowerMonitor.setBatteryForTesting(
          level: 80, state: BatteryState.discharging);
      PowerMonitor.setThermalForTesting(ThermalStatus.severe);
      expect(TorrentResourceManager.maxConcurrentTorrents(), 1);

      PowerMonitor.setThermalForTesting(ThermalStatus.none);
      PowerMonitor.setBatteryForTesting(
          level: 100, state: BatteryState.charging);
    });

    test('maxConnectionsPerTorrent adapts to battery saver modes', () {
      PowerMonitor.setBatteryForTesting(
          level: 80, state: BatteryState.discharging);
      expect(TorrentResourceManager.maxConnectionsPerTorrent(), 200);

      PowerMonitor.setBatteryForTesting(
          level: 30, state: BatteryState.discharging);
      expect(TorrentResourceManager.maxConnectionsPerTorrent(), 50);

      PowerMonitor.setBatteryForTesting(
          level: 10, state: BatteryState.discharging);
      expect(TorrentResourceManager.maxConnectionsPerTorrent(), 20);

      PowerMonitor.setBatteryForTesting(
          level: 100, state: BatteryState.charging);
    });

    test('screenOffDownloadLimit enforces power-saving rates', () {
      final settings = SettingsProvider();

      PowerMonitor.setBatteryForTesting(
          level: 80, state: BatteryState.discharging);
      expect(
          TorrentResourceManager.screenOffDownloadLimit(settings), 500 * 1024);

      PowerMonitor.setBatteryForTesting(
          level: 30, state: BatteryState.discharging);
      expect(
          TorrentResourceManager.screenOffDownloadLimit(settings), 100 * 1024);

      PowerMonitor.setBatteryForTesting(
          level: 10, state: BatteryState.discharging);
      expect(TorrentResourceManager.screenOffDownloadLimit(settings), 0);

      PowerMonitor.setBatteryForTesting(
          level: 100, state: BatteryState.charging);
    });
  });
}
