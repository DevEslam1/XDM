import 'dart:convert';

import 'package:dmx/features/browser/services/reader_mode_service.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeReaderController implements InAppWebViewController {
  dynamic jsResult;

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async =>
      jsResult;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _articleJson({String content = '<p>Body</p>'}) => jsonEncode({
      'title': 'Title',
      'content': content,
      'url': 'https://example.com/post',
      'domain': 'example.com',
      'wordCount': 10,
      'readingTime': 1,
    });

void main() {
  group('ReaderModeService Tests', () {
    test('sanitizeContent delegates to HtmlSanitizer', () {
      expect(ReaderModeService.sanitizeContent('<script>x</script>hi'), 'hi');
    });

    test('buildReaderHtml delegates to ReaderHtmlBuilder', () {
      const article = ReaderArticle(
        title: 'T',
        content: '<p>c</p>',
        url: 'https://a.com',
        domain: 'a.com',
      );
      final html = ReaderModeService.buildReaderHtml(
        article,
        fontSize: 16,
        theme: 'dark',
        fontFamily: 'serif',
      );
      expect(html, contains('#1a1a2e'));
      expect(html, contains('a.com'));
    });

    test('extract returns an article for a valid controller result', () async {
      final controller = _FakeReaderController()..jsResult = _articleJson();
      final article = await ReaderModeService.extract(controller);
      expect(article, isNotNull);
      expect(article!.title, 'Title');
    });

    test('activateReaderMode returns false when extraction fails', () async {
      final controller = _FakeReaderController()..jsResult = 'null';
      var called = false;
      final ok = await ReaderModeService.activateReaderMode(
        controller,
        (_) => called = true,
        fontSize: 16,
        theme: 'light',
        fontFamily: 'sans',
      );
      expect(ok, isFalse);
      expect(called, isFalse);
    });

    test('activateReaderMode returns false when content is empty', () async {
      final controller = _FakeReaderController()
        ..jsResult = _articleJson(content: '');
      final ok = await ReaderModeService.activateReaderMode(
        controller,
        (_) {},
        fontSize: 16,
        theme: 'light',
        fontFamily: 'sans',
      );
      expect(ok, isFalse);
    });

    test('activateReaderMode loads a data URI on success', () async {
      final controller = _FakeReaderController()..jsResult = _articleJson();
      String? loaded;
      final ok = await ReaderModeService.activateReaderMode(
        controller,
        (url) => loaded = url,
        fontSize: 16,
        theme: 'light',
        fontFamily: 'sans',
      );
      expect(ok, isTrue);
      expect(loaded, isNotNull);
      expect(loaded, startsWith('data:text/html'));
    });

    test('rebuildReaderHtml emits a data URI for the supplied article',
        () async {
      const article = ReaderArticle(
        title: 'T',
        content: '<p>Body</p>',
        url: 'https://a.com',
        domain: 'a.com',
        readingTime: 2,
      );
      String? loaded;
      final ok = await ReaderModeService.rebuildReaderHtml(
        article,
        (url) => loaded = url,
        fontSize: 18,
        theme: 'sepia',
        fontFamily: 'serif',
      );
      expect(ok, isTrue);
      expect(loaded, startsWith('data:text/html'));
    });

    test('rebuildReaderHtml sanitizes large content via isolate', () async {
      final article = ReaderArticle(
        title: 'T',
        content: '<p>${'a' * 3000}</p><script>bad()</script>',
        url: 'https://a.com',
        domain: 'a.com',
      );
      String? loaded;
      await ReaderModeService.rebuildReaderHtml(
        article,
        (url) => loaded = url,
        fontSize: 18,
        theme: 'light',
        fontFamily: 'sans',
      );
      expect(loaded, isNotNull);
    });
  });
}
