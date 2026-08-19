import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:dmx/features/browser/services/download_interceptor.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_services.dart';
import '../../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;
  late FakeDatabaseService database;
  late DownloadProvider downloadProvider;
  late DownloadInterceptor interceptor;
  BrowserTab? activeTab;

  setUp(() {
    setupTestPluginMocks();
    SharedPreferences.setMockInitialValues({});
    settings = SettingsProvider();
    database = FakeDatabaseService();

    downloadProvider = DownloadProvider(
      databaseService: database,
      settingsProvider: settings,
      enableBackgroundTimers: false,
    );

    activeTab = BrowserTab(
      id: 'tab-1',
      url: 'https://example.com/page',
      title: 'Example Page',
    );

    interceptor = DownloadInterceptor(
      resolveDownloadProvider: () => downloadProvider,
      resolveActiveTab: () => activeTab,
    );
  });

  tearDown(() {
    interceptor.dispose();
  });

  group('DownloadInterceptor Tests', () {
    test('addBypass and consumeBypass correctly mark and clear bypass keys',
        () {
      const url = 'https://example.com/download.zip?token=123';
      interceptor.addBypass(url);

      expect(interceptor.consumeBypass(url), isTrue);
      expect(interceptor.consumeBypass(url), isFalse);
    });

    test('shouldIntercept ignores youtube hosts and detects binary files', () {
      expect(
        interceptor.shouldIntercept(
          tabUrl: 'https://youtube.com/watch?v=123',
          requestUrl: 'https://example.com/file.mp4',
        ),
        isFalse,
      );

      expect(
        interceptor.shouldIntercept(
          tabUrl: 'https://example.com/page',
          requestUrl: 'https://example.com/archive.zip',
        ),
        isTrue,
      );
    });

    test('parseFilenameFromContentDispositionString extracts valid filenames',
        () {
      expect(
        interceptor.parseFilenameFromContentDispositionString(
            'attachment; filename="document.pdf"'),
        equals('document.pdf'),
      );

      expect(
        interceptor.parseFilenameFromContentDispositionString(
            "attachment; filename*=UTF-8''my%20archive.zip"),
        equals('my archive.zip'),
      );

      expect(
        interceptor.parseFilenameFromContentDispositionString(''),
        isNull,
      );
    });

    test('recordIntercepted records and clears history correctly', () {
      interceptor.recordIntercepted('https://example.com/file.zip', 'file.zip');
      expect(interceptor.interceptedList.length, equals(1));
      expect(interceptor.interceptedList.first['fileName'], equals('file.zip'));

      interceptor.clearIntercepted();
      expect(interceptor.interceptedList.isEmpty, isTrue);
    });

    test('startDirectDownload returns alreadyCompleted when task is completed',
        () async {
      final now = DateTime.now();
      final task = DownloadTask(
        id: 'task-1',
        fileName: 'test.zip',
        url: 'https://example.com/test.zip',
        fileSize: 1024,
        downloadedBytes: 1024,
        speed: 0,
        category: 'Archive',
        status: DownloadStatus.completed,
        savePath: '/downloads/test.zip',
        localFilePath: '/downloads/test.zip',
        tempFilePath: '/downloads/test.zip.dmxpart',
        threadCount: 4,
        chunks: const [1.0],
        createdAt: now,
        updatedAt: now,
      );

      await database.saveTask(task);
      await downloadProvider.load();

      final res =
          await interceptor.startDirectDownload('https://example.com/test.zip');
      expect(res.status, equals(InterceptDownloadStatus.alreadyCompleted));
    });
  });
}
