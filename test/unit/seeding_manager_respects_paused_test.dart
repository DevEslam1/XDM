import 'package:dmx/core/domain/torrent_models.dart';
import 'package:dmx/core/services/torrent_seeding_manager.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TorrentSeedingManager Paused State Guarding', () {
    late TorrentSeedingManager seedingManager;

    setUp(() {
      seedingManager = TorrentSeedingManager();
    });

    test('shouldStopSeedingForTask returns false when task cycleState is paused', () {
      final now = DateTime.now();
      final pausedTask = DownloadTask(
        id: 'seed_task_1',
        url: 'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335de7ece74fedd',
        fileName: 'Test.torrent',
        category: 'General',
        savePath: '/tmp',
        localFilePath: '/tmp/Test.torrent',
        tempFilePath: '/tmp/Test.torrent.dmxdownload',
        fileSize: 1000000,
        downloadedBytes: 1000000,
        status: DownloadStatus.completed,
        cycleState: CycleState.paused,
        seedingEnabled: true,
        threadCount: 1,
        chunks: const [],
        createdAt: now,
        updatedAt: now,
      );

      final shouldStop = seedingManager.shouldStopSeedingForTask(
        pausedTask,
        currentRatio: 5.0, // well above default 2.0 limit
        seedDuration: const Duration(hours: 10),
        uploadedBytes: 5000000,
        isCharging: true,
        isOnWifi: true,
      );

      expect(shouldStop, isFalse);
    });

    test('shouldStopSeedingForTask returns false when task status is paused', () {
      final now = DateTime.now();
      final pausedTask = DownloadTask(
        id: 'seed_task_2',
        url: 'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335de7ece74fedd',
        fileName: 'Test.torrent',
        category: 'General',
        savePath: '/tmp',
        localFilePath: '/tmp/Test.torrent',
        tempFilePath: '/tmp/Test.torrent.dmxdownload',
        fileSize: 1000000,
        downloadedBytes: 1000000,
        status: DownloadStatus.paused,
        seedingEnabled: true,
        threadCount: 1,
        chunks: const [],
        createdAt: now,
        updatedAt: now,
      );

      final shouldStop = seedingManager.shouldStopSeedingForTask(
        pausedTask,
        currentRatio: 10.0,
        seedDuration: const Duration(hours: 5),
        uploadedBytes: 10000000,
        isCharging: true,
        isOnWifi: true,
      );

      expect(shouldStop, isFalse);
    });

    test('shouldAutoResumeSeeding returns false for paused tasks', () {
      final now = DateTime.now();
      final pausedTask = DownloadTask(
        id: 'seed_task_3',
        url: 'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335de7ece74fedd',
        fileName: 'Test.torrent',
        category: 'General',
        savePath: '/tmp',
        localFilePath: '/tmp/Test.torrent',
        tempFilePath: '/tmp/Test.torrent.dmxdownload',
        fileSize: 1000000,
        downloadedBytes: 1000000,
        status: DownloadStatus.paused,
        pausedByUser: true,
        seedingEnabled: true,
        threadCount: 1,
        chunks: const [],
        createdAt: now,
        updatedAt: now,
      );

      expect(seedingManager.shouldAutoResumeSeeding(pausedTask), isFalse);
    });

    test('SeedingPolicy returns false when cycleState is paused', () {
      const policy = SeedingPolicy(
        maxRatio: 1.5,
        maxSeedTime: Duration(hours: 1),
      );

      final result = policy.shouldStopSeeding(
        currentRatio: 3.0,
        seedDuration: const Duration(hours: 2),
        uploadedBytes: 3000000,
        isCharging: true,
        isOnWifi: true,
        cycleState: CycleState.paused,
      );

      expect(result, isFalse);
    });
  });
}
