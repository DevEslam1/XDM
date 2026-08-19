import 'package:dmx/features/browser/services/long_press_parser.dart';
import 'package:dmx/features/browser/services/reader_mode_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LongPressPayload & ReaderMode Hardening Tests', () {
    test('LongPressPayload parses simple and double-quoted escaped JSON', () {
      const validJson =
          '{"url": "https://example.com/test.zip", "src": "https://example.com/img.png", "type": "link"}';
      final payload1 = LongPressPayload.tryParse(validJson);
      expect(payload1, isNotNull);
      expect(payload1?.url, 'https://example.com/test.zip');
      expect(payload1?.type, 'link');

      const quotedJson =
          '"{\\"url\\": \\"https://example.com/escaped.mp4\\", \\"text\\": \\"Sample\\", \\"type\\": \\"video\\"}"';
      final payload2 = LongPressPayload.tryParse(quotedJson);
      expect(payload2, isNotNull);
      expect(payload2?.url, 'https://example.com/escaped.mp4');
      expect(payload2?.text, 'Sample');
      expect(payload2?.type, 'video');
    });

    test('ReaderArticle instantiates with sanitized HTML content', () {
      const article = ReaderArticle(
        title: 'Safe Title',
        content: '<p>Valid article body content</p>',
        url: 'https://example.com/news/1',
        domain: 'example.com',
        author: 'Editor',
        textContent: 'Valid article body content',
        wordCount: 4,
        readingTime: 1,
      );

      expect(article.title, 'Safe Title');
      expect(article.content, contains('Valid article body content'));
      expect(article.domain, 'example.com');
      expect(article.wordCount, 4);
    });
  });
}
