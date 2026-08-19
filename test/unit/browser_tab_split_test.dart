import 'dart:typed_data';
import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BrowserTab Clean Architecture Split Tests', () {
    test('initializes sub-states and normalized identity correctly', () {
      final tab = BrowserTab(
        id: 'tab-101',
        url: 'https://example.com/page',
        title: 'Example Page',
        isIncognito: true,
      );

      expect(tab.id, equals('tab-101'));
      expect(tab.url, equals('https://example.com/page'));
      expect(tab.isIncognito, isTrue);
      expect(tab.isHome, isFalse);
      expect(tab.host, equals('example.com'));
      expect(tab.domain, equals('example.com'));
      expect(tab.title, equals('Example Page'));
      expect(tab.progress, equals(0.0));
      expect(tab.isLoading, isFalse);
    });

    test('normalizes empty URL to canonical about:blank and marks isHome', () {
      final tab = BrowserTab(id: 'tab-102', url: '');
      expect(tab.url, equals('about:blank'));
      expect(tab.isHome, isTrue);
      expect(tab.host, isEmpty);
      expect(tab.stripLabel, equals('Home'));
    });

    test('updates URL and syncs urlNotifier and host cache', () {
      final tab = BrowserTab(id: 'tab-103', url: 'https://google.com');
      expect(tab.host, equals('google.com'));

      tab.url = 'https://flutter.dev/docs';
      expect(tab.url, equals('https://flutter.dev/docs'));
      expect(tab.urlNotifier.value, equals('https://flutter.dev/docs'));
      expect(tab.host, equals('flutter.dev'));
    });

    test('clamps oversized favicon bytes to 512KB limit', () {
      final tab = BrowserTab(id: 'tab-104', url: 'https://example.com');
      final giantFavicon = Uint8List(600 * 1024);
      tab.faviconBytes = giantFavicon;
      expect(tab.faviconBytes, isNull);

      final validFavicon = Uint8List(32 * 1024);
      tab.faviconBytes = validFavicon;
      expect(tab.faviconBytes, isNotNull);
      expect(tab.faviconBytesSize, equals(32 * 1024));
    });

    test('disposes webViewState cleanly and marks isDisposed', () {
      final tab = BrowserTab(id: 'tab-105', url: 'https://example.com');
      expect(tab.isDisposed, isFalse);

      tab.dispose();
      expect(tab.isDisposed, isTrue);
      // Double dispose is a safe no-op
      tab.dispose();
      expect(tab.isDisposed, isTrue);
    });
  });
}
