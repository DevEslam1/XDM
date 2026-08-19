import 'package:dmx/features/browser/services/long_press_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LongPressPayload Tests', () {
    test('Parses direct JSON payload', () {
      const json =
          '{"url": "https://example.com/file.zip", "type": "link", "text": "Download File"}';
      final payload = LongPressPayload.tryParse(json);

      expect(payload, isNotNull);
      expect(payload!.url, equals('https://example.com/file.zip'));
      expect(payload.type, equals('link'));
      expect(payload.text, equals('Download File'));
    });

    test('Parses double-quoted and escaped JSON string', () {
      const doubleQuoted =
          '"{\\"url\\": \\"https://example.com/image.png\\", \\"type\\": \\"image\\", \\"text\\": \\"Sample Image\\"}"';
      final payload = LongPressPayload.tryParse(doubleQuoted);

      expect(payload, isNotNull);
      expect(payload!.url, equals('https://example.com/image.png'));
      expect(payload.type, equals('image'));
      expect(payload.text, equals('Sample Image'));
    });

    test('Returns null for empty string or invalid JSON', () {
      expect(LongPressPayload.tryParse(''), isNull);
      expect(LongPressPayload.tryParse('not a json string'), isNull);
    });

    test('Returns null when URL is missing or empty', () {
      const json = '{"url": "", "type": "link"}';
      expect(LongPressPayload.tryParse(json), isNull);
    });

    test('Defaults type to link when type missing', () {
      const json = '{"url": "https://example.com/page"}';
      final payload = LongPressPayload.tryParse(json);

      expect(payload, isNotNull);
      expect(payload!.type, equals('link'));
    });
  });
}
