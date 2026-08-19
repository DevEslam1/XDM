import 'package:dmx/core/di/injection.dart';
import 'package:dmx/core/services/background_service.dart';
import 'package:dmx/core/services/bandwidth_governor.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/data/task_repository.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/progress_emitter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Production Readiness & Hardening Tests', () {
    test('BandwidthGovernor unlimited constant semantics (P1-6)', () {
      final governor = BandwidthGovernor(BandwidthGovernor.unlimited);
      expect(governor.globalBytesPerSecond, 0);
      expect(governor.isUnlimited, isTrue);

      governor.registerConsumer();
      expect(governor.isUnlimited, isTrue);

      governor.setGlobalLimit(1024 * 1024); // 1 MB/s
      expect(governor.isUnlimited, isFalse);
      expect(governor.globalBytesPerSecond, 1024 * 1024);

      governor.setGlobalLimit(BandwidthGovernor.unlimited);
      expect(governor.isUnlimited, isTrue);
      governor.dispose();
    });

    test('ProgressEmitter updates, throttling, and memory cleanup (P0-5)', () {
      final emitter = ProgressEmitter(throttleDuration: Duration.zero);
      const taskId = 'task-readiness-1';

      final progressNotif = emitter.progressNotifier(taskId);
      final speedNotif = emitter.speedNotifier(taskId);

      expect(progressNotif.value, 0.0);
      expect(speedNotif.value, 0.0);

      // In foreground
      emitter.pushTick(taskId, 0.25, 500000);
      expect(progressNotif.value, 0.25);
      expect(speedNotif.value, 500000);

      // Micro delta (< 0.005) should be filtered to prevent UI churn
      emitter.pushTick(taskId, 0.252, 500100);
      expect(progressNotif.value, 0.25); // unchanged

      // Significant delta should push
      emitter.pushTick(taskId, 0.26, 600000);
      expect(progressNotif.value, 0.26);
      expect(speedNotif.value, 600000);

      // Refresh on resume re-emits last known progress
      emitter.refreshOnResume();
      expect(progressNotif.value, 0.26);

      emitter.disposeTaskNotifier(taskId);
      emitter.dispose();
    });

    test('Android 15 dataSync 6-hour timeout graceful pause and retry (P1-1)',
        () async {
      BackgroundService.testMode = true;
      bool pauseCallbackInvoked = false;

      BackgroundService.onDataSyncTimeout = () async {
        pauseCallbackInvoked = true;
      };

      await BackgroundService.start();
      expect(BackgroundService.dataSyncSessionStartTimeForTesting, isNotNull);

      await BackgroundService.triggerDataSyncTimeoutForTesting();
      expect(pauseCallbackInvoked, isTrue);
      expect(BackgroundService.dataSyncSessionStartTimeForTesting, isNull);

      await BackgroundService.stop();
      BackgroundService.onDataSyncTimeout = null;
    });

    test('DI reset dependencies for testing (P1-9)', () async {
      await resetDependenciesForTesting();
      expect(getIt.isRegistered<DatabaseService>(), isFalse);

      await configureDependencies();
      expect(getIt.isRegistered<DatabaseService>(), isTrue);
      expect(getIt.isRegistered<TaskRepository>(), isTrue);
      expect(getIt.isRegistered<BandwidthGovernor>(), isTrue);

      final governor = inject<BandwidthGovernor>();
      expect(governor.isUnlimited, isTrue);
    });

    test('TaskRepository interface compliance with in-memory implementation',
        () async {
      final repo = InMemoryTaskRepository();
      final now = DateTime.now();
      final task = DownloadTask(
        id: 'repo-task-1',
        url: 'https://example.com/file.zip',
        fileName: 'file.zip',
        fileSize: 1024,
        downloadedBytes: 0,
        category: 'other',
        status: DownloadStatus.queued,
        savePath: '/downloads',
        localFilePath: '/downloads/file.zip',
        tempFilePath: '/downloads/repo-task-1.tmp',
        threadCount: 2,
        chunks: const [0.0, 0.0],
        createdAt: now,
        updatedAt: now,
      );

      await repo.save(task);
      final retrieved = await repo.getById('repo-task-1');
      expect(retrieved, isNotNull);
      expect(retrieved?.id, 'repo-task-1');

      final all = await repo.getAll();
      expect(all.length, 1);

      await repo.delete('repo-task-1');
      final afterDelete = await repo.getById('repo-task-1');
      expect(afterDelete, isNull);
    });
  });
}
