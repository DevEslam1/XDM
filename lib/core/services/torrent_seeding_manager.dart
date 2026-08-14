import 'dart:async';
import 'package:logging/logging.dart';
import '../../features/settings/provider/settings_provider.dart';
import 'power_monitor.dart';
import 'torrent_service.dart';

final _log = Logger('TorrentSeedingManager');

/// Phase 5: Smart Seeding Manager & Adaptive Upload Regulation
class TorrentSeedingManager {
  static Timer? _seedingCheckTimer;
  static final Map<int, DateTime> _seedStartTimes = {};

  /// Starts the periodic seeding policy enforcement loop.
  static void startSeedingCheck() {
    _seedingCheckTimer?.cancel();
    _seedingCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => checkSeedingPolicies(),
    );
  }

  /// Stops the periodic seeding check loop.
  static void stopSeedingCheck() {
    _seedingCheckTimer?.cancel();
    _seedingCheckTimer = null;
  }

  /// Records when a torrent enters the seeding state.
  static void recordSeedStart(int torrentId) {
    _seedStartTimes.putIfAbsent(torrentId, () => DateTime.now());
  }

  /// Removes tracking when a torrent stops seeding.
  static void clearSeedStart(int torrentId) {
    _seedStartTimes.remove(torrentId);
  }

  /// Calculates elapsed duration of active seeding for a given torrent.
  static Duration getSeedDuration(int torrentId) {
    final start = _seedStartTimes[torrentId];
    if (start == null) return Duration.zero;
    return DateTime.now().difference(start);
  }

  /// Calculates share ratio from download and upload stats.
  static double calculateRatio(int uploadedBytes, int downloadedBytes) {
    if (downloadedBytes <= 0) return 0.0;
    return uploadedBytes / downloadedBytes;
  }

  /// Checks all active torrents against seeding policies and pauses those that exceed limits.
  static void checkSeedingPolicies({SettingsProvider? settingsProvider}) {
    final s = settingsProvider ?? SettingsProvider.instance;
    final activeIds = TorrentService.activeTorrentIds;
    final statsMap = TorrentService.latestStats;

    for (final id in activeIds) {
      final stats = statsMap[id];
      if (stats == null) continue;

      final stateLabel = stats.stateLabel.toLowerCase();
      final isSeeding = stateLabel.contains('seeding') ||
          (stats.progress >= 1.0 && stats.uploadRate > 0);

      if (!isSeeding) {
        clearSeedStart(id);
        continue;
      }

      recordSeedStart(id);

      final policy = SeedingPolicy(
        maxRatio: s.shareRatioLimit,
        maxSeedTime: Duration(minutes: s.maxSeedingTimeMinutes),
        seedOnlyWhenCharging: s.seedOnlyWhenCharging,
        seedOnlyOnWifi: s.seedOnlyOnWifi,
        minSeedTimeMinutes: s.minSeedTimeMinutes,
      );

      final isCharging = PowerMonitor.isCharging;
      const isWifi = true;
      final currentRatio =
          calculateRatio(stats.totalPayloadUpload, stats.totalPayloadDownload);
      final seedDuration = getSeedDuration(id);

      final shouldStop = policy.shouldStopSeeding(
        currentRatio: currentRatio,
        seedDuration: seedDuration,
        uploadedBytes: stats.totalPayloadUpload,
        isCharging: isCharging,
        isOnWifi: isWifi,
      );

      if (shouldStop) {
        _log.info('Stopping seeding for torrent $id (seeding policy conditions met)');
        TorrentService.pauseTorrent(id);
        clearSeedStart(id);
      }
    }
  }

  /// Calculates optimal upload rate limit in bytes/second based on thermal and battery state.
  static int computeAdaptiveUploadLimit({
    required SettingsProvider settings,
    required BatterySaverMode batteryMode,
    required ThermalStatus thermalStatus,
  }) {
    if (batteryMode == BatterySaverMode.aggressive) {
      return 0; // Disable uploading during aggressive battery saver
    }
    if (batteryMode == BatterySaverMode.moderate) {
      return 50 * 1024; // Limit to 50 KB/s in moderate battery saver
    }
    if (thermalStatus == ThermalStatus.severe ||
        thermalStatus == ThermalStatus.critical) {
      return 25 * 1024; // Limit to 25 KB/s when device is hot
    }
    if (settings.globalTorrentSeedingLimited) {
      return settings.globalTorrentSeedingLimitKbps * 1024;
    }
    return 0; // Unlimited
  }
}
