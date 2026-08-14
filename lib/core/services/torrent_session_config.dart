import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'power_monitor.dart';

/// Phase 1: Session Configuration Overhaul & Runtime Tuning
class TorrentSessionConfig {
  /// Builds an optimized config adapted to device power and user settings.
  static dynamic buildOptimizedConfig(SettingsProvider s) {
    return LibtorrentFlutter.instance.getDefaultConfig().copyWith(
          // === CONNECTION & PROTOCOL ===
          disableDht: !s.enableDht,
          disableUpnp: !s.enableUpnp,
          forceEncrypt: s.forceEncrypt,
          connectionsLimit: adaptiveConnectionsLimit(s),

          // === RATE LIMITS ===
          downloadRateLimit: s.effectiveSpeedLimitBytesPerSecond ~/ 1024,
          uploadRateLimit: s.globalTorrentSeedingLimited
              ? s.globalTorrentSeedingLimitKbps
              : 0,
        );
  }

  /// Calculates dynamic connections limit based on active Battery Saver mode.
  static int adaptiveConnectionsLimit(SettingsProvider s) {
    final batteryMode = PowerMonitor.batterySaverMode;
    if (batteryMode == BatterySaverMode.aggressive) return 50;
    if (batteryMode == BatterySaverMode.moderate) return 100;
    return s.torrentConnectionsLimit; // User setting or default (200)
  }

  /// Adaptive half-open connection limit for peer discovery.
  static int maxHalfOpenConnections() {
    final batteryMode = PowerMonitor.batterySaverMode;
    if (batteryMode == BatterySaverMode.aggressive) return 4;
    if (batteryMode == BatterySaverMode.moderate) return 8;
    return 20;
  }
}
