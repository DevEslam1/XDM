import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:drift/drift.dart' as drift;

import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/permission_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import '../../helpers/test_helpers.dart';

class MockConnectivityPlatform extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      Stream.value([ConnectivityResult.wifi]);
}

class FakePermissionService extends PermissionService {
  @override
  Future<String> defaultDownloadDirectory() async => 'build/test_lifecycle_dl';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  drift.driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late DatabaseService database;
  late SettingsProvider settings;
  late DownloadProvider provider;
  late String testDir;

  setUpAll(() {
    setupTestPluginMocks();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ConnectivityPlatform.instance = MockConnectivityPlatform();
    testDir = 'build/test_lifecycle_${DateTime.now().microsecondsSinceEpoch}';

    database = DatabaseService.forSubclass();
    await database.init(testPath: testDir);

    settings = SettingsProvider();
    await settings.load();
    settings.autoRetryEnabled = false;
    await settings.setMaxDownloads(5);

    provider = DownloadProvider(
      databaseService: database,
      settingsProvider: settings,
      permissionService: FakePermissionService(),
    );
    await provider.load();
  });

  tearDown(() async {
    provider.dispose();
    database.dispose();
    try {
      final dir = Directory(testDir);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('FIX-8.2: Download Lifecycle Integration Tests', () {
    test(
        'Task transitions correctly across create -> pause -> resume -> delete',
        () async {
      await provider.addDownload(
        name: 'lifecycle_test.bin',
        url: 'https://example.com/lifecycle_test.bin',
        size: 1024 * 1024,
        category: 'Document',
        savePath: 'build/test_lifecycle_dl',
      );

      expect(provider.tasks.length, 1);
      final taskId = provider.tasks.first.id;
      expect(provider.tasks.first.status,
          anyOf(DownloadStatus.queued, DownloadStatus.downloading));

      // Pause task
      await provider.pauseTask(taskId);
      expect(provider.tasks.first.status, DownloadStatus.paused);

      // Debounce window wait then resume
      await Future.delayed(const Duration(milliseconds: 600));
      await provider.resumeTask(taskId);
      expect(provider.tasks.first.status,
          anyOf(DownloadStatus.downloading, DownloadStatus.queued));

      // Delete task with cleanup
      await provider.deleteTask(taskId, deleteFiles: true);
      expect(provider.tasks.isEmpty, isTrue);
      expect(provider.findTaskById(taskId), isNull);
    });

    test('Batch deletion cleans up all state', () async {
      await provider.addDownload(
        name: 'item1.bin',
        url: 'https://example.com/item1.bin',
        size: 1000,
        category: 'Other',
        savePath: 'build/test_lifecycle_dl',
      );
      await provider.addDownload(
        name: 'item2.bin',
        url: 'https://example.com/item2.bin',
        size: 2000,
        category: 'Other',
        savePath: 'build/test_lifecycle_dl',
      );

      expect(provider.tasks.length, 2);
      final id1 = provider.tasks[0].id;
      final id2 = provider.tasks[1].id;

      await provider.deleteMultipleTasks([id1, id2], deleteFiles: true);
      expect(provider.tasks.isEmpty, isTrue);
      expect(provider.findTaskById(id1), isNull);
      expect(provider.findTaskById(id2), isNull);
    });
  });
}
