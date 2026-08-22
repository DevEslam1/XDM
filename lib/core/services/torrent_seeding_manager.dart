import 'dart:async';
import 'package:logging/logging.dart';
import '../../features/downloads/models/download_task.dart';
import '../../features/downloads/provider/network_monitor.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../di/injection.dart';
import 'power_monitor.dart';
import 'torrent_service.dart';

final _log = Logger('TorrentSeedingManager');

/// Phase 5: Smart Seeding Manager & Adaptive Upload Regulation
class TorrentSeedingManager {
  TorrentSeedingManager._();

  static final TorrentSeedingManager instance = TorrentSeedingManager._();
  factory TorrentSeedingManager() => instance;

  Timer? _seedingCheckTimer;
  final Map<int, DateTime> _seedStartTimes = {};

  /// Starts the periodic seeding policy enforcement loop.
  void startSeedingCheck() {
    _seedingCheckTimer?.cancel();
    _seedingCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => checkSeedingPolicies(),
    );
  }

  /// Stops the periodic seeding check loop.
  void stopSeedingCheck() {
    _seedingCheckTimer?.cancel();
    _seedingCheckTimer = null;
  }

  /// Records when a torrent enters the seeding state.
  void recordSeedStart(int torrentId) {
    _seedStartTimes.putIfAbsent(torrentId, () => DateTime.now());
  }

  /// Removes tracking when a torrent stops seeding.
  void clearSeedStart(int torrentId) {
    _seedStartTimes.remove(torrentId);
  }

  /// Calculates elapsed duration of active seeding for a given torrent.
  Duration getSeedDuration(int torrentId) {
    final start = _seedStartTimes[torrentId];
    if (start == null) return Duration.zero;
    return DateTime.now().difference(start);
  }

  /// Calculates share ratio from download and upload stats with fallback for magnet-only additions.
  static double calculateRatio(int uploadedBytes, int downloadedBytes, {int? fallbackBytes}) {
    final effectiveDownload = downloadedBytes > 0 ? downloadedBytes : (fallbackBytes ?? 0);
    if (effectiveDownload <= 0) return 0.0;
    return uploadedBytes / effectiveDownload;
  }

  /// Checks all active torrents against seeding policies and pauses those that exceed limits.
  void checkSeedingPolicies({SettingsProvider? settingsProvider}) {
    SettingsProvider? s = settingsProvider;
    if (s == null) {
      try {
        s = SettingsProvider.instance;
      } catch (_) {}
    }
    final activeIds = TorrentService.activeTorrentIds;
    final statsMap = TorrentService.latestStats;

    // Prune stale tracked IDs that are no longer active
    _seedStartTimes.removeWhere((id, _) => !activeIds.contains(id));

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
        maxRatio: s?.shareRatioLimit ?? 2.0,
        maxSeedTime: Duration(minutes: s?.maxSeedingTimeMinutes ?? 0),
        seedOnlyWhenCharging: s?.seedOnlyWhenCharging ?? false,
        seedOnlyOnWifi: s?.seedOnlyOnWifi ?? false,
        minSeedTimeMinutes: s?.minSeedTimeMinutes ?? 0,
      );

      final isCharging = PowerMonitor.isCharging;
      // FIX v2.0.0: Actually check wifi status instead of hardcoding true.
      bool isWifi = true;
      try {
        if (getIt.isRegistered<NetworkMonitor>()) {
          isWifi = getIt<NetworkMonitor>().hasWifiOrEthernet;
        }
      } catch (_) {}
      final currentRatio = calculateRatio(
        stats.totalPayloadUpload,
        stats.totalPayloadDownload,
        fallbackBytes: stats.totalDone > 0 ? stats.totalDone : null,
      );
      final seedDuration = getSeedDuration(id);

      final shouldStop = policy.shouldStopSeeding(
        currentRatio: currentRatio,
        seedDuration: seedDuration,
        uploadedBytes: stats.totalPayloadUpload,
        isCharging: isCharging,
        isOnWifi: isWifi,
      );

      if (shouldStop) {
        _log.info(
            'Stopping seeding for torrent $id (seeding policy conditions met)');
        TorrentService.pauseTorrent(id);
        clearSeedStart(id);
      }
    }
  }

  /// Checks whether seeding should stop for a specific task.
  /// Strictly returns false if the task is currently paused.
  bool shouldStopSeedingForTask(
    DownloadTask task, {
    required double currentRatio,
    required Duration seedDuration,
    required int uploadedBytes,
    required bool isCharging,
    required bool isOnWifi,
    SettingsProvider? settingsProvider,
  }) {
    if (task.cycleState == CycleState.paused ||
        task.status == DownloadStatus.paused) {
      return false;
    }
    SettingsProvider? s = settingsProvider;
    if (s == null) {
      try {
        s = SettingsProvider.instance;
      } catch (_) {}
    }
    final policy = SeedingPolicy(
      maxRatio: s?.shareRatioLimit ?? 2.0,
      maxSeedTime: Duration(minutes: s?.maxSeedingTimeMinutes ?? 0),
      seedOnlyWhenCharging: s?.seedOnlyWhenCharging ?? false,
      seedOnlyOnWifi: s?.seedOnlyOnWifi ?? false,
      minSeedTimeMinutes: s?.minSeedTimeMinutes ?? 0,
    );
    return policy.shouldStopSeeding(
      currentRatio: currentRatio,
      seedDuration: seedDuration,
      uploadedBytes: uploadedBytes,
      isCharging: isCharging,
      isOnWifi: isOnWifi,
      cycleState: task.cycleState,
    );
  }

  /// Checks whether a seeding torrent can be auto-resumed.
  /// If the task is paused, returns false immediately.
  bool shouldAutoResumeSeeding(DownloadTask task) {
    if (task.cycleState == CycleState.paused ||
        task.status == DownloadStatus.paused ||
        task.pausedByUser == true) {
      return false;
    }
    return task.isTorrent &&
        task.status == DownloadStatus.completed &&
        task.seedingEnabled;
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

  /// FIX-25: Enforces a global upload budget divided fairly across all actively seeding tasks.
  static int computePerTaskUploadLimit({
    required SettingsProvider settings,
    required int activeSeedingCount,
    required BatterySaverMode batteryMode,
    required ThermalStatus thermalStatus,
  }) {
    final globalLimit = computeAdaptiveUploadLimit(
      settings: settings,
      batteryMode: batteryMode,
      thermalStatus: thermalStatus,
    );
    if (globalLimit <= 0 || activeSeedingCount <= 1) {
      return globalLimit;
    }
    final perTask = globalLimit ~/ activeSeedingCount;
    return perTask.clamp(0, globalLimit);
  }
}
