import 'dart:collection';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:dmx/core/constants/thresholds.dart';
import 'package:dmx/core/interfaces/i_torrent_service.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/permission_service.dart';
import 'package:dmx/core/services/positional_file_writer.dart';
import 'package:dmx/core/services/torrent_service_stub.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockConnectivityPlatform extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      Stream.value([ConnectivityResult.wifi]);
}

class _FakeDownloadEngine extends Fake implements DownloadEngine {
  @override
  void updateSpeedLimit(int bytesPerSecond, int activeDownloads) {}
  @override
  Future<bool> hasEnoughDiskSpace(String path, int requiredBytes) async => true;
  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() async {}
}

class _FakePermissionService extends Fake implements PermissionService {
  @override
  Future<bool> isStoragePermissionValid() async => true;
  @override
  Future<String> defaultDownloadDirectory() async => 'build/test_downloads';
}

Future<(DatabaseService, SettingsProvider)> _setupServices() async {
  SharedPreferences.setMockInitialValues({});
  if (!Hive.isBoxOpen(DatabaseService.downloadsBoxName)) {
    await Hive.openBox<dynamic>(DatabaseService.downloadsBoxName);
  }
  await Hive.box<dynamic>(DatabaseService.downloadsBoxName).clear();

  final database = DatabaseService.forSubclass();
  await database.init(testPath: 'build/test_hive_audit_fixes');
  final settings = SettingsProvider();
  await settings.load();
  return (database, settings);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    drift.driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    Hive.init('build/test_hive_audit_fixes');
    ConnectivityPlatform.instance = _MockConnectivityPlatform();

    final getIt = GetIt.instance;
    if (getIt.isRegistered<ITorrentService>()) {
      getIt.unregister<ITorrentService>();
    }
    getIt.registerSingleton<ITorrentService>(TorrentServiceStub());

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.dmx.app/torrent'),
      (methodCall) async {
        if (methodCall.method == 'init') return {'status': 'ok'};
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (methodCall) async => null,
    );
  });

  group('Production Readiness Audit Fixes Verification', () {
    test('P2-11: Thresholds are hardened to low loss windows', () {
      expect(kJournalBackgroundWriteDelta, equals(1 * 1024 * 1024));
      expect(kJournalScreenOffWriteDelta, equals(2 * 1024 * 1024));
      expect(kStateSaveBgDelta, equals(2 * 1024 * 1024));
      expect(kStateSaveFgDelta, equals(512 * 1024));
    });

    test(
        'P0-3: Completion byte pinning ensures exact 100% progress and matching sizes',
        () async {
      final (database, settings) = await _setupServices();
      final provider = DownloadProvider(
        databaseService: database,
        settingsProvider: settings,
        downloadEngine: _FakeDownloadEngine(),
        permissionService: _FakePermissionService(),
      );

      final task = DownloadTask(
        id: 'test-completion-pin',
        fileName: 'file.bin',
        url: 'https://example.com/file.bin',
        fileSize: 5000,
        downloadedBytes: 4800,
        threadCount: 1,
        chunks: const [0.96],
        category: 'Document',
        status: DownloadStatus.downloading,
        savePath: 'build',
        localFilePath: 'build/file.bin',
        tempFilePath: 'build/file.dmxpart',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await database.saveTask(task);
      await provider.load();

      // Simulate completion update
      final completedUpdate = task.copyWith(
        status: DownloadStatus.completed,
        downloadedBytes: 4800,
      );
      await database.saveTask(completedUpdate);
      await provider.load();

      final live = provider.taskById('test-completion-pin')!;
      expect(live.status, DownloadStatus.completed);
      expect(live.downloadedBytes, equals(5000));
      expect(live.fileSize, equals(5000));
      expect(live.progress, equals(1.0));

      provider.dispose();
      database.dispose();
    });

    test('P1-5: Memory tracking maps are purged on task deletion', () async {
      final (database, settings) = await _setupServices();
      final provider = DownloadProvider(
        databaseService: database,
        settingsProvider: settings,
        downloadEngine: _FakeDownloadEngine(),
        permissionService: _FakePermissionService(),
      );

      final task = DownloadTask(
        id: 'test-mem-leak',
        fileName: 'data.iso',
        url: 'https://example.com/data.iso',
        fileSize: 2000,
        downloadedBytes: 500,
        threadCount: 1,
        chunks: const [0.25],
        category: 'Archive',
        status: DownloadStatus.downloading,
        savePath: 'build',
        localFilePath: 'build/data.iso',
        tempFilePath: 'build/data.dmxpart',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await database.saveTask(task);
      await provider.load();

      // Populate tracking maps
      provider.speedHistories['test-mem-leak'] = Queue<double>()
        ..addAll([100.0, 200.0]);
      provider.lastProgressUpdateTimes['test-mem-leak'] =
          DateTime.now().millisecondsSinceEpoch;

      expect(provider.speedHistories.containsKey('test-mem-leak'), isTrue);
      expect(provider.lastProgressUpdateTimes.containsKey('test-mem-leak'),
          isTrue);

      await provider.deleteTask('test-mem-leak');

      expect(provider.speedHistories.containsKey('test-mem-leak'), isFalse);
      expect(provider.lastProgressUpdateTimes.containsKey('test-mem-leak'),
          isFalse);

      provider.dispose();
      database.dispose();
    });

    test('P1-10: PositionalFileWriter write and drain signal works properly',
        () async {
      final path =
          'build/test_writer_${DateTime.now().millisecondsSinceEpoch}.dat';
      final writer = await PositionalFileWriter.open(
        path,
        totalSize: 1024,
        threadCount: 1,
        maxPendingBytes: 512,
      );

      final data = Uint8List(256);
      for (int i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }

      await writer.write(0, 0, data);
      await writer.flushAll();

      final readBack = await writer.readRange(0, 256);
      expect(readBack, equals(data));

      await writer.close();
    });
  });
}
