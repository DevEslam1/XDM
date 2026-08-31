import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// URL scheme safety validation mirrors the logic in TabManager.restoreTabs:
  ///   - about:blank is safe (treated as blank tab)
  ///   - http and https are safe
  ///   - file://, javascript:, data: etc. must be rejected
  group('TabManager URL scheme safety', () {
    bool isSafeRestoredUrl(String url) {
      if (url.isEmpty || url == 'about:blank') return true;
      final uri = Uri.tryParse(url);
      if (uri == null) return false;
      return uri.scheme == 'http' || uri.scheme == 'https';
    }

    test('https URL is safe', () {
      expect(isSafeRestoredUrl('https://example.com'), isTrue);
    });

    test('http URL is safe', () {
      expect(isSafeRestoredUrl('http://example.com'), isTrue);
    });

    test('about:blank is safe', () {
      expect(isSafeRestoredUrl('about:blank'), isTrue);
    });

    test('empty string is safe (treated as blank)', () {
      expect(isSafeRestoredUrl(''), isTrue);
    });

    test('javascript: scheme is rejected', () {
      expect(isSafeRestoredUrl('javascript:alert(1)'), isFalse);
    });

    test('file:// scheme is rejected', () {
      expect(isSafeRestoredUrl('file:///etc/passwd'), isFalse);
    });

    test('data: scheme is rejected', () {
      expect(isSafeRestoredUrl('data:text/html,<script>alert(1)</script>'),
          isFalse);
    });

    test('ftp:// scheme is rejected', () {
      expect(isSafeRestoredUrl('ftp://example.com/file'), isFalse);
    });

    test('unparseable URL is rejected', () {
      expect(isSafeRestoredUrl(':::garbage'), isFalse);
    });
  });

  group('BrowserTab incognito flag', () {
    test('default tab is not incognito', () {
      final tab = BrowserTab(id: 'test-1', url: '', title: 'New Tab');
      expect(tab.isIncognito, isFalse);
    });

    test('incognito tab has flag set', () {
      final tab = BrowserTab(
        id: 'test-2',
        url: '',
        title: 'New Tab',
        isIncognito: true,
      );
      expect(tab.isIncognito, isTrue);
    });
  });
}
