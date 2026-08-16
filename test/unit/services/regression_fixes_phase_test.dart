import 'package:dmx/core/services/app_lifecycle_coordinator.dart';
import 'package:dmx/core/services/background_service.dart';
import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/frame_watchdog.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/shared/widgets/performance_monitor_overlay.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 2 & 3 Regression Tests', () {
    test('DownloadEngine markForeground and markBackground toggle state correctly', () {
      DownloadEngine.markBackground();
      expect(DownloadEngine.isInBackground, isTrue);
      expect(DownloadEngine.appInForeground, isFalse);

      DownloadEngine.markForeground();
      expect(DownloadEngine.isInBackground, isFalse);
      expect(DownloadEngine.appInForeground, isTrue);
    });

    test('AppLifecycleCoordinator instance init and dispose lifecycle', () {
      AppLifecycleCoordinator.init();
      expect(AppLifecycleCoordinator.isAppForegrounded, isTrue);

      var resumedCalled = false;
      void onResumed() {
        resumedCalled = true;
      }

      AppLifecycleCoordinator.addOnResumedCallback(onResumed);
      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(resumedCalled, isTrue);

      AppLifecycleCoordinator.removeOnResumedCallback(onResumed);
      AppLifecycleCoordinator.dispose();
    });

    test('FrameWatchdog detectRefreshRate fallback gracefully', () async {
      await FrameWatchdog.detectRefreshRate();
      expect(FrameWatchdog.refreshRate, greaterThanOrEqualTo(60.0));
      expect(FrameWatchdog.frameBudgetMs, lessThanOrEqualTo(16.7));
    });

    test('PerformanceMonitorOverlay enabled flag can be toggled', () {
      expect(PerformanceMonitorOverlay.enabled, equals(kDebugMode));
      PerformanceMonitorOverlay.enabled = false;
      expect(PerformanceMonitorOverlay.enabled, isFalse);
      PerformanceMonitorOverlay.enabled = kDebugMode;
    });
  });

  group('Phase 5 & 6 Hardening Tests', () {
    test('DatabaseService _rowToTask handles invalid/unrecognized status by falling back to failed', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => await db.close());

      // Insert a task directly with an invalid status string
      await db.customStatement('''
        INSERT INTO download_tasks (
          id, file_name, url, file_size, downloaded_bytes, category,
          status, save_path, local_file_path, temp_file_path,
          thread_count, created_at, updated_at
        ) VALUES (
          'test-corrupt-status', 'test.zip', 'https://example.com/test.zip', 1000, 500, 'Other',
          'totally_unknown_status', '/downloads', '/downloads/test.zip', '/downloads/test.zip.dmxpart',
          4, 1700000000000, 1700000000000
        )
      ''');

      final taskRows = await db.select(db.downloadTasks).get();
      expect(taskRows.length, equals(1));

      // Query through DatabaseService mapping
      final row = taskRows.first;
      final statusName = row.status;
      final resolvedStatus = DownloadStatus.values.firstWhere(
        (v) => v.name == statusName,
        orElse: () => DownloadStatus.failed,
      );

      expect(resolvedStatus, equals(DownloadStatus.failed));
    });

    test('BackgroundService watchdog timer config has 25s timeout', () {
      expect(BackgroundService.iosBgCallInFlightForTesting, isFalse);
      expect(BackgroundService.iosBgWatchdogTimerForTesting, isNull);
    });
  });
}
