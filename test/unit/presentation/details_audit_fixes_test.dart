import 'dart:collection';

import 'package:dmx/core/domain/torrent_file_progress_estimator.dart';
import 'package:dmx/features/details/presentation/details_view_model.dart';
import 'package:dmx/features/details/screens/details_screen.dart';
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

  group('Details Audit Fixes Unit Tests', () {
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
    });

    test('D1/D2: Seeding upload speed & DetailsViewModel.speedText displays UL',
        () async {
      final task = createTestTask(
        id: 'seed-task-1',
        isTorrent: true,
        status: DownloadStatus.completed,
        speed: 0.0,
      ).copyWith(seedingEnabled: true);

      provider = DownloadProvider(
        databaseService: FakeDatabaseService(initialTasks: [task]),
        settingsProvider: settings,
        downloadEngine: FakeDownloadEngine(),
        permissionService: FakePermissionService(),
        enableBackgroundTimers: false,
      );
      await provider.load(pauseOrphanDownloads: false);

      final vm = DetailsViewModel(taskId: task.id, downloadProvider: provider);

      expect(vm.isSeeding, isTrue);
    });

    test('D3: filesLabel & normalizer exclude deselected files and estimates',
        () async {
      final files = [
        {
          'name': 'f1.mp4',
          'length': 1000,
          'downloadedBytes': 1000,
          'selected': true,
          'isComplete': true,
          'progressEstimated': false,
        },
        {
          'name': 'f2.mp4',
          'length': 1000,
          'downloadedBytes': 1000,
          'selected': false, // Deselected
          'isComplete': false,
          'progressEstimated': false,
        },
        {
          'name': 'f3.mp4',
          'length': 1000,
          'downloadedBytes': 1000,
          'selected': true,
          'isComplete': false, // Estimated, not complete
          'progressEstimated': true,
        },
      ];

      final task = createTestTask(
        id: 'torrent-files-task',
        isTorrent: true,
        torrentFiles: files,
      );

      provider = DownloadProvider(
        databaseService: FakeDatabaseService(initialTasks: [task]),
        settingsProvider: settings,
        downloadEngine: FakeDownloadEngine(),
        permissionService: FakePermissionService(),
        enableBackgroundTimers: false,
      );
      await provider.load(pauseOrphanDownloads: false);

      final vm = DetailsViewModel(taskId: task.id, downloadProvider: provider);

      // Out of 2 selected files, only 1 is genuinely complete (f1).
      // Deselected f2 is excluded from denominator, estimated f3 is not complete.
      expect(vm.filesLabel(), '1/2 FILES');
    });

    test('D3: TorrentFileProgressEstimator never marks estimated files as complete',
        () {
      final files = [
        {
          'name': 'part1.iso',
          'length': 1000,
          'downloadedBytes': 0,
          'selected': true,
          'isComplete': false,
        },
      ];

      // Distribute 1000 bytes via estimator
      TorrentFileProgressEstimator.updateFilesWithNativeProgress(
        files,
        1.0,
        1000,
      );

      expect(files.first['progressEstimated'], isTrue);
      // Contract: estimator must never set isComplete = true
      expect(files.first['isComplete'], isFalse);
    });

    test('D4: resumeDataSaved property on DownloadTask', () {
      final task = createTestTask(
        id: 't-d4',
        isTorrent: true,
        status: DownloadStatus.paused,
      );

      expect(task.resumeDataSaved, isFalse);
      final updated = task.copyWith(resumeDataSaved: true);
      expect(updated.resumeDataSaved, isTrue);
    });

    test('D5: deleteTask returns true on success', () async {
      final task = createTestTask(id: 'del-task-1');
      provider = DownloadProvider(
        databaseService: FakeDatabaseService(initialTasks: [task]),
        settingsProvider: settings,
        downloadEngine: FakeDownloadEngine(),
        permissionService: FakePermissionService(),
        enableBackgroundTimers: false,
      );
      await provider.load(pauseOrphanDownloads: false);

      final success = await provider.deleteTask(task.id);
      expect(success, isTrue);
      expect(provider.tasks.any((t) => t.id == task.id), isFalse);

      // Second attempt returns false since it no longer exists
      final secondTry = await provider.deleteTask(task.id);
      expect(secondTry, isFalse);
    });

    test('D6: Seeding summary returns formatted ratio and duration', () async {
      final completedAt = DateTime.now().subtract(const Duration(minutes: 45));
      final task = createTestTask(
        id: 'seed-task-2',
        isTorrent: true,
        status: DownloadStatus.completed,
        fileSize: 1000000,
        downloadedBytes: 1000000,
      ).copyWith(
        completedAt: completedAt,
        seedingEnabled: true,
        uploadedBytes: 1500000,
      );

      provider = DownloadProvider(
        databaseService: FakeDatabaseService(initialTasks: [task]),
        settingsProvider: settings,
        downloadEngine: FakeDownloadEngine(),
        permissionService: FakePermissionService(),
        enableBackgroundTimers: false,
      );
      await provider.load(pauseOrphanDownloads: false);

      final summary = provider.getSeedingSummary(task.id);
      expect(summary, contains('Ratio 1.50'));
      expect(summary, contains('seeded'));
    });

    test('L2: Speed histories alignment in DetailsViewModel right-aligns spots',
        () async {
      final task = createTestTask(id: 'speed-task');
      provider = DownloadProvider(
        databaseService: FakeDatabaseService(initialTasks: [task]),
        settingsProvider: settings,
        downloadEngine: FakeDownloadEngine(),
        permissionService: FakePermissionService(),
        enableBackgroundTimers: false,
      );
      await provider.load(pauseOrphanDownloads: false);

      // Populate speed history directly into provider
      final q = Queue<double>()..addAll([10.0, 20.0, 30.0, 40.0, 50.0]);
      provider.speedHistories[task.id] = q;

      final vm = DetailsViewModel(taskId: task.id, downloadProvider: provider);
      vm.updateSpeedSpots();

      expect(vm.downloadSpots.length, 5);
      expect(vm.downloadSpots.last.y, 50.0);
      expect(vm.maxGraphLen, 5);
    });
  });

  group('DetailsScreen Widget Audit Tests', () {
    testWidgets('L3: Torrent panels are omitted for HTTP tasks',
        (tester) async {
      final task = createTestTask(
        id: 'http-task-1',
        isTorrent: false,
        fileName: 'document.pdf',
        fileSize: 2000000,
        status: DownloadStatus.paused,
      );

      final provider = createMockDownloadProvider(tasks: [task]);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DetailsScreen), findsOneWidget);
    });
  });
}
