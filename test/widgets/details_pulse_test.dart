import 'package:dmx/core/di/injection.dart';
import 'package:dmx/features/details/screens/details_screen.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/downloads/provider/schedule_manager.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/shared/widgets/geometric_grid_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_services.dart';
import '../helpers/test_helpers.dart';

/// Reads the pulse AnimationController driving the telemetry ring so tests can
/// assert on its running state without relying on transient frame counts.
AnimationController pulseControllerOf(WidgetTester tester) {
  final builder = tester.widget<AnimatedBuilder>(
    find.descendant(
      of: find.byKey(const ValueKey('details_pulse_ring')),
      matching: find.byType(AnimatedBuilder),
    ),
  );
  return builder.animation as AnimationController;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DetailsScreen pulse animation (H12)', () {
    late DownloadProvider provider;

    setUp(() async {
      setupTestPluginMocks();
      // Mirror Android production behavior: scheduled-download checks are
      // handled by WorkManager there, so ScheduleManager creates no timer.
      // Without this the 15s fallback timer stays pending at test teardown.
      ScheduleManager.isAndroidForTesting = true;
      SharedPreferences.setMockInitialValues({
        'isDarkMode': true,
        'autoStart': true,
        'maxDownloads': 3,
        'defaultThreadCount': 8,
        'speedLimitMb': 0.0,
        'notificationsEnabled': true,
        'wifiOnly': false,
        'batterySaverMode': false,
      });
      final settings = SettingsProvider();
      await settings.load();
      if (!getIt.isRegistered<AmbientProgress>()) {
        getIt.registerLazySingleton<AmbientProgress>(() => AmbientProgress());
      }

      final task = createTestTask(
        fileName: 'pulse.bin',
        status: DownloadStatus.queued,
        downloadedBytes: 0,
        speed: 0,
      );
      provider = DownloadProvider(
        databaseService: FakeDatabaseService(initialTasks: [task]),
        settingsProvider: settings,
        downloadEngine: FakeDownloadEngine(),
        permissionService: FakePermissionService(),
        enableBackgroundTimers: false,
      );
      await provider.load(pauseOrphanDownloads: false);
      // load() may convert non-completed tasks to paused; normalize to queued
      // so the tests can transition to downloading without the engine running.
      final loaded = provider.tasks.single;
      await provider.setTaskState(loaded.copyWith(
        status: DownloadStatus.queued,
        pausedByUser: false,
        speed: 0,
        downloadedBytes: 0,
      ));
    });

    tearDown(() {
      provider.dispose();
      if (getIt.isRegistered<AmbientProgress>()) {
        getIt<AmbientProgress>().stopAll();
      }
    });

    // DownloadProvider.notifyListeners() coalesces notifications to one per
    // 250ms of real time. Status transitions in these tests happen much faster
    // than real-world downloads, so a real delay is required between
    // structural changes for the throttle to release the notification.
    Future<void> settleNotifyThrottle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 320)),
      );
    }

    testWidgets('pulse keeps animating while the task is downloading',
        (tester) async {
      // Phone-sized portrait surface avoids the landscape two-column layout.
      tester.view.physicalSize = const Size(1440, 3120);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final task = provider.tasks.single;
      expect(task.status, DownloadStatus.queued);

      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      // Release the 250ms notify throttle left by setUp()'s queued transition.
      await settleNotifyThrottle(tester);

      // Task starts downloading -> build() calls _pulse.repeat(reverse: true).
      await provider.setTaskState(
        task.copyWith(
          status: DownloadStatus.downloading,
          downloadedBytes: 52428800,
          speed: 5242880,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      final pulse = pulseControllerOf(tester);
      expect(pulse.isAnimating, isTrue);
    });

    testWidgets('pulse stops when the task completes', (tester) async {
      tester.view.physicalSize = const Size(1440, 3120);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final task = provider.tasks.single;
      await tester.pumpWidget(createTestApp(
        child: DetailsScreen(taskId: task.id),
        downloadProvider: provider,
      ));
      // Release the 250ms notify throttle left by setUp()'s queued transition.
      await settleNotifyThrottle(tester);

      await provider.setTaskState(
        task.copyWith(
          status: DownloadStatus.downloading,
          downloadedBytes: 52428800,
          speed: 5242880,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(pulseControllerOf(tester).isAnimating, isTrue);

      // Let the notify throttle release before the structural transition.
      await settleNotifyThrottle(tester);

      // Complete the task through the provider; build() calls _pulse.stop().
      await provider.setTaskState(task.copyWith(
        status: DownloadStatus.completed,
        downloadedBytes: task.fileSize,
        speed: 0,
        completedAt: DateTime.now(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(pulseControllerOf(tester).isAnimating, isFalse);
    });
  });
}
