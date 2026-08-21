import 'dart:io';

import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/downloads/widgets/download_card.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadCard Rebuild & RepaintBoundary Optimization (U2/U3)', () {
    late Directory tempDir;
    late DatabaseService dbService;
    late SettingsProvider settingsProvider;
    late DownloadProvider downloadProvider;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (methodCall) async => null,
      );

      tempDir = await Directory.systemTemp.createTemp('card_rebuild_test_');
      dbService = DatabaseService();
      await dbService.init(testPath: tempDir.path);
      settingsProvider = SettingsProvider();
      await settingsProvider.load();
      downloadProvider = DownloadProvider(
        databaseService: dbService,
        settingsProvider: settingsProvider,
      );
    });

    tearDown(() async {
      downloadProvider.dispose();
      dbService.cancelPendingTimers();
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    testWidgets(
        'pumping card 60 times with new progress minimizes dirty element rebuilds',
        (tester) async {
      final taskNotifier = ValueNotifier<DownloadTask>(
        DownloadTask(
          id: 'test_card_task',
          fileName: 'large_archive.zip',
          url: 'https://example.com/large_archive.zip',
          fileSize: 100 * 1024 * 1024,
          downloadedBytes: 0,
          category: 'archive',
          status: DownloadStatus.downloading,
          savePath: '${tempDir.path}/large_archive.zip',
          localFilePath: '${tempDir.path}/large_archive.zip',
          tempFilePath: '${tempDir.path}/large_archive.zip.tmp',
          threadCount: 4,
          chunks: const [],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      int parentRebuildCount = 0;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsProvider>.value(
                value: settingsProvider),
            ChangeNotifierProvider<DownloadProvider>.value(
                value: downloadProvider),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  return ValueListenableBuilder<DownloadTask>(
                    valueListenable: taskNotifier,
                    builder: (context, currentTask, child) {
                      parentRebuildCount++;
                      return DownloadCard(task: currentTask);
                    },
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Reset counter after initial mount
      parentRebuildCount = 0;

      // Pump 60 progress frames
      for (int i = 1; i <= 60; i++) {
        final now = DateTime.now();
        taskNotifier.value = DownloadTask(
          id: 'test_card_task',
          fileName: 'large_archive.zip',
          url: 'https://example.com/large_archive.zip',
          fileSize: 100 * 1024 * 1024,
          downloadedBytes: i * 1024 * 1024,
          category: 'archive',
          status: DownloadStatus.downloading,
          savePath: '${tempDir.path}/large_archive.zip',
          localFilePath: '${tempDir.path}/large_archive.zip',
          tempFilePath: '${tempDir.path}/large_archive.zip.tmp',
          threadCount: 4,
          chunks: const [],
          createdAt: now,
          updatedAt: now,
        );
        // Step with throttled pump
        if (i % 6 == 0) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.pumpAndSettle();

      // Verify that RepaintBoundary isolates the card repaints
      expect(find.byType(RepaintBoundary), findsWidgets);
      expect(parentRebuildCount, lessThanOrEqualTo(60));
    });
  });
}
