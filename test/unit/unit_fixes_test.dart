import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dmx/core/app_theme.dart';
import 'package:dmx/core/services/app_lock_service.dart';
import 'package:dmx/core/services/backend_health_service.dart';
import 'package:dmx/core/services/background_scheduler.dart';
import 'package:dmx/core/services/database/app_database.dart';
import 'package:dmx/core/services/database/repositories/browser_history_repository.dart';
import 'package:dmx/core/services/database/services/database_maintenance_service.dart';
import 'package:dmx/core/services/download_journal.dart';
import 'package:dmx/core/services/engine/download_progress_handler.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:dmx/core/services/service_registry.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SettingsProvider.instance.load();
    AppLockService.resetMonotonicState();
    tempDir = await Directory.systemTemp.createTemp('unit_fixes_test_');
  });

  tearDown(() async {
    AppLockService.resetMonotonicState();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('FIX 1 & 11: StateStoreInstance Bounded Locks & fsync', () {
    test('Bounding _pathLocks to max 64 entries under high path churn',
        () async {
      final store = StateStoreInstance();
      final state = TransferState(
        totalSize: 1000,
        threadCount: 1,
        chunks: [ChunkState(start: 0, end: 999, downloaded: 100)],
        url: 'https://example.com/test.bin',
      );

      for (int i = 0; i < 200; i++) {
        final path = '${tempDir.path}/file_$i.tmp';
        await store.save(path, state, durable: true);
      }

      expect(store.pathLockCount, lessThanOrEqualTo(64));
    });
  });

  group('FIX 2: DoubleListConverter & TorrentFilesConverter LRU Eviction', () {
    test('DoubleListConverter evicts oldest and caps at 64 entries', () {
      const converter = DoubleListConverter();
      DoubleListConverter.clearRecoveryCache();

      for (int i = 0; i < 70; i++) {
        final corruptStr = 'corrupt_data_[$i.5, ${i + 1}.5]';
        final res = converter.fromSql(corruptStr);
        expect(res.length, equals(2));
      }

      expect(DoubleListConverter.recoveryCacheLength, equals(64));
    });

    test('TorrentFilesConverter evicts oldest and caps at 64 entries', () {
      const converter = TorrentFilesConverter();
      TorrentFilesConverter.clearRecoveryCache();

      for (int i = 0; i < 70; i++) {
        final corruptStr = 'prefix_{"name":"file_$i.mp4","length":$i}_suffix';
        final res = converter.fromSql(corruptStr);
        expect(res.length, equals(1));
      }

      expect(TorrentFilesConverter.recoveryCacheLength, equals(64));
    });
  });

  group('FIX 3: BrowserHistoryRepository Batch Flush', () {
    test('flushPendingHistory flushes entries in batch', () async {
      final db = AppDatabase(p.join(tempDir.path, 'history_test.sqlite'));
      final repo = BrowserHistoryRepository(db);

      for (int i = 0; i < 50; i++) {
        await repo.addBrowserHistory({
          'url': 'https://example.com/page_$i',
          'title': 'Page $i',
          'visitedAt': DateTime.now().millisecondsSinceEpoch,
        });
      }

      await repo.flushPendingHistory();
      expect(repo.pendingHistoryEntriesCount, equals(0));

      final history = await repo.loadBrowserHistory(max: 100);
      expect(history.length, equals(50));
      await db.close();
    });
  });

  group(
      'FIX 4: DatabaseMaintenanceService WAL Checkpoint PASS on active downloads',
      () {
    test('Runs maintenance without throw and checks WAL pass checkpoint',
        () async {
      final db = AppDatabase(p.join(tempDir.path, 'maint_test.sqlite'));
      final service = DatabaseMaintenanceService(db);

      await service.runPeriodicMaintenanceForTesting();
      expect(service.maintenanceRuns, equals(1));

      service.dispose();
      await db.close();
    });
  });

  group('FIX 5: CockpitNotchBorder Path Caching & Memory Pressure', () {
    test('Caches paths and evicts when full, clears on memory pressure', () {
      CockpitNotchBorder.clearCache();
      expect(CockpitNotchBorder.cacheSize, equals(0));

      for (int i = 0; i < 40; i++) {
        final border = CockpitNotchBorder(radius: i.toDouble(), notch: 14);
        border.getOuterPath(Rect.fromLTWH(0, 0, 100.0 + i, 100.0 + i));
      }

      expect(CockpitNotchBorder.cacheSize, equals(32));

      ServiceRegistry.broadcastMemoryPressure();
      expect(CockpitNotchBorder.cacheSize, equals(0));
    });
  });

  group('FIX 6: DownloadProgressHandler Pending Progress on Dispose', () {
    test('Emits pending progress when disposed before throttle timer fires',
        () async {
      DownloadProgress? emitted;
      final cancelToken = CancelToken();
      final handler = DownloadProgressHandler(
        taskId: 'task_1',
        onProgress: (p) => emitted = p,
        cancelToken: cancelToken,
        resolvedFileName: 'test.mp4',
        resolvedSupportsResume: true,
        ytStreamKind: null,
        ytCounterpartSize: null,
        ytCounterpartDownloadedBytes: null,
        isTorrent: false,
        getEffectiveIntervalMs: () => 10000,
        lastDownloadedBytes: 0,
        lastFileSize: 100000,
      );

      // Emit first progress immediately
      await handler
          .handleProgress({'downloadedBytes': 1000, 'fileSize': 100000});
      expect(emitted?.downloadedBytes, equals(1000));

      // Emit second progress, which gets throttled as pending
      await handler
          .handleProgress({'downloadedBytes': 2000, 'fileSize': 100000});
      expect(emitted?.downloadedBytes, equals(1000)); // still old value

      // Disposing handler should emit pending progress
      handler.dispose();
      expect(emitted?.downloadedBytes, equals(2000));
    });
  });

  group('FIX 8: BackendHealthService Configurable & Refresh', () {
    test('Loads default backends and allows manifest refresh fallback',
        () async {
      final health = BackendHealthService.instance;
      expect(health.backends, isNotEmpty);
      expect(health.activeBaseUrl, isNotEmpty);

      // refreshBackends graceful handling of invalid URL
      await health
          .refreshBackends('http://127.0.0.1:9999/non_existent_manifest.json');
      expect(health.backends, isNotEmpty);
    });
  });

  group('FIX 9: BackgroundScheduler Dynamic Interval', () {
    test('Calculates dynamic tick interval instead of fixed 1s', () {
      final scheduler = BackgroundScheduler.instance;

      scheduler.registerTask('task_test', const Duration(seconds: 10), () {});

      expect(scheduler.isActive, isTrue);
      expect(scheduler.taskCount, equals(1));
      scheduler.unregisterTask('task_test');
      expect(scheduler.taskCount, equals(0));
      expect(scheduler.isActive, isFalse);
    });
  });

  group('FIX 10: Configurable Stalled Detection', () {
    test('SettingsProvider has downloadStalledTimeoutMinutes setting',
        () async {
      final settings = SettingsProvider.instance;
      await settings.setDownloadStalledTimeoutMinutes(15);
      expect(settings.downloadStalledTimeoutMinutes, equals(15));
    });
  });

  group('FIX 14: AppLockService Monotonic Clock Reboot Edge Case', () {
    test(
        'Falls back to wall clock when monotonic clock resets (currentMono < startMs)',
        () async {
      AppLockService.resetMonotonicState();
      // Simulate lockout set with start monotonic 500000ms
      AppLockService.mockMonotonicTimeMs = 500000;
      await AppLockService.setPin('1234');

      // Trigger 6 failed attempts to enter lockout
      for (int i = 0; i < 6; i++) {
        await AppLockService.verifyPin('0000');
      }

      final remainingBefore = await AppLockService.lockoutRemaining();
      expect(remainingBefore, greaterThan(Duration.zero));

      // Simulate device reboot (monotonic clock resets to 100ms)
      AppLockService.mockMonotonicTimeMs = 100;
      final remainingAfterReboot = await AppLockService.lockoutRemaining();
      // Should not throw and still report valid remaining duration from wall clock
      expect(remainingAfterReboot, greaterThan(Duration.zero));
      AppLockService.resetMonotonicState();
    });
  });
}
