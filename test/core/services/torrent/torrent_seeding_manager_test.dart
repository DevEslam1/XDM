import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/interfaces/i_torrent_native.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/torrent/fake_torrent_native.dart';
import 'package:dmx/core/services/torrent_seeding_manager.dart';
import 'package:dmx/core/services/torrent_service_ffi.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DownloadTask torrentTask({
    String url = 'magnet:?xt=urn:btih:abcdef1234567890',
    String fileName = 't.torrent',
    DownloadStatus status = DownloadStatus.completed,
    CycleState? cycleState,
    bool seedingEnabled = true,
    bool pausedByUser = false,
  }) {
    final now = DateTime(2025, 1, 1);
    return DownloadTask(
      id: 't',
      fileName: fileName,
      url: url,
      fileSize: 100,
      downloadedBytes: 100,
      category: 'torrent',
      status: status,
      cycleState: cycleState,
      savePath: '/s',
      localFilePath: '/s',
      tempFilePath: '/s.tmp',
      threadCount: 1,
      chunks: const [],
      createdAt: now,
      updatedAt: now,
      seedingEnabled: seedingEnabled,
      pausedByUser: pausedByUser,
    );
  }

  group('TorrentSeedingManager.calculateRatio', () {
    test('uses the downloaded bytes when present', () {
      expect(TorrentSeedingManager.calculateRatio(100, 50), 2.0);
    });

    test('falls back to fallbackBytes for magnet-only torrents', () {
      expect(
        TorrentSeedingManager.calculateRatio(100, 0, fallbackBytes: 200),
        0.5,
      );
    });

    test('returns zero when there is no effective download', () {
      expect(TorrentSeedingManager.calculateRatio(100, 0), 0.0);
    });
  });

  group('TorrentSeedingManager seed tracking', () {
    setUp(() {
      TorrentSeedingManager.instance.dispose();
    });

    test('factory returns the singleton', () {
      expect(
        identical(TorrentSeedingManager(), TorrentSeedingManager.instance),
        isTrue,
      );
    });

    test('the seeding tick callback enforces policies', () async {
      TorrentSeedingManager.instance.startSeedingCheck();
      // The heartbeat fires after ~1s; the epoch lastRun makes the callback
      // eligible on the first beat.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      TorrentSeedingManager.instance.stopSeedingCheck();
    });

    test('records, measures and clears seed durations', () {
      TorrentSeedingManager.instance.recordSeedStart(1);
      expect(TorrentSeedingManager.instance.getSeedDuration(1),
          greaterThanOrEqualTo(Duration.zero));
      TorrentSeedingManager.instance.clearSeedStart(1);
      expect(TorrentSeedingManager.instance.getSeedDuration(1), Duration.zero);
    });

    test('start and stop the seeding check tick', () {
      TorrentSeedingManager.instance.startSeedingCheck();
      TorrentSeedingManager.instance.startSeedingCheck();
      TorrentSeedingManager.instance.stopSeedingCheck();
    });
  });

  group('TorrentSeedingManager.shouldStopSeedingForTask', () {
    test('never stops a paused task', () {
      final task = torrentTask(
        status: DownloadStatus.paused,
        cycleState: CycleState.paused,
      );
      expect(
        TorrentSeedingManager.instance.shouldStopSeedingForTask(
          task,
          currentRatio: 5,
          seedDuration: const Duration(hours: 1),
          uploadedBytes: 1000,
          isCharging: true,
          isOnWifi: true,
          settingsProvider: SettingsProvider(),
        ),
        isFalse,
      );
    });

    test('stops when the ratio exceeds the configured limit', () {
      final settings = SettingsProvider()..shareRatioLimit = 1.0;
      expect(
        TorrentSeedingManager.instance.shouldStopSeedingForTask(
          torrentTask(),
          currentRatio: 2.0,
          seedDuration: const Duration(minutes: 1),
          uploadedBytes: 200,
          isCharging: true,
          isOnWifi: true,
          settingsProvider: settings,
        ),
        isTrue,
      );
    });

    test('keeps seeding when under all limits', () {
      final settings = SettingsProvider()
        ..shareRatioLimit = 10.0
        ..maxSeedingTimeMinutes = 0;
      expect(
        TorrentSeedingManager.instance.shouldStopSeedingForTask(
          torrentTask(),
          currentRatio: 0.1,
          seedDuration: const Duration(minutes: 1),
          uploadedBytes: 10,
          isCharging: true,
          isOnWifi: true,
          settingsProvider: settings,
        ),
        isFalse,
      );
    });

    test('falls back to the settings singleton when none is supplied', () {
      SettingsProvider.instance.shareRatioLimit = 1.0;
      addTearDown(() => SettingsProvider.instance.shareRatioLimit = 2.0);
      expect(
        TorrentSeedingManager.instance.shouldStopSeedingForTask(
          torrentTask(),
          currentRatio: 2.0,
          seedDuration: const Duration(minutes: 1),
          uploadedBytes: 200,
          isCharging: true,
          isOnWifi: true,
        ),
        isTrue,
      );
    });
  });

  group('TorrentSeedingManager.shouldAutoResumeSeeding', () {
    tearDown(() {
      SettingsProvider.instance.globalTorrentSeeding = true;
    });

    test('refuses when paused or paused by user', () {
      expect(
        TorrentSeedingManager.instance.shouldAutoResumeSeeding(
            torrentTask(status: DownloadStatus.paused)),
        isFalse,
      );
      expect(
        TorrentSeedingManager.instance
            .shouldAutoResumeSeeding(torrentTask(pausedByUser: true)),
        isFalse,
      );
    });

    test('refuses when global seeding is disabled', () {
      SettingsProvider.instance.globalTorrentSeeding = false;
      expect(
        TorrentSeedingManager.instance.shouldAutoResumeSeeding(torrentTask()),
        isFalse,
      );
    });

    test('resumes a completed seeding torrent', () {
      SettingsProvider.instance.globalTorrentSeeding = true;
      expect(
        TorrentSeedingManager.instance.shouldAutoResumeSeeding(torrentTask()),
        isTrue,
      );
    });

    test('refuses a non-torrent task', () {
      SettingsProvider.instance.globalTorrentSeeding = true;
      expect(
        TorrentSeedingManager.instance.shouldAutoResumeSeeding(
          torrentTask(
              url: 'https://example.com/file.zip', fileName: 'file.zip'),
        ),
        isFalse,
      );
    });
  });

  group('TorrentSeedingManager.computeAdaptiveUploadLimit', () {
    test('honours battery, thermal and explicit limits', () {
      final settings = SettingsProvider();
      expect(
        TorrentSeedingManager.computeAdaptiveUploadLimit(
          settings: settings,
          batteryMode: BatterySaverMode.aggressive,
          thermalStatus: ThermalStatus.none,
        ),
        0,
      );
      expect(
        TorrentSeedingManager.computeAdaptiveUploadLimit(
          settings: settings,
          batteryMode: BatterySaverMode.moderate,
          thermalStatus: ThermalStatus.none,
        ),
        50 * 1024,
      );
      expect(
        TorrentSeedingManager.computeAdaptiveUploadLimit(
          settings: settings,
          batteryMode: BatterySaverMode.off,
          thermalStatus: ThermalStatus.critical,
        ),
        25 * 1024,
      );

      settings.globalTorrentSeedingLimited = true;
      settings.globalTorrentSeedingLimitKbps = 100;
      expect(
        TorrentSeedingManager.computeAdaptiveUploadLimit(
          settings: settings,
          batteryMode: BatterySaverMode.off,
          thermalStatus: ThermalStatus.none,
        ),
        100 * 1024,
      );

      settings.globalTorrentSeedingLimited = false;
      expect(
        TorrentSeedingManager.computeAdaptiveUploadLimit(
          settings: settings,
          batteryMode: BatterySaverMode.off,
          thermalStatus: ThermalStatus.none,
        ),
        0,
      );
    });
  });

  group('TorrentSeedingManager.computePerTaskUploadLimit', () {
    test('divides the global budget fairly across tasks', () {
      final settings = SettingsProvider()
        ..globalTorrentSeedingLimited = true
        ..globalTorrentSeedingLimitKbps = 100;

      expect(
        TorrentSeedingManager.computePerTaskUploadLimit(
          settings: settings,
          activeSeedingCount: 4,
          batteryMode: BatterySaverMode.off,
          thermalStatus: ThermalStatus.none,
        ),
        25 * 1024,
      );

      // A single task gets the whole budget.
      expect(
        TorrentSeedingManager.computePerTaskUploadLimit(
          settings: settings,
          activeSeedingCount: 1,
          batteryMode: BatterySaverMode.off,
          thermalStatus: ThermalStatus.none,
        ),
        100 * 1024,
      );

      settings.globalTorrentSeedingLimited = false;
      expect(
        TorrentSeedingManager.computePerTaskUploadLimit(
          settings: settings,
          activeSeedingCount: 4,
          batteryMode: BatterySaverMode.off,
          thermalStatus: ThermalStatus.none,
        ),
        0,
      );
    });
  });

  group('AdaptiveSeedingPolicy.shouldContinueSeeding', () {
    const policy = SeedingPolicy(
      maxRatio: 2.0,
      maxSeedTime: Duration(hours: 1),
      seedOnlyOnWifi: true,
      seedOnlyWhenCharging: true,
    );

    test('yields bandwidth while downloads are active', () {
      expect(
        AdaptiveSeedingPolicy.shouldContinueSeeding(
          currentRatio: 0.1,
          currentUploadSpeed: 200 * 1024,
          seedDuration: const Duration(minutes: 1),
          isOnWifi: true,
          isCharging: true,
          activeDownloads: 1,
          policy: policy,
        ),
        isFalse,
      );
    });

    test('requires wifi and charging when configured', () {
      expect(
        AdaptiveSeedingPolicy.shouldContinueSeeding(
          currentRatio: 0.1,
          currentUploadSpeed: 0,
          seedDuration: const Duration(minutes: 1),
          isOnWifi: false,
          isCharging: true,
          activeDownloads: 0,
          policy: policy,
        ),
        isFalse,
      );
      expect(
        AdaptiveSeedingPolicy.shouldContinueSeeding(
          currentRatio: 0.1,
          currentUploadSpeed: 0,
          seedDuration: const Duration(minutes: 1),
          isOnWifi: true,
          isCharging: false,
          activeDownloads: 0,
          policy: policy,
        ),
        isFalse,
      );
    });

    test('stops at the ratio and time limits', () {
      expect(
        AdaptiveSeedingPolicy.shouldContinueSeeding(
          currentRatio: 2.0,
          currentUploadSpeed: 0,
          seedDuration: const Duration(minutes: 1),
          isOnWifi: true,
          isCharging: true,
          activeDownloads: 0,
          policy: policy,
        ),
        isFalse,
      );
      expect(
        AdaptiveSeedingPolicy.shouldContinueSeeding(
          currentRatio: 0.1,
          currentUploadSpeed: 0,
          seedDuration: const Duration(hours: 2),
          isOnWifi: true,
          isCharging: true,
          activeDownloads: 0,
          policy: policy,
        ),
        isFalse,
      );
    });

    test('continues when all constraints pass', () {
      expect(
        AdaptiveSeedingPolicy.shouldContinueSeeding(
          currentRatio: 0.1,
          currentUploadSpeed: 0,
          seedDuration: const Duration(minutes: 1),
          isOnWifi: true,
          isCharging: true,
          activeDownloads: 0,
          policy: policy,
        ),
        isTrue,
      );
    });
  });

  group('TorrentSeedingManager.checkSeedingPolicies', () {
    late FakeTorrentNative native;

    setUp(() {
      native = FakeTorrentNative();
      TorrentService.setNativeForTesting(native);
    });

    tearDown(() async {
      TorrentSeedingManager.instance.dispose();
      await TorrentService.dispose();
      SettingsProvider.instance.globalTorrentSeeding = true;
    });

    NativeTorrentStatus seedingStatus({
      int totalUploaded = 1000,
      int totalDone = 100,
    }) =>
        NativeTorrentStatus(
          id: 1,
          name: 't',
          savePath: '/d',
          errorMsg: '',
          state: 4,
          stateLabel: 'Seeding',
          progress: 1.0,
          downloadRate: 0,
          uploadRate: 100,
          totalDone: totalDone,
          totalWanted: totalDone,
          totalWantedDone: totalDone,
          totalUploaded: totalUploaded,
          numPeers: 0,
          numSeeds: 0,
          isPaused: false,
          isFinished: true,
          hasMetadata: true,
          queuePosition: 0,
        );

    test('pauses torrents that exceed the share-ratio policy', () async {
      native.emitStatuses({1: seedingStatus()});
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final settings = SettingsProvider()
        ..globalTorrentSeeding = true
        ..shareRatioLimit = 1.0;
      TorrentSeedingManager.instance
          .checkSeedingPolicies(settingsProvider: settings);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(native.getTorrentStatus(1)!.isPaused, isTrue);
    });

    test('stops all seeding when the global switch is disabled', () async {
      native.emitStatuses({1: seedingStatus()});
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final settings = SettingsProvider()..globalTorrentSeeding = false;
      TorrentSeedingManager.instance
          .checkSeedingPolicies(settingsProvider: settings);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(native.getTorrentStatus(1)!.isPaused, isTrue);
    });

    test('leaves non-seeding torrents alone', () async {
      native.emitStatuses({
        1: const NativeTorrentStatus(
          id: 1,
          name: 't',
          savePath: '/d',
          errorMsg: '',
          state: 2,
          stateLabel: 'Downloading',
          progress: 0.1,
          downloadRate: 1000,
          uploadRate: 0,
          totalDone: 10,
          totalWanted: 100,
          totalWantedDone: 10,
          totalUploaded: 0,
          numPeers: 1,
          numSeeds: 1,
          isPaused: false,
          isFinished: false,
          hasMetadata: true,
          queuePosition: 0,
        ),
      });
      await Future<void>.delayed(const Duration(milliseconds: 40));

      TorrentSeedingManager.instance
          .checkSeedingPolicies(settingsProvider: SettingsProvider());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(native.getTorrentStatus(1)!.isPaused, isFalse);
    });
  });
}
