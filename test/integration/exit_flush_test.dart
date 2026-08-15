import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/downloads/provider/schedule_manager.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_services.dart';
import '../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadProvider exit-time progress flush (H9)', () {
    late DownloadProvider provider;
    late FakeDatabaseService database;
    late SettingsProvider settings;

    setUp(() async {
      ScheduleManager.isAndroidForTesting = true;
      setupTestPluginMocks();
      SharedPreferences.setMockInitialValues({
        'autoStart': true,
        'maxDownloads': 3,
        'batterySaverMode': false,
      });
      settings = SettingsProvider();
      await settings.load();
      database = FakeDatabaseService();
      provider = DownloadProvider(
        databaseService: database,
        settingsProvider: settings,
        downloadEngine: FakeDownloadEngine(),
        permissionService: FakePermissionService(),
        enableBackgroundTimers: false,
      );
      addTearDown(() => provider.dispose());
      await provider.load(pauseOrphanDownloads: false);
    });

    /// Seeds a task via the DB, loads the provider, transitions it to
    /// downloading (structural save), then pushes a progress-only update that
    /// defers the DB write.
    Future<DownloadTask> seedTaskWithDeferredProgress() async {
      await database.saveTask(createTestTask(
        id: 'exit-1',
        fileName: 'flush.bin',
        status: DownloadStatus.queued,
        downloadedBytes: 0,
        speed: 0,
      ));
      await provider.load(pauseOrphanDownloads: false);

      final queued = provider.taskById('exit-1')!;
      await provider.setTaskState(queued.copyWith(
        status: DownloadStatus.downloading,
        downloadedBytes: 1048576,
        speed: 5242880,
      ));

      // Progress-only update: status unchanged -> deferred into pending set.
      final downloading = provider.taskById('exit-1')!;
      await provider.setTaskState(downloading.copyWith(
        downloadedBytes: 2097152,
        speed: 10485760,
      ));
      return provider.taskById('exit-1')!;
    }

    test('progress-only updates defer the DB write into pendingProgressUpdates',
        () async {
      final task = await seedTaskWithDeferredProgress();

      expect(task.downloadedBytes, 2097152);
      expect(provider.pendingProgressUpdates, contains(task.id));

      // The DB must NOT yet reflect the deferred progress-only update.
      final dbTasks = await database.loadTasks();
      final dbTask = dbTasks.firstWhere((t) => t.id == task.id);
      expect(dbTask.downloadedBytes, 1048576);
    });

    test('flushPendingProgress persists the in-memory task and clears the flag',
        () async {
      final task = await seedTaskWithDeferredProgress();
      expect(provider.pendingProgressUpdates, contains(task.id));

      await provider.flushPendingProgress(task.id);

      expect(provider.pendingProgressUpdates, isNot(contains(task.id)));
      final dbTasks = await database.loadTasks();
      final dbTask = dbTasks.firstWhere((t) => t.id == task.id);
      expect(dbTask.downloadedBytes, 2097152);
    });

    test('flushPendingProgress is idempotent and safe for unknown ids',
        () async {
      final task = await seedTaskWithDeferredProgress();

      // A second flush after the first is a no-op (re-entry guarded).
      await provider.flushPendingProgress(task.id);
      await provider.flushPendingProgress(task.id);
      expect(provider.pendingProgressUpdates, isEmpty);

      // Unknown ids are safe no-ops.
      await provider.flushPendingProgress('does-not-exist');
      expect(provider.pendingProgressUpdates, isEmpty);
    });

    test('exit-flush loop persists every task with deferred progress',
        () async {
      final ids = <String>[];
      for (var i = 0; i < 3; i++) {
        await database.saveTask(createTestTask(
          id: 'exit-$i',
          fileName: 'flush-$i.bin',
          status: DownloadStatus.queued,
          downloadedBytes: 0,
          speed: 0,
        ));
        ids.add('exit-$i');
      }
      await provider.load(pauseOrphanDownloads: false);

      for (final id in ids) {
        final queued = provider.taskById(id)!;
        await provider.setTaskState(queued.copyWith(
          status: DownloadStatus.downloading,
          downloadedBytes: 1024,
          speed: 2048,
        ));
        final downloading = provider.taskById(id)!;
        await provider.setTaskState(downloading.copyWith(
          downloadedBytes: 4096,
          speed: 8192,
        ));
      }

      expect(provider.pendingProgressUpdates, containsAll(ids));

      // The same flush loop exitApp() runs before shutting down.
      for (final task in provider.tasks) {
        await provider.flushPendingProgress(task.id);
      }

      expect(provider.pendingProgressUpdates, isEmpty);
      final dbTasks = await database.loadTasks();
      for (final id in ids) {
        final dbTask = dbTasks.firstWhere((t) => t.id == id);
        expect(dbTask.downloadedBytes, 4096);
      }
    });
  });
}
