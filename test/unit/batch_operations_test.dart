import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class MockDatabaseService extends DatabaseService {
  MockDatabaseService() : super.forSubclass();
  final Map<String, DownloadTask> tasksMap = {};

  @override
  Future<void> saveTask(DownloadTask task) async {
    tasksMap[task.id] = task;
  }

  @override
  Future<void> saveTasks(Iterable<DownloadTask> tasks) async {
    for (final t in tasks) {
      tasksMap[t.id] = t;
    }
  }

  Future<List<DownloadTask>> loadAllTasks() async {
    return tasksMap.values.toList();
  }

  @override
  Future<List<DownloadTask>> loadTasks() async {
    return tasksMap.values.toList();
  }

  @override
  Future<void> deleteTask(String id) async {
    tasksMap.remove(id);
  }
}

DownloadTask _makeTask(String id) {
  return DownloadTask(
    id: id,
    fileName: 'file-$id.mp4',
    url: 'https://example.com/$id',
    fileSize: 100,
    downloadedBytes: 10,
    category: 'Video',
    status: DownloadStatus.downloading,
    savePath: '/downloads',
    localFilePath: '/downloads/$id.mp4',
    tempFilePath: '/downloads/$id.mp4.tmp',
    threadCount: 1,
    chunks: [0.1],
    createdAt: DateTime(2024, 1, 1),
    updatedAt: DateTime(2024, 1, 1),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ConnectivityPlatform.instance = MockConnectivityPlatform();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (methodCall) async => null,
  );

  late MockDatabaseService db;
  late SettingsProvider settings;
  late DownloadProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = MockDatabaseService();
    settings = SettingsProvider();
    await settings.load();
    settings.autoStart = false;
    provider = DownloadProvider(
      databaseService: db,
      settingsProvider: settings,
    );
  });

  test('batch operations correctly mutate tasks', () async {
    final t1 = _makeTask('task-1');
    final t2 = _makeTask('task-2');

    await db.saveTasks([t1, t2]);
    await provider.load();

    expect(provider.tasks, hasLength(2));

    // Test changeCategoryForMultipleTasks
    await provider.changeCategoryForMultipleTasks([
      'task-1',
      'task-2',
    ], 'Documents');
    expect(
      provider.tasks.firstWhere((t) => t.id == 'task-1').category,
      equals('Documents'),
    );
    expect(
      provider.tasks.firstWhere((t) => t.id == 'task-2').category,
      equals('Documents'),
    );

    // Test pauseMultipleTasks
    await provider.pauseMultipleTasks(['task-1', 'task-2']);
    expect(
      provider.tasks.firstWhere((t) => t.id == 'task-1').status,
      equals(DownloadStatus.paused),
    );
    expect(
      provider.tasks.firstWhere((t) => t.id == 'task-2').status,
      equals(DownloadStatus.paused),
    );

    // Test deleteMultipleTasks
    await provider.deleteMultipleTasks(['task-1']);
    expect(provider.tasks.any((t) => t.id == 'task-1'), isFalse);
    expect(provider.tasks.any((t) => t.id == 'task-2'), isTrue);
  });
}
