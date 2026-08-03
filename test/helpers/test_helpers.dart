import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'fake_services.dart';

/// Wraps a widget with required providers for testing.
Widget createTestApp({
  required Widget child,
  DownloadProvider? downloadProvider,
  SettingsProvider? settingsProvider,
  DatabaseService? databaseService,
  ThemeData? theme,
  Locale? locale,
}) {
  WebViewPlatform.instance = FakeWebViewPlatform();

  final db = databaseService ?? FakeDatabaseService();
  final provider = downloadProvider ?? createMockDownloadProvider(db: db);
  addTearDown(() {
    try {
      provider.dispose();
    } catch (_) {}
  });

  return MultiProvider(
    providers: [
      Provider<DatabaseService>.value(
        value: db,
      ),
      ChangeNotifierProvider<DownloadProvider>.value(
        value: provider,
      ),
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settingsProvider ?? createMockSettingsProvider(),
      ),
    ],
    child: MaterialApp(
      theme: theme ?? ThemeData.dark(),
      locale: locale,
      home: Scaffold(body: child),
    ),
  );
}

/// Creates a DownloadProvider with fake services.
DownloadProvider createMockDownloadProvider({
  DatabaseService? db,
  List<DownloadTask>? tasks,
}) {
  final settings = createMockSettingsProvider();
  final database = db ?? FakeDatabaseService(initialTasks: tasks);
  final provider = DownloadProvider(
    databaseService: database,
    settingsProvider: settings,
    downloadEngine: FakeDownloadEngine(),
    permissionService: FakePermissionService(),
    enableBackgroundTimers: false,
  );
  return provider;
}

/// Creates a SettingsProvider with test defaults.
SettingsProvider createMockSettingsProvider() {
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
  final instance = SettingsProvider.instance;
  instance.load();
  return instance;
}

/// Creates a sample DownloadTask for testing.
DownloadTask createTestTask({
  String id = 'test-task-1',
  String fileName = 'test-file.zip',
  String? url,
  DownloadStatus status = DownloadStatus.downloading,
  double progress = 0.45,
  int fileSize = 104857600, // 100 MB
  int downloadedBytes = 47185920, // ~45 MB
  double speed = 5242880.0, // 5 MB/s
  int eta = 11,
  int threadCount = 8,
  List<double>? chunks,
  bool isTorrent = false,
  String category = 'Compressed',
  List<Map<String, dynamic>>? torrentFiles,
  String? errorMessage,
  DateTime? createdAt,
}) {
  final effectiveUrl = url ??
      (isTorrent
          ? 'magnet:?xt=urn:btih:test'
          : 'https://example.com/test-file.zip');

  return DownloadTask(
    id: id,
    fileName: fileName,
    url: effectiveUrl,
    status: status,
    fileSize: fileSize,
    downloadedBytes: (fileSize * progress).round(),
    speed: speed,
    eta: eta,
    threadCount: threadCount,
    chunks: chunks ?? List.filled(threadCount, progress),
    category: category,
    savePath: '/storage/emulated/0/Download',
    localFilePath: '/storage/emulated/0/Download/$fileName',
    tempFilePath: '/storage/emulated/0/Download/$fileName.dmxpart',
    torrentFiles: torrentFiles,
    errorMessage: errorMessage,
    createdAt: createdAt ?? DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

/// Creates a list of mixed-status tasks for testing.
List<DownloadTask> createMixedTaskList() {
  return [
    createTestTask(
        id: 'dl-1',
        fileName: 'ubuntu.iso',
        status: DownloadStatus.downloading,
        progress: 0.65),
    createTestTask(
        id: 'dl-2',
        fileName: 'movie.mp4',
        status: DownloadStatus.downloading,
        progress: 0.30),
    createTestTask(
        id: 'dl-3',
        fileName: 'song.mp3',
        status: DownloadStatus.paused,
        progress: 0.50),
    createTestTask(
        id: 'dl-4',
        fileName: 'doc.pdf',
        status: DownloadStatus.completed,
        progress: 1.0),
    createTestTask(
        id: 'dl-5',
        fileName: 'archive.rar',
        status: DownloadStatus.queued,
        progress: 0.0),
    createTestTask(
        id: 'dl-6',
        fileName: 'image.png',
        status: DownloadStatus.failed,
        progress: 0.15,
        errorMessage: 'Timeout'),
    createTestTask(
        id: 'dl-7',
        fileName: 'game.torrent',
        status: DownloadStatus.downloading,
        progress: 0.80,
        isTorrent: true),
  ];
}
