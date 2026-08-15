import 'package:battery_plus/battery_plus.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/torrent_session_config.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TorrentSessionConfig Unit Tests (Phase 1)', () {
    test('adaptiveConnectionsLimit adjusts to battery saver modes', () {
      final settings = SettingsProvider();
      settings.torrentConnectionsLimit = 150;

      PowerMonitor.setBatteryForTesting(level: 80, state: BatteryState.discharging);
      expect(TorrentSessionConfig.adaptiveConnectionsLimit(settings), 150);

      PowerMonitor.setBatteryForTesting(level: 30, state: BatteryState.discharging);
      expect(TorrentSessionConfig.adaptiveConnectionsLimit(settings), 100);

      PowerMonitor.setBatteryForTesting(level: 10, state: BatteryState.discharging);
      expect(TorrentSessionConfig.adaptiveConnectionsLimit(settings), 50);

      PowerMonitor.setBatteryForTesting(level: 100, state: BatteryState.charging);
    });

    test('maxHalfOpenConnections adjusts to battery saver modes', () {
      PowerMonitor.setBatteryForTesting(level: 80, state: BatteryState.discharging);
      expect(TorrentSessionConfig.maxHalfOpenConnections(), 20);

      PowerMonitor.setBatteryForTesting(level: 30, state: BatteryState.discharging);
      expect(TorrentSessionConfig.maxHalfOpenConnections(), 8);

      PowerMonitor.setBatteryForTesting(level: 10, state: BatteryState.discharging);
      expect(TorrentSessionConfig.maxHalfOpenConnections(), 4);

      PowerMonitor.setBatteryForTesting(level: 100, state: BatteryState.charging);
    });
  });
}
