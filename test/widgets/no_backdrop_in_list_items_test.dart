import 'dart:io';

import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/downloads/widgets/download_card.dart';
import 'package:dmx/features/downloads/widgets/filter_chips_bar.dart';
import 'package:dmx/features/downloads/widgets/speed_graph_widget.dart';
import 'package:dmx/features/downloads/widgets/status_chip.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/shared/widgets/dmx_backdrop_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('No BackdropFilter in List Items Widget Audit (U1)', () {
    late Directory tempDir;
    late DatabaseService dbService;
    late SettingsProvider settingsProvider;
    late DownloadProvider downloadProvider;
    late DownloadTask sampleTask;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (methodCall) async => null,
      );

      tempDir = await Directory.systemTemp.createTemp('no_backdrop_test_');
      dbService = DatabaseService();
      await dbService.init(testPath: tempDir.path);
      settingsProvider = SettingsProvider();
      await settingsProvider.load();
      downloadProvider = DownloadProvider(
        databaseService: dbService,
        settingsProvider: settingsProvider,
      );

      sampleTask = DownloadTask(
        id: 'test_task_1',
        fileName: 'video.mp4',
        url: 'https://example.com/video.mp4',
        fileSize: 1024 * 1024 * 50,
        downloadedBytes: 1024 * 1024 * 25,
        category: 'video',
        status: DownloadStatus.downloading,
        savePath: '${tempDir.path}/video.mp4',
        localFilePath: '${tempDir.path}/video.mp4',
        tempFilePath: '${tempDir.path}/video.mp4.tmp',
        threadCount: 4,
        chunks: const [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
    });

    tearDown(() async {
      dbService.cancelPendingTimers();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    testWidgets(
        'ListView containing download list items has no BackdropFilter descendants',
        (tester) async {
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
              body: ListView(
                children: [
                  DownloadCard(task: sampleTask),
                  const FilterChipsBar(),
                  const SpeedGraphWidget(speedHistory: [1000, 2000, 1500]),
                  StatusChip(task: sampleTask),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Assert none of the descendants inside the list view is BackdropFilter or DmxBackdropFilter
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(DmxBackdropFilter), findsNothing);
    });
  });
}
