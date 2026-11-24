import 'dart:convert';

import 'package:dmx/features/browser/services/html_sanitizer.dart';
import 'package:dmx/features/browser/services/reader_extractor.dart';
import 'package:dmx/features/browser/services/reader_html_builder.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeReaderController implements InAppWebViewController {
  dynamic jsResult;
  Object? error;

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (error != null) throw error!;
    return jsResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('HtmlSanitizer Tests', () {
    test('removes dangerous tag blocks and self-closing tags', () {
      const html =
          '<div>ok</div><script>alert(1)</script><iframe src="x"></iframe>'
          '<link rel="stylesheet"><meta charset="utf-8">';
      final out = HtmlSanitizer.sanitize(html);
      expect(out, contains('<div>ok</div>'));
      expect(out, isNot(contains('script')));
      expect(out, isNot(contains('iframe')));
      expect(out, isNot(contains('<link')));
      expect(out, isNot(contains('<meta')));
    });

    test('strips inline event handlers and style attributes', () {
      final out = HtmlSanitizer.sanitize(
          '<div onclick="evil()" style="color:red">hi</div>');
      expect(out, isNot(contains('onclick')));
      expect(out, isNot(contains('style=')));
      expect(out, contains('hi'));
    });

    test('neutralizes javascript/data links and img onerror', () {
      expect(HtmlSanitizer.sanitize('<a href="javascript:alert(1)">x</a>'),
          isNot(contains('javascript:')));
      expect(HtmlSanitizer.sanitize('<a href="vbscript:x">x</a>'),
          isNot(contains('vbscript:')));
      expect(HtmlSanitizer.sanitize('<a href="data:text/html,x">x</a>'),
          isNot(contains('data:text/html')));
      expect(HtmlSanitizer.sanitize('<img src="javascript:evil()">'),
          isNot(contains('javascript:')));
      expect(HtmlSanitizer.sanitize('<img src="x" onerror="evil()">'),
          isNot(contains('onerror')));
    });

    test('decodes numeric entities before matching', () {
      // &#106;avascript: -> javascript:
      final out = HtmlSanitizer.sanitize('<a href="&#106;avascript:x">y</a>');
      expect(out, isNot(contains('javascript')));
      final hex = HtmlSanitizer.sanitize('<a href="&#x6a;avascript:x">y</a>');
      expect(hex, isNot(contains('javascript')));
    });

    test('keeps out-of-range numeric entities unchanged', () {
      expect(HtmlSanitizer.sanitize('&#0;'), '&#0;');
      expect(HtmlSanitizer.sanitize('&#x110000;'), '&#x110000;');
    });

    test('returns empty string for empty input', () {
      expect(HtmlSanitizer.sanitize(''), '');
    });

    test('escapeHtml escapes reserved characters', () {
      expect(HtmlSanitizer.escapeHtml('<a href="x">&\'</a>'),
          '&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;');
    });

    test('sanitizeAsync handles small and large payloads', () async {
      final small = await HtmlSanitizer.sanitizeAsync('<script>x</script>hi');
      expect(small, 'hi');

      final large = '<p>${'a' * 3000}</p><script>bad()</script>';
      final out = await HtmlSanitizer.sanitizeAsync(large);
      expect(out, isNot(contains('<script>')));
      expect(out, contains('aaa'));
    });
  });

  group('ReaderHtmlBuilder Tests', () {
    const article = ReaderArticle(
      title: 'Hello <World>',
      content: '<p>Body</p>',
      url: 'https://example.com/post',
      domain: 'example.com',
      readingTime: 3,
    );

    test('builds light theme with default sans font', () {
      final html = ReaderHtmlBuilder.build(
        article: article,
        fontSize: 18,
        theme: 'light',
        fontFamily: 'sans',
      );
      expect(html, contains('#ffffff'));
      expect(html, contains('font-size: 18.0px'));
      expect(html, contains("'Inter', sans-serif"));
      expect(html, contains('3 min read'));
      expect(html, contains('Hello &lt;World&gt;'));
      expect(html, contains('<p>Body</p>'));
    });

    test('builds dark and sepia themes with serif font', () {
      final dark = ReaderHtmlBuilder.build(
        article: article,
        fontSize: 20,
        theme: 'dark',
        fontFamily: 'serif',
      );
      expect(dark, contains('#1a1a2e'));
      expect(dark, contains("'Georgia', serif"));

      final sepia = ReaderHtmlBuilder.build(
        article: article,
        fontSize: 16,
        theme: 'sepia',
        fontFamily: 'serif',
      );
      expect(sepia, contains('#f4ecd8'));
    });

    test('uses provided sanitized content and omits reading time when zero',
        () {
      const noRead = ReaderArticle(
        title: 'T',
        content: '<script>bad</script>',
        url: 'https://a.com',
        domain: 'a.com',
      );
      final html = ReaderHtmlBuilder.build(
        article: noRead,
        fontSize: 14,
        theme: 'light',
        fontFamily: 'sans',
        sanitizedContent: '<p>Clean</p>',
      );
      expect(html, contains('<p>Clean</p>'));
      expect(html, isNot(contains('min read')));
    });
  });

  group('ReaderExtractor Tests', () {
    test('parses a valid extraction result', () async {
      final controller = _FakeReaderController()
        ..jsResult = jsonEncode({
          'title': 'Title',
          'content': '<p>Body</p>',
          'url': 'https://example.com/a',
          'domain': 'example.com',
          'author': 'Author',
          'publishedDate': '2020-01-01',
          'textContent': 'Body',
          'images': [
            {'src': 'https://example.com/i.png', 'alt': 'Alt'},
            {'src': null, 'alt': null},
          ],
          'wordCount': 100,
          'readingTime': 1,
        });

      final article = await ReaderExtractor.extract(controller);
      expect(article, isNotNull);
      expect(article!.title, 'Title');
      expect(article.images.length, 2);
      expect(article.images.first['src'], 'https://example.com/i.png');
      expect(article.images[1]['src'], '');
      expect(article.wordCount, 100);
      expect(article.readingTime, 1);
    });

    test('returns null for "null", null and invalid payloads', () async {
      final nullString = _FakeReaderController()..jsResult = 'null';
      expect(await ReaderExtractor.extract(nullString), isNull);

      final nullResult = _FakeReaderController()..jsResult = null;
      expect(await ReaderExtractor.extract(nullResult), isNull);

      final invalid = _FakeReaderController()..jsResult = 'not json';
      expect(await ReaderExtractor.extract(invalid), isNull);
    });

    test('returns null when the controller throws', () async {
      final controller = _FakeReaderController()..error = Exception('boom');
      expect(await ReaderExtractor.extract(controller), isNull);
    });

    test('applies defaults for missing fields', () async {
      final controller = _FakeReaderController()..jsResult = '{}';
      final article = await ReaderExtractor.extract(controller);
      expect(article, isNotNull);
      expect(article!.title, 'Untitled');
      expect(article.content, '');
      expect(article.images, isEmpty);
      expect(article.wordCount, 0);
      expect(article.readingTime, 0);
    });

    test('copyWith overrides only provided fields', () {
      const original = ReaderArticle(
        title: 'A',
        content: 'B',
        url: 'https://a.com',
        domain: 'a.com',
        wordCount: 5,
      );
      final copy = original.copyWith(title: 'C', readingTime: 2);
      expect(copy.title, 'C');
      expect(copy.content, 'B');
      expect(copy.wordCount, 5);
      expect(copy.readingTime, 2);

      final copy2 = original.copyWith(content: 'B2', wordCount: 7);
      expect(copy2.title, 'A');
      expect(copy2.content, 'B2');
      expect(copy2.wordCount, 7);
      expect(copy2.readingTime, 0);
    });
  });
}
