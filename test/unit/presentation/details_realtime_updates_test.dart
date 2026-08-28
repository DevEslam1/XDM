import 'dart:collection';
import 'package:dmx/core/utils/torrent_id_resolver.dart';
import 'package:dmx/features/details/presentation/details_view_model.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/downloads/provider/schedule_manager.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_services.dart';
import '../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;
  late DownloadProvider provider;

  setUp(() async {
    setupTestPluginMocks();
    ScheduleManager.isAndroidForTesting = true;
    SharedPreferences.setMockInitialValues({
      'isDarkMode': true,
      'autoStart': false,
      'maxDownloads': 3,
      'defaultThreadCount': 8,
      'speedLimitMb': 0.0,
      'notificationsEnabled': true,
      'wifiOnly': false,
      'batterySaverMode': false,
    });
    settings = SettingsProvider();
    await settings.load();

    provider = DownloadProvider(
      databaseService: FakeDatabaseService(),
      settingsProvider: settings,
      downloadEngine: FakeDownloadEngine(),
      permissionService: FakePermissionService(),
      enableBackgroundTimers: false,
    );
  });

  tearDown(() {
    provider.dispose();
  });

  group('Requirement 1 & 5: DownloadTask torrentId & TorrentIdResolver', () {
    test('DownloadTask preserves torrentId in copyWith, toMap, fromMap', () {
      final task = DownloadTask(
        id: 't-1',
        fileName: 'movie.torrent',
        url: 'magnet:?xt=urn:btih:1234567890abcdef',
        fileSize: 1024 * 1024 * 500,
        downloadedBytes: 0,
        category: 'Torrent',
        status: DownloadStatus.downloading,
        savePath: '/test/downloads',
        localFilePath: '/test/downloads/movie.mp4',
        tempFilePath: '/test/downloads/movie.mp4.dmxpart',
        threadCount: 4,
        chunks: const [0, 0, 0, 0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        torrentId: 42,
      );

      expect(task.torrentId, 42);

      final map = task.toMap();
      expect(map['torrentId'], 42);

      final fromMapTask = DownloadTask.fromMap(map);
      expect(fromMapTask.torrentId, 42);

      final copied = task.copyWith(torrentId: 99);
      expect(copied.torrentId, 99);

      final cleared = copied.copyWith(clearTorrentId: true);
      expect(cleared.torrentId, isNull);
    });

    test('TorrentIdResolver uses stored task.torrentId first', () {
      final taskWithStoredId = DownloadTask(
        id: 'task-abc',
        fileName: 'ubuntu.iso',
        url: 'magnet:?xt=urn:btih:0000000000000000000000000000000000000000',
        fileSize: 1000,
        downloadedBytes: 0,
        category: 'Torrent',
        status: DownloadStatus.downloading,
        savePath: '/test',
        localFilePath: '/test/ubuntu.iso',
        tempFilePath: '/test/ubuntu.iso.dmxpart',
        threadCount: 4,
        chunks: const [0, 0, 0, 0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        torrentId: 77,
      );

      final resolved = TorrentIdResolver.resolve(
        taskWithStoredId,
        providerMap: {'task-abc': 11},
      );
      expect(resolved, 77);
    });
  });

  group('Requirement 3: DetailsViewModel self-refresh and disposal', () {
    test('DetailsViewModel refreshes spots and cancels timer on dispose',
        () async {
      final task = createTestTask(
        id: 'speed-task-1',
        status: DownloadStatus.downloading,
        speed: 1024 * 100,
      );

      await provider.restoreTask(task);
      provider.speedHistories[task.id] = Queue<double>()
        ..addAll([100.0, 200.0, 300.0]);

      final vm = DetailsViewModel(
        taskId: 'speed-task-1',
        downloadProvider: provider,
      );

      expect(vm.task?.id, 'speed-task-1');
      expect(vm.downloadSpots, isNotEmpty);
      expect(vm.downloadSpots.last.y, 300.0);

      // Verify dispose can be safely invoked
      vm.dispose();
      expect(vm.isDisposed, isTrue);

      // Calling dispose again should be safe and idempotent
      expect(() => vm.dispose(), returnsNormally);

      // Calling updateSpeedSpots after dispose should be safe and not throw
      expect(() => vm.updateSpeedSpots(), returnsNormally);
    });
  });

  group(
      'Requirement 2 & 4: Speed History & Upload History tracking in DownloadProvider',
      () {
    test(
        'getSpeedHistory and getUploadSpeedHistory return empty list by default',
        () {
      expect(provider.getSpeedHistory('non-existent'), isEmpty);
      expect(provider.getUploadSpeedHistory('non-existent'), isEmpty);
    });
  });
}
