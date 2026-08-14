import '../../features/settings/provider/settings_provider.dart';
import 'power_monitor.dart';

/// Phase 6: Memory, Battery & Screen-Off Resource Optimization
class TorrentResourceManager {
  /// Maximum concurrent active torrent downloads allowed based on system load.
  static int maxConcurrentTorrents() {
    final batteryMode = PowerMonitor.batterySaverMode;
    final thermal = PowerMonitor.thermal;

    if (batteryMode == BatterySaverMode.aggressive) return 1;
    if (batteryMode == BatterySaverMode.moderate) return 2;
    if (thermal == ThermalStatus.severe || thermal == ThermalStatus.critical) {
      return 1;
    }
    return 5;
  }

  /// Maximum peer connections allowed per torrent based on battery mode.
  static int maxConnectionsPerTorrent() {
    final batteryMode = PowerMonitor.batterySaverMode;
    if (batteryMode == BatterySaverMode.aggressive) return 20;
    if (batteryMode == BatterySaverMode.moderate) return 50;
    return 200;
  }

  /// Calculates throttled download rate limit in bytes/sec when screen is off.
  static int screenOffDownloadLimit(SettingsProvider s) {
    final batteryMode = PowerMonitor.batterySaverMode;
    if (batteryMode == BatterySaverMode.aggressive) return 0;
    if (batteryMode == BatterySaverMode.moderate) return 100 * 1024; // 100 KB/s
    return 500 * 1024; // 500 KB/s baseline screen-off throttle
  }
}
