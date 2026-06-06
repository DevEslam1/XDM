import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/permission_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';

class MockConnectivityPlatform extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    return [ConnectivityResult.wifi];
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged {
    return Stream.value([ConnectivityResult.wifi]);
  }
}

class FakeDownloadEngine extends DownloadEngine {
  final startedUrls = <String>[];

  @override
  Future<DownloadMetadata> resolveMetadata({
    required String url,
    String? requestedFileName,
    String? customUserAgent,
    bool enableProxy = false,
    String? proxyAddress,
    bool bypassSSL = false,
  }) async {
    return DownloadMetadata(
      fileName: requestedFileName ?? 'file.zip',
      category: 'Archive',
      fileSize: 100,
      supportsResume: true,
    );
  }

  @override
  Future<void> download({
    required String url,
    required String tempFilePath,
    required String localFilePath,
    required int knownFileSize,
    required bool supportsResume,
    required CancelToken cancelToken,
    required ValueChangedProgress onProgress,
    required int Function() speedLimitBytesPerSecond,
    required int Function() activeDownloadCount,
    int threadCount = 1,
    String? customUserAgent,
    bool enableProxy = false,
    String? proxyAddress,
    bool bypassSSL = false,
  }) {
    startedUrls.add(url);
    final completer = Completer<void>();
    cancelToken.whenCancel.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(
          DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
          ),
        );
      }
    });
    return completer.future;
  }
}

class FakePermissionService extends PermissionService {
  @override
  Future<String> defaultDownloadDirectory() async => 'build/test_downloads';

  @override
  Future<bool> ensureStorageAccess() async => true;
}

Future<(DatabaseService, SettingsProvider)> _setupServices() async {
  SharedPreferences.setMockInitialValues({});
  if (!Hive.isBoxOpen(DatabaseService.downloadsBoxName)) {
    await Hive.openBox<dynamic>(DatabaseService.downloadsBoxName);
  }
  await Hive.box<dynamic>(DatabaseService.downloadsBoxName).clear();

  final database = DatabaseService();
  await database.init();
  final settings = SettingsProvider();
  await settings.load();
  return (database, settings);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    Hive.init('build/test_hive_provider');
    ConnectivityPlatform.instance = MockConnectivityPlatform();

    // Register mock handlers for platform channels
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.example.dmx/widget'),
      (methodCall) async => null,
    );
  });

  tearDown(() async {
    if (Hive.isBoxOpen(DatabaseService.downloadsBoxName)) {
      await Hive.box<dynamic>(DatabaseService.downloadsBoxName).clear();
    }
  });

  test('load converts stale downloading tasks to paused', () async {
    final (database, settings) = await _setupServices();
    final now = DateTime.now();
    await database.saveTask(
      DownloadTask(
        id: 'stale',
        fileName: 'stale.zip',
        url: 'https://example.com/stale.zip',
        fileSize: 100,
        downloadedBytes: 10,
        category: 'Archive',
        status: DownloadStatus.downloading,
        savePath: 'build',
        localFilePath: 'build/stale.zip',
        tempFilePath: 'build/stale.zip.dmxpart',
        threadCount: 2,
        chunks: const [0.1, 0.1],
        createdAt: now,
        updatedAt: now,
      ),
    );

    final provider = DownloadProvider(
      databaseService: database,
      settingsProvider: settings,
      downloadEngine: FakeDownloadEngine(),
      permissionService: FakePermissionService(),
    );
    await provider.load();

    expect(provider.tasks.single.status, DownloadStatus.paused);
    expect(provider.tasks.single.speed, 0);
  });

  test('addDownload respects maxDownloads and queues overflow', () async {
    final (database, settings) = await _setupServices();
    await settings.setMaxDownloads(1);
    final engine = FakeDownloadEngine();
    final provider = DownloadProvider(
      databaseService: database,
      settingsProvider: settings,
      downloadEngine: engine,
      permissionService: FakePermissionService(),
    );
    await provider.load();

    await provider.addDownload(
      name: 'one.zip',
      url: 'https://example.com/one.zip',
      size: 0,
      category: '',
      savePath: '',
    );
    await provider.addDownload(
      name: 'two.zip',
      url: 'https://example.com/two.zip',
      size: 0,
      category: '',
      savePath: '',
    );

    expect(provider.downloadingTasksCount, 1);
    expect(provider.queuedTasksCount, 1);
    expect(engine.startedUrls, ['https://example.com/one.zip']);
  });

  test('updateTaskThreadCount on task with zero progress only resizes chunks', () async {
    final (database, settings) = await _setupServices();
    final provider = DownloadProvider(
      databaseService: database,
      settingsProvider: settings,
      downloadEngine: FakeDownloadEngine(),
      permissionService: FakePermissionService(),
    );
    await provider.load();

    await provider.addDownload(
      name: 'test.zip',
      url: 'https://example.com/test.zip',
      size: 100,
      category: '',
      savePath: '',
      threadCount: 2,
    );

    final taskId = provider.tasks.first.id;
    expect(provider.tasks.first.threadCount, 2);
    expect(provider.tasks.first.chunks.length, 2);

    await provider.updateTaskThreadCount(taskId, 5);
    expect(provider.tasks.first.threadCount, 5);
    expect(provider.tasks.first.chunks.length, 5);
    expect(provider.tasks.first.downloadedBytes, 0);
  });

  test('updateTaskThreadCount on task with non-zero progress resets progress and chunks', () async {
    final (database, settings) = await _setupServices();
    final now = DateTime.now();
    final task = DownloadTask(
      id: 'active_task',
      fileName: 'active.zip',
      url: 'https://example.com/active.zip',
      fileSize: 100,
      downloadedBytes: 50,
      category: 'Archive',
      status: DownloadStatus.paused,
      savePath: 'build',
      localFilePath: 'build/active.zip',
      tempFilePath: 'build/active.zip.dmxpart',
      threadCount: 2,
      chunks: const [0.5, 0.5],
      createdAt: now,
      updatedAt: now,
    );
    await database.saveTask(task);

    final provider = DownloadProvider(
      databaseService: database,
      settingsProvider: settings,
      downloadEngine: FakeDownloadEngine(),
      permissionService: FakePermissionService(),
    );
    await provider.load();

    expect(provider.tasks.first.downloadedBytes, 50);
    expect(provider.tasks.first.threadCount, 2);

    await provider.updateTaskThreadCount('active_task', 4);
    expect(provider.tasks.first.threadCount, 4);
    expect(provider.tasks.first.chunks.length, 4);
    expect(provider.tasks.first.downloadedBytes, 0);
    expect(provider.tasks.first.status, DownloadStatus.paused);
  });
}
