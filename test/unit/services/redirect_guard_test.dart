import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/browser/services/redirect_guard.dart';

void main() {
  group('RedirectGuard.extractDomain', () {
    test('simple domain', () {
      expect(RedirectGuard.extractDomain('https://example.com/page'), 'example.com');
    });

    test('strips www prefix', () {
      expect(RedirectGuard.extractDomain('https://www.example.com'), 'example.com');
    });

    test('subdomain returns root', () {
      expect(RedirectGuard.extractDomain('https://sub.example.com'), 'example.com');
    });

    test('multi-part TLD co.uk', () {
      expect(RedirectGuard.extractDomain('https://shop.bbc.co.uk'), 'bbc.co.uk');
    });

    test('multi-part TLD com.au', () {
      expect(RedirectGuard.extractDomain('https://news.abc.com.au'), 'abc.com.au');
    });

    test('empty string returns empty', () {
      expect(RedirectGuard.extractDomain(''), '');
    });

    test('malformed URL returns empty', () {
      expect(RedirectGuard.extractDomain(':::not-a-url'), '');
    });
  });

  group('RedirectGuard.isSuspiciousRedirect', () {
    final guard = RedirectGuard.instance;

    setUp(() {
      // Ensure guard is enabled for all tests
      guard.setEnabled(true);
    });

    test('same domain is not suspicious', () {
      expect(
        guard.isSuspiciousRedirect(
          currentTabUrl: 'https://example.com/page1',
          targetUrl: 'https://example.com/page2',
        ),
        isFalse,
      );
    });

    test('allowlisted domain (google.com) is not suspicious', () {
      expect(
        guard.isSuspiciousRedirect(
          currentTabUrl: 'https://example.com/page',
          targetUrl: 'https://google.com/search',
        ),
        isFalse,
      );
    });

    test('allowlisted subdomain (maps.google.com) is not suspicious', () {
      expect(
        guard.isSuspiciousRedirect(
          currentTabUrl: 'https://example.com/page',
          targetUrl: 'https://maps.google.com/',
        ),
        isFalse,
      );
    });

    test('cross-domain redirect to unknown site is suspicious', () {
      expect(
        guard.isSuspiciousRedirect(
          currentTabUrl: 'https://example.com/page',
          targetUrl: 'https://sketchy-ads.biz/track',
        ),
        isTrue,
      );
    });

    test('disabled guard never flags suspicious', () {
      guard.setEnabled(false);
      expect(
        guard.isSuspiciousRedirect(
          currentTabUrl: 'https://example.com/page',
          targetUrl: 'https://sketchy-ads.biz/track',
        ),
        isFalse,
      );
    });
  });

  group('RedirectGuard.markUserInitiated / consumeUserInitiated', () {
    final guard = RedirectGuard.instance;

    test('marking a URL allows consuming it once', () {
      guard.markUserInitiated('https://example.com/go');
      expect(guard.consumeUserInitiated('https://example.com/go'), isTrue);
    });

    test('consuming removes the mark', () {
      guard.markUserInitiated('https://example.com/go');
      guard.consumeUserInitiated('https://example.com/go');
      expect(guard.consumeUserInitiated('https://example.com/go'), isFalse);
    });
  });
}
