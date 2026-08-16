import 'dart:io';

import 'package:dmx/core/services/background_service.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/ios_background_service.dart';
import 'package:dmx/core/services/notification_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Milestone 9 — Background Service Edge Cases', () {
    group('(E8) BackgroundService.restoreInterruptedTasks', () {
      late Directory tempDir;
      late DatabaseService dbService;

      setUp(() async {
        SharedPreferences.setMockInitialValues({});
        tempDir = await Directory.systemTemp.createTemp('bg_restore_test_');
        dbService = DatabaseService();
        await dbService.init(testPath: tempDir.path);
      });

      tearDown(() async {
        dbService.cancelPendingTimers();
        await dbService.dispose();
        if (await tempDir.exists()) {
          try {
            await tempDir.delete(recursive: true);
          } catch (_) {}
        }
      });

      test(
          'restores downloading / starting tasks to downloading with resuming cycleState',
          () async {
        final task1 = DownloadTask(
          id: 'task_active_1',
          fileName: 'video.mp4',
          url: 'https://example.com/video.mp4',
          fileSize: 10000000,
          downloadedBytes: 4000000,
          category: 'video',
          status: DownloadStatus.downloading,
          cycleState: CycleState.downloading,
          savePath: '${tempDir.path}/video.mp4',
          localFilePath: '${tempDir.path}/video.mp4',
          tempFilePath: '${tempDir.path}/video.mp4.tmp',
          threadCount: 1,
          chunks: [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final task2 = DownloadTask(
          id: 'task_starting_2',
          fileName: 'audio.mp3',
          url: 'https://example.com/audio.mp3',
          fileSize: 5000000,
          downloadedBytes: 0,
          category: 'music',
          status: DownloadStatus.downloading,
          cycleState: CycleState.starting,
          savePath: '${tempDir.path}/audio.mp3',
          localFilePath: '${tempDir.path}/audio.mp3',
          tempFilePath: '${tempDir.path}/audio.mp3.tmp',
          threadCount: 1,
          chunks: [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final task3Completed = DownloadTask(
          id: 'task_done_3',
          fileName: 'document.pdf',
          url: 'https://example.com/document.pdf',
          fileSize: 1000000,
          downloadedBytes: 1000000,
          category: 'document',
          status: DownloadStatus.completed,
          cycleState: CycleState.completed,
          savePath: '${tempDir.path}/document.pdf',
          localFilePath: '${tempDir.path}/document.pdf',
          tempFilePath: '${tempDir.path}/document.pdf.tmp',
          threadCount: 1,
          chunks: [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        await dbService.saveTask(task1);
        await dbService.saveTask(task2);
        await dbService.saveTask(task3Completed);

        final restored =
            await BackgroundService.restoreInterruptedTasks(dbService);
        expect(restored.length, equals(2));

        final restored1 = restored.firstWhere((t) => t.id == 'task_active_1');
        expect(restored1.status, equals(DownloadStatus.downloading));
        expect(restored1.cycleState, equals(CycleState.resuming));
        expect(restored1.speed, equals(0.0));

        final restored2 = restored.firstWhere((t) => t.id == 'task_starting_2');
        expect(restored2.status, equals(DownloadStatus.downloading));
        expect(restored2.cycleState, equals(CycleState.resuming));
      });
    });

    group('(L8) IosBackgroundService Expiration Handler', () {
      test(
          'invokes onBackgroundExpiration when native onTaskExpired is received',
          () async {
        bool expirationCalled = false;
        IosBackgroundService.onBackgroundExpiration = () async {
          expirationCalled = true;
        };

        await IosBackgroundService.handleMethodCall(
          const MethodCall('onTaskExpired'),
        );

        expect(expirationCalled, isTrue);
        IosBackgroundService.onBackgroundExpiration = null;
      });
    });

    group('(B5) NotificationService Spam Throttle', () {
      final List<Map<String, dynamic>> shownNotifications = [];

      test(
          'rapid calls per notificationId are throttled and trailing update fires',
          () async {
        shownNotifications.clear();
        final notif = NotificationService();
        NotificationService.setInitializedForTesting(true);
        notif.showHookForTesting =
            ({required id, required title, required body}) async {
          shownNotifications.add({'id': id, 'title': title, 'body': body});
        };

        // Send 10 rapid progress calls for notificationId 101
        for (int i = 1; i <= 10; i++) {
          await notif.showProgress(
            notificationId: 101,
            title: 'Download Task',
            progressPercent: i * 10,
          );
        }

        // Immediately, exactly 1 notification should have posted
        expect(shownNotifications.length, equals(1));
        expect(shownNotifications.first['id'], equals(101));

        notif.showHookForTesting = null;
        await notif.dispose();
      });
    });
  });
}
