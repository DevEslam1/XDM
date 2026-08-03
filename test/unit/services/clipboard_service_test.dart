import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/utils/url_utils.dart';

void main() {
  group('ClipboardService URL validation', () {
    test('rejects javascript: URLs', () {
      expect(isHttpUrl('javascript:void(0)'), false);
      expect(isHttpUrl('javascript:alert("xss")'), false);
    });

    test('rejects data: URLs', () {
      expect(isHttpUrl('data:text/html,<script>alert(1)</script>'), false);
      expect(isHttpUrl('data:image/svg+xml,<svg>'), false);
    });

    test('rejects vbscript: URLs', () {
      expect(isHttpUrl('vbscript:msgbox("xss")'), false);
    });

    test('accepts http/https URLs', () {
      expect(isHttpUrl('http://example.com/file.zip'), true);
      expect(isHttpUrl('https://example.com'), true);
    });

    test('accepts magnet URLs', () {
      expect(
        isMagnetUrl(
            'magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10'),
        true,
      );
    });

    test('rejects empty strings', () {
      expect(isHttpUrl(''), false);
      expect(isMagnetUrl(''), false);
    });
  });
}
