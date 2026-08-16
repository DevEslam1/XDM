import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'power_monitor.dart';
import 'torrent_models.dart';

/// Phase 1: Session Configuration Overhaul & Runtime Tuning
class TorrentSessionConfig {
  /// Builds a [BtConfig] from a [TorrentSettingsPack].
  static BtConfig buildBtConfigFromPack(
    TorrentSettingsPack pack, {
    BtConfig? baseConfig,
  }) {
    final def = baseConfig ?? LibtorrentFlutter.instance.getDefaultConfig();
    return def.copyWith(
      disableDht: !pack.enableDht,
      disableUpnp: !pack.enableUpnp,
      disableUtp: !pack.enableUtp,
      disableTcp: !pack.enableTcp,
      forceEncrypt: pack.forceEncrypt,
      connectionsLimit: pack.maxConnectionsGlobal ?? def.connectionsLimit,
      downloadRateLimit: pack.maxDownloadRate != null
          ? (pack.maxDownloadRate! ~/ 1024)
          : def.downloadRateLimit,
      uploadRateLimit: pack.maxUploadRate != null
          ? (pack.maxUploadRate! ~/ 1024)
          : def.uploadRateLimit,
      cacheSize: pack.cacheSize ?? def.cacheSize,
    );
  }

  /// Builds an optimized config adapted to device power and user settings.
  static BtConfig buildOptimizedConfig(SettingsProvider s) {
    return LibtorrentFlutter.instance.getDefaultConfig().copyWith(
          // === CONNECTION & PROTOCOL ===
          disableDht: !s.enableDht,
          disableUpnp: !s.enableUpnp,
          disableUtp: !s.enableUtp,
          forceEncrypt: s.forceEncrypt,
          connectionsLimit: adaptiveConnectionsLimit(s),

          // === RATE LIMITS ===
          downloadRateLimit: s.effectiveSpeedLimitBytesPerSecond ~/ 1024,
          uploadRateLimit: s.globalTorrentSeedingLimited
              ? s.globalTorrentSeedingLimitKbps
              : 0,
        );
  }

  /// Converts SettingsProvider to a standard [TorrentSettingsPack].
  static TorrentSettingsPack settingsToPack(SettingsProvider s) {
    return TorrentSettingsPack(
      enableDht: s.enableDht,
      enableLsd: s.enableLsd,
      enablePex: s.enablePex,
      enableUpnp: s.enableUpnp,
      maxConnectionsGlobal: adaptiveConnectionsLimit(s),
      maxDownloadRate: s.effectiveSpeedLimitBytesPerSecond,
      maxUploadRate: s.globalTorrentSeedingLimited
          ? s.globalTorrentSeedingLimitKbps * 1024
          : null,
      forceEncrypt: s.forceEncrypt,
      enableUtp: s.enableUtp,
      enableTcp: true,
      socks5ProxyHost: s.proxyHost.isNotEmpty ? s.proxyHost : null,
      socks5ProxyPort: s.proxyPort > 0 ? s.proxyPort : null,
      enforceProxy: s.enableProxy,
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

