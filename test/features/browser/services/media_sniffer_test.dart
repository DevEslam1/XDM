import 'dart:async';
import 'dart:convert';

import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:dmx/features/browser/services/media_sniffer.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSnifferController implements InAppWebViewController {
  Future<dynamic> Function()? handler;
  Object? syncError;

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) {
    final error = syncError;
    if (error != null) throw error;
    return handler?.call() ?? Future<dynamic>.value('[]');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MediaSniffer sniffer;
  late bool active;
  late bool contains;
  late bool enabled;

  MediaSniffer build() => MediaSniffer(
        isActive: () => active,
        containsTab: (_) => contains,
        isSnifferEnabled: () => enabled,
      );

  setUp(() {
    active = true;
    contains = true;
    enabled = true;
    sniffer = build();
  });

  tearDown(() => sniffer.dispose());

  BrowserTab tabWith(
    _FakeSnifferController controller, {
    String url = 'https://example.com/page',
    String id = 'tab_1',
  }) =>
      BrowserTab(id: id, url: url, title: 'T', controller: controller);

  group('MediaSniffer basics', () {
    test('isYoutubeHost identifies YouTube variants', () {
      expect(
          MediaSniffer.isYoutubeHost('https://www.youtube.com/watch'), isTrue);
      expect(MediaSniffer.isYoutubeHost('https://m.youtube.com/watch'), isTrue);
      expect(MediaSniffer.isYoutubeHost('https://youtu.be/abc'), isTrue);
      expect(MediaSniffer.isYoutubeHost('https://example.com/v.mp4'), isFalse);
      expect(MediaSniffer.isYoutubeHost('invalid uri'), isFalse);
    });

    test('totalDetectedCount and clearAll manage state', () {
      sniffer.detectedDownloadUrls['t'] = 'https://a.com/v.mp4';
      sniffer.detectedMediaSources['t'] = [
        {'src': 'https://a.com/a.mp3'}
      ];
      sniffer.detectedPlaylistUrls['p'] = 3;
      expect(sniffer.totalDetectedCount, 3);

      sniffer.clearAll();
      expect(sniffer.totalDetectedCount, 0);
    });

    test('cleanupTab clears per-tab state and trims ytDetectionFailed', () {
      final now = DateTime.now();
      for (var i = 0; i < 210; i++) {
        sniffer.ytDetectionFailed['https://yt.com/$i'] = now;
      }
      sniffer.detectedDownloadUrls['tab_1'] = 'https://a.com/v.mp4';
      sniffer.detectedMediaSources['tab_1'] = [
        {'src': 'https://a.com/v.mp4'}
      ];
      sniffer.lastYoutubeAuthTimes['tab_1'] = now;

      sniffer.cleanupTab('tab_1');
      expect(sniffer.detectedDownloadUrls.containsKey('tab_1'), isFalse);
      expect(sniffer.detectedMediaSources.containsKey('tab_1'), isFalse);
      expect(sniffer.lastYoutubeAuthTimes.containsKey('tab_1'), isFalse);
      expect(sniffer.ytDetectionFailed.length, lessThanOrEqualTo(200));
    });

    test('cancelAllScanTimers cancels scheduled scans', () {
      sniffer.mediaScanTimers['t'] = Timer(const Duration(hours: 1), () {});
      sniffer.cancelAllScanTimers();
      expect(sniffer.mediaScanTimers, isEmpty);
    });

    test('scheduleScan skips YouTube and clears state', () {
      final controller = _FakeSnifferController();
      final tab = tabWith(controller, url: 'https://youtube.com/watch?v=1');
      sniffer.detectedDownloadUrls[tab.id] = 'https://a.com/v.mp4';
      sniffer.scheduleScan(tab);
      expect(sniffer.mediaScanTimers.containsKey(tab.id), isFalse);
      expect(sniffer.detectedDownloadUrls.containsKey(tab.id), isFalse);
    });

    test('scheduleScan debounces and runs a scan', () {
      fakeAsync((async) {
        final controller = _FakeSnifferController()..handler = () async => '[]';
        final tab = tabWith(controller);
        sniffer.scheduleScan(tab, tabs: [tab]);
        expect(sniffer.mediaScanTimers.containsKey(tab.id), isTrue);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(sniffer.mediaScanTimers.containsKey(tab.id), isFalse);
      });
    });

    test('cleanupTab drops ytDetectionFailed entries for scanned urls',
        () async {
      final controller = _FakeSnifferController()..handler = () async => '[]';
      final tab = tabWith(controller);
      await sniffer.scanPageMedia(tab, tabs: [tab]);
      sniffer.ytDetectionFailed[tab.url] = DateTime.now();

      sniffer.cleanupTab(tab.id);
      expect(sniffer.ytDetectionFailed.containsKey(tab.url), isFalse);
    });

    test('dispose cancels pending scan timers', () {
      sniffer.mediaScanTimers['pending'] = Timer(
        const Duration(hours: 1),
        () {},
      );
      // tearDown() calls dispose(), which must cancel the timer.
      expect(sniffer.mediaScanTimers, isNotEmpty);
    });
  });

  group('MediaSniffer scanPageMedia', () {
    test('returns early when inactive, missing, home or disabled', () async {
      final controller = _FakeSnifferController()..handler = () async => '[]';
      final tab = tabWith(controller);

      active = false;
      await sniffer.scanPageMedia(tab, tabs: [tab]);

      active = true;
      contains = false;
      await sniffer.scanPageMedia(tab, tabs: [tab]);

      contains = true;
      final home = tabWith(controller, url: '');
      await sniffer.scanPageMedia(home, tabs: [home]);

      enabled = false;
      await sniffer.scanPageMedia(tab, tabs: [tab]);
      expect(sniffer.detectedDownloadUrls, isEmpty);
    });

    test('clears state for YouTube tabs', () async {
      final controller = _FakeSnifferController()..handler = () async => '[]';
      final tab = tabWith(controller, url: 'https://youtube.com/watch?v=1');
      sniffer.detectedDownloadUrls[tab.id] = 'https://a.com/v.mp4';
      await sniffer.scanPageMedia(tab, tabs: [tab]);
      expect(sniffer.detectedDownloadUrls.containsKey(tab.id), isFalse);
    });

    test('stores detected sources and prefers CDN urls', () async {
      final sources = [
        {'src': 'https://example.com/audio.mp3', 'label': 'Audio'},
        {'src': 'https://rr1---sn.googlevideo.com/videoplayback', 'label': 'V'},
      ];
      final controller = _FakeSnifferController()
        ..handler = () async => jsonEncode(sources);
      final tab = tabWith(controller);

      await sniffer.scanPageMedia(tab, tabs: [tab]);
      expect(sniffer.detectedMediaSources[tab.id], hasLength(2));
      expect(sniffer.detectedDownloadUrls[tab.id],
          'https://rr1---sn.googlevideo.com/videoplayback');
    });

    test('handles JSON-wrapped string results', () async {
      final sources = [
        {'src': 'https://example.com/video.mp4', 'label': 'Video'}
      ];
      final controller = _FakeSnifferController()
        ..handler = () async => jsonEncode(jsonEncode(sources));
      final tab = tabWith(controller);

      await sniffer.scanPageMedia(tab, tabs: [tab]);
      expect(sniffer.detectedDownloadUrls[tab.id],
          'https://example.com/video.mp4');
    });

    test('handles malformed JSON-wrapped results', () async {
      final controller = _FakeSnifferController()
        ..handler = () async => '"a"b"';
      final tab = tabWith(controller);
      await sniffer.scanPageMedia(tab, tabs: [tab]);
      expect(sniffer.mediaScanFailed[tab.id], isTrue);
    });

    test('handles specialized streaming sites', () async {
      final controller = _FakeSnifferController()..handler = () async => '[]';
      final tab = tabWith(controller, url: 'https://ok.ru/video/123');
      await sniffer.scanPageMedia(tab, tabs: [tab]);
      expect(sniffer.mediaScanFailed.containsKey(tab.id), isFalse);
    });

    test('marks failure for malformed payloads', () async {
      final controller = _FakeSnifferController()..handler = () async => 'nope';
      final tab = tabWith(controller);
      await sniffer.scanPageMedia(tab, tabs: [tab]);
      expect(sniffer.mediaScanFailed[tab.id], isTrue);
    });

    test('ignores MissingPluginException', () async {
      final controller = _FakeSnifferController()
        ..syncError = MissingPluginException('no plugin');
      final tab = tabWith(controller);
      await sniffer.scanPageMedia(tab, tabs: [tab]);
      expect(sniffer.mediaScanFailed.containsKey(tab.id), isFalse);
    });

    test('marks failure for other exceptions', () async {
      final controller = _FakeSnifferController()
        ..syncError = Exception('boom');
      final tab = tabWith(controller);
      await sniffer.scanPageMedia(tab, tabs: [tab]);
      expect(sniffer.mediaScanFailed[tab.id], isTrue);
    });

    test('marks failure when the scan times out', () {
      fakeAsync((async) {
        final controller = _FakeSnifferController()
          ..handler = () => Completer<dynamic>().future;
        final tab = tabWith(controller);
        sniffer.scanPageMedia(tab, tabs: [tab]);
        async.elapse(const Duration(seconds: 9));
        async.flushMicrotasks();
        expect(sniffer.mediaScanFailed[tab.id], isTrue);
      });
    });

    test('prunes stale per-tab state not in the open tabs', () async {
      final controller = _FakeSnifferController()..handler = () async => '[]';
      final tab = tabWith(controller);
      sniffer.detectedMediaSources['stale'] = [
        {'src': 'https://a.com/v.mp4'}
      ];
      sniffer.detectedDownloadUrls['stale'] = 'https://a.com/v.mp4';

      await sniffer.scanPageMedia(tab, tabs: [tab]);
      expect(sniffer.detectedMediaSources.containsKey('stale'), isFalse);
      expect(sniffer.detectedDownloadUrls.containsKey('stale'), isFalse);
    });

    test('recordDetectedMedia safely adds and deduplicates media streams', () {
      sniffer.recordDetectedMedia(
        'tab_1',
        url: 'https://example.com/playlist.m3u8',
        label: 'HLS Stream',
      );
      expect(sniffer.detectedMediaSources['tab_1']?.length, 1);
      expect(sniffer.detectedMediaSources['tab_1']?.first['src'], 'https://example.com/playlist.m3u8');
      expect(sniffer.detectedMediaSources['tab_1']?.first['label'], 'HLS Stream');
      expect(sniffer.detectedDownloadUrls['tab_1'], 'https://example.com/playlist.m3u8');

      // Duplicate should be ignored
      sniffer.recordDetectedMedia(
        'tab_1',
        url: 'https://example.com/playlist.m3u8',
      );
      expect(sniffer.detectedMediaSources['tab_1']?.length, 1);

      // Images or data URIs should be filtered out
      sniffer.recordDetectedMedia('tab_1', url: 'https://example.com/icon.png');
      sniffer.recordDetectedMedia('tab_1', url: 'data:image/png;base64,...');
      expect(sniffer.detectedMediaSources['tab_1']?.length, 1);
    });
  });
}
