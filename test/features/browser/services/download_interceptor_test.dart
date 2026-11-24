import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:dmx/features/browser/services/download_interceptor.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_services.dart';
import '../../../helpers/test_helpers.dart';

class _MockDownloadProvider extends Mock implements DownloadProvider {}

void _stubAddDownload(_MockDownloadProvider provider, {String? id}) {
  when(() => provider.addDownload(
        url: any(named: 'url'),
        name: any(named: 'name'),
        category: any(named: 'category'),
        size: any(named: 'size'),
        savePath: any(named: 'savePath'),
        downloadPageUrl: any(named: 'downloadPageUrl'),
        mergedAudioUrl: any(named: 'mergedAudioUrl'),
        audioSize: any(named: 'audioSize'),
      )).thenAnswer((_) async => id ?? 'new-id');
}

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

    test('startDirectDownload succeeds when resolveActiveTab returns null',
        () async {
      final mockProvider = _MockDownloadProvider();
      when(() => mockProvider.tasks).thenReturn([]);
      when(() => mockProvider.lastError).thenReturn(null);
      _stubAddDownload(mockProvider);

      final interceptorWithoutTab = DownloadInterceptor(
        resolveDownloadProvider: () => mockProvider,
        resolveActiveTab: () => null,
      );

      final res = await interceptorWithoutTab.startDirectDownload(
        'https://example.com/direct_file.zip',
        suggestedName: 'direct_file.zip',
      );
      expect(res.status, equals(InterceptDownloadStatus.queued));
      interceptorWithoutTab.dispose();
    });
  });

  group('ContentCheckResult Tests', () {
    test('isBinaryDownload respects inconclusive and content types', () {
      expect(
        const ContentCheckResult(
          finalUrl: 'u',
          contentType: 'application/zip',
          contentDisposition: '',
          isInconclusive: true,
        ).isBinaryDownload,
        isFalse,
      );
      expect(
        const ContentCheckResult(
          finalUrl: 'u',
          contentType: '',
          contentDisposition: 'attachment; filename=x',
        ).isBinaryDownload,
        isTrue,
      );
      expect(
        const ContentCheckResult(
          finalUrl: 'u',
          contentType: '',
          contentDisposition: '',
        ).isBinaryDownload,
        isFalse,
      );
      expect(
        const ContentCheckResult(
          finalUrl: 'u',
          contentType: 'text/html',
          contentDisposition: '',
        ).isBinaryDownload,
        isFalse,
      );
      expect(
        const ContentCheckResult(
          finalUrl: 'u',
          contentType: 'text/plain',
          contentDisposition: '',
        ).isBinaryDownload,
        isFalse,
      );
      expect(
        const ContentCheckResult(
          finalUrl: 'u',
          contentType: 'application/octet-stream',
          contentDisposition: '',
        ).isBinaryDownload,
        isTrue,
      );
      expect(
        const ContentCheckResult(
          finalUrl: 'u',
          contentType: 'video/mp4',
          contentDisposition: '',
        ).isBinaryDownload,
        isTrue,
      );
      expect(
        const ContentCheckResult(
          finalUrl: 'u',
          contentType: 'audio/mpeg',
          contentDisposition: '',
        ).isBinaryDownload,
        isTrue,
      );
      expect(
        const ContentCheckResult(
          finalUrl: 'u',
          contentType: 'image/png',
          contentDisposition: '',
        ).isBinaryDownload,
        isTrue,
      );
      expect(
        const ContentCheckResult(
          finalUrl: 'u',
          contentType: 'font/woff',
          contentDisposition: '',
        ).isBinaryDownload,
        isFalse,
      );
    });
  });

  group('DownloadInterceptor bypass and history tests', () {
    late DownloadInterceptor local;

    setUp(() {
      local = DownloadInterceptor(
        resolveDownloadProvider: () => throw UnimplementedError(),
        resolveActiveTab: () => null,
      );
    });

    tearDown(() => local.dispose());

    test('consumeBypass handles malformed urls', () {
      local.addBypass('http://[');
      expect(local.consumeBypass('http://['), isTrue);
      expect(local.consumeBypass('http://['), isFalse);
    });

    test('bypass set is capped and evicts the oldest entries', () {
      for (var i = 0; i < 205; i++) {
        local.addBypass('https://example.com/p$i');
      }
      expect(local.consumeBypass('https://example.com/p0'), isFalse);
      expect(local.consumeBypass('https://example.com/p204'), isTrue);
    });

    test('recordIntercepted caps history at 100 entries', () {
      for (var i = 0; i < 105; i++) {
        local.recordIntercepted('https://a.com/$i', 'f$i');
      }
      expect(local.interceptedCount, 100);
      expect(local.interceptedList.first['url'], 'https://a.com/5');
    });

    test('verifyContentType returns inconclusive for unusable urls', () async {
      final result = await local.verifyContentType(
        'not a valid url',
        referer: 'https://example.com/page',
      );
      expect(result.isInconclusive, isTrue);
      expect(result.contentType, isEmpty);
    });

    test('content disposition parsing tolerates malformed encodings', () {
      final name = local.parseFilenameFromContentDispositionString(
          "attachment; filename*=UTF-8''%ZZbad");
      expect(name, isNotNull);
      expect(
        local.parseFilenameFromContentDispositionString('attachment'),
        isNull,
      );
    });
  });

  group('startDirectDownload with mocked provider', () {
    late _MockDownloadProvider provider;
    late DownloadInterceptor mockInterceptor;

    DownloadInterceptor build({
      BrowserTab? Function()? activeTab,
    }) =>
        DownloadInterceptor(
          resolveDownloadProvider: () => provider,
          resolveActiveTab: activeTab ?? () => null,
        );

    setUp(() {
      provider = _MockDownloadProvider();
      when(() => provider.tasks).thenReturn([]);
      when(() => provider.lastError).thenReturn(null);
      when(() => provider.resumeTask(any())).thenAnswer((_) async {});
      _stubAddDownload(provider);
      mockInterceptor = build();
    });

    tearDown(() => mockInterceptor.dispose());

    test('returns alreadyInProgress for downloading and queued tasks',
        () async {
      when(() => provider.tasks).thenReturn([
        createTestTask(
          id: 'dl',
          url: 'https://a.com/f.zip',
          status: DownloadStatus.downloading,
        ),
      ]);
      expect(
        (await mockInterceptor.startDirectDownload('https://a.com/f.zip'))
            .status,
        InterceptDownloadStatus.alreadyInProgress,
      );

      when(() => provider.tasks).thenReturn([
        createTestTask(
          id: 'q',
          url: 'https://a.com/f.zip',
          status: DownloadStatus.queued,
        ),
      ]);
      expect(
        (await mockInterceptor.startDirectDownload('https://a.com/f.zip'))
            .status,
        InterceptDownloadStatus.alreadyInProgress,
      );
    });

    test('resumes paused or failed tasks', () async {
      when(() => provider.tasks).thenReturn([
        createTestTask(
          id: 'p',
          url: 'https://a.com/f.zip',
          status: DownloadStatus.paused,
        ),
      ]);
      final res =
          await mockInterceptor.startDirectDownload('https://a.com/f.zip');
      expect(res.status, InterceptDownloadStatus.resumed);
      verify(() => provider.resumeTask('p')).called(1);
    });

    test('returns failed when the provider reports lastError', () async {
      when(() => provider.lastError).thenReturn('boom');
      final res = await mockInterceptor.startDirectDownload(
        'https://a.com/f.zip',
        suggestedName: 'f.zip',
      );
      expect(res.status, InterceptDownloadStatus.failed);
      expect(res.errorMessage, 'boom');
    });

    test('returns failed when resolveActiveTab throws', () async {
      final throwing = build(activeTab: () => throw Exception('tab boom'));
      addTearDown(throwing.dispose);
      final res = await throwing.startDirectDownload(
        'https://a.com/f.zip',
        suggestedName: 'f.zip',
      );
      expect(res.status, InterceptDownloadStatus.failed);
      expect(res.errorMessage, contains('tab boom'));
    });

    test('derives names from content disposition and magnet links', () async {
      final r1 = await mockInterceptor.startDirectDownload(
        'https://a.com/download',
        contentDisposition: 'attachment; filename="x.zip"',
      );
      expect(r1.status, InterceptDownloadStatus.queued);

      final r2 = await mockInterceptor.startDirectDownload(
        'magnet:?xt=urn:btih:abc&dn=My%20File',
      );
      expect(r2.status, InterceptDownloadStatus.queued);
    });

    test('debounces duplicate interceptions for the same url', () {
      fakeAsync((async) {
        InterceptDownloadResult? second;
        mockInterceptor.startDirectDownload('https://a.com/dup.zip');
        mockInterceptor
            .startDirectDownload('https://a.com/dup.zip')
            .then((r) => second = r);
        async.flushMicrotasks();
        expect(second!.status, InterceptDownloadStatus.alreadyInProgress);
        async.elapse(const Duration(seconds: 3));
      });
    });

    test('resolves categories from type and mime type', () async {
      await mockInterceptor.startDirectDownload('https://a.com/v.mp4',
          suggestedName: 'v.mp4', type: 'video');
      verify(() => provider.addDownload(
            url: 'https://a.com/v.mp4',
            name: 'v.mp4',
            category: 'Video',
            size: any(named: 'size'),
            savePath: any(named: 'savePath'),
            downloadPageUrl: any(named: 'downloadPageUrl'),
            mergedAudioUrl: any(named: 'mergedAudioUrl'),
            audioSize: any(named: 'audioSize'),
          )).called(1);

      await mockInterceptor.startDirectDownload('https://a.com/a.mp3',
          suggestedName: 'a.mp3', mimeType: 'audio/mpeg');
      verify(() => provider.addDownload(
            url: 'https://a.com/a.mp3',
            name: 'a.mp3',
            category: 'Audio',
            size: any(named: 'size'),
            savePath: any(named: 'savePath'),
            downloadPageUrl: any(named: 'downloadPageUrl'),
            mergedAudioUrl: any(named: 'mergedAudioUrl'),
            audioSize: any(named: 'audioSize'),
          )).called(1);

      await mockInterceptor.startDirectDownload('https://a.com/i.png',
          suggestedName: 'i.png', type: 'image');
      verify(() => provider.addDownload(
            url: 'https://a.com/i.png',
            name: 'i.png',
            category: 'Image',
            size: any(named: 'size'),
            savePath: any(named: 'savePath'),
            downloadPageUrl: any(named: 'downloadPageUrl'),
            mergedAudioUrl: any(named: 'mergedAudioUrl'),
            audioSize: any(named: 'audioSize'),
          )).called(1);
    });

    test('numbers duplicate file names to avoid collisions', () async {
      when(() => provider.tasks).thenReturn([
        createTestTask(
          id: 'existing',
          url: 'https://other.com/file.zip',
          fileName: 'dup.zip',
        ),
      ]);
      await mockInterceptor.startDirectDownload('https://a.com/other',
          suggestedName: 'dup.zip');
      verify(() => provider.addDownload(
            url: any(named: 'url'),
            name: 'dup_1.zip',
            category: any(named: 'category'),
            size: any(named: 'size'),
            savePath: any(named: 'savePath'),
            downloadPageUrl: any(named: 'downloadPageUrl'),
            mergedAudioUrl: any(named: 'mergedAudioUrl'),
            audioSize: any(named: 'audioSize'),
          )).called(1);
    });

    test('resolves categories from content-type hints', () async {
      Future<void> run(String mime, String expected) async {
        await mockInterceptor.startDirectDownload(
          'https://a.com/file?m=$mime',
          suggestedName: 'file-$expected',
          mimeType: mime,
        );
        verify(() => provider.addDownload(
              url: any(named: 'url'),
              name: 'file-$expected',
              category: expected,
              size: any(named: 'size'),
              savePath: any(named: 'savePath'),
              downloadPageUrl: any(named: 'downloadPageUrl'),
              mergedAudioUrl: any(named: 'mergedAudioUrl'),
              audioSize: any(named: 'audioSize'),
            )).called(1);
      }

      await run('application/pdf', 'Document');
      await run('application/zip', 'Archive');
      await run('application/x-bittorrent', 'Torrent');

      // Unknown content type falls back to smart category resolution.
      final res = await mockInterceptor.startDirectDownload(
        'https://a.com/file.bin',
        suggestedName: 'file.bin',
        mimeType: 'application/octet-stream',
      );
      expect(res.status, InterceptDownloadStatus.queued);
    });

    test('uses the active tab url as the download page url', () async {
      final tab = BrowserTab(
        id: 'ref',
        url: 'https://ref.example.com/page',
        title: 'Ref',
      );
      final interceptorWithTab = build(activeTab: () => tab);
      addTearDown(interceptorWithTab.dispose);
      await interceptorWithTab.startDirectDownload('https://a.com/f.zip',
          suggestedName: 'f.zip');
      verify(() => provider.addDownload(
            url: any(named: 'url'),
            name: 'f.zip',
            category: any(named: 'category'),
            size: any(named: 'size'),
            savePath: any(named: 'savePath'),
            downloadPageUrl: 'https://ref.example.com/page',
            mergedAudioUrl: any(named: 'mergedAudioUrl'),
            audioSize: any(named: 'audioSize'),
          )).called(1);
    });

    test('interceptBatch and queueDownload delegate to the provider', () async {
      when(() => provider.addDownloadsBatch(any())).thenAnswer((_) async => []);
      await mockInterceptor.interceptBatch(['https://a.com/x.zip']);
      verify(() => provider.addDownloadsBatch(any())).called(1);

      await mockInterceptor.queueDownload('https://a.com/y.zip', name: 'y.zip');
      await mockInterceptor.queueDownload('https://a.com/z.zip');
    });
  });
}
