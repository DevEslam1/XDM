import 'dart:typed_data';

import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BrowserTab Model Tests', () {
    test('Favicon setter detaches buffer and discards oversized payloads (B2)',
        () {
      final tab = BrowserTab(id: 'tab-1', url: 'https://example.com');
      final validBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      tab.faviconBytes = validBytes;

      expect(tab.faviconBytes, isNotNull);
      expect(tab.faviconBytes!.length, 5);
      expect(identical(tab.faviconBytes, validBytes), isFalse); // Detached copy

      final oversizedBytes = Uint8List(600 * 1024); // 600 KB > 512 KB
      tab.faviconBytes = oversizedBytes;
      expect(tab.faviconBytes, isNull);
    });

    test('Host cache is invalidated on updateUrl (B3)', () {
      final tab = BrowserTab(id: 'tab-1', url: 'https://example.com/page1');
      expect(tab.host, 'example.com');

      tab.updateUrl('https://otherdomain.org/path');
      expect(tab.host, 'otherdomain.org');

      tab.updateUrl('');
      expect(tab.host, '');
    });

    test('Canonical blank tab handling (B5)', () {
      final tab1 = BrowserTab(id: 'tab-1', url: 'about:blank');
      expect(tab1.isHome, isTrue);

      final tab2 = BrowserTab(id: 'tab-2', url: '');
      expect(tab2.isHome, isTrue);

      final tab3 = BrowserTab(id: 'tab-3', url: 'https://github.com');
      expect(tab3.isHome, isFalse);
    });

    test('Loading and URL notifiers notify listeners (P1, P2)', () {
      final tab = BrowserTab(id: 'tab-1', url: 'https://example.com');
      bool loadingNotified = false;
      bool urlNotified = false;

      tab.loadingNotifier.addListener(() {
        loadingNotified = true;
      });
      tab.urlNotifier.addListener(() {
        urlNotified = true;
      });

      tab.isLoading = true;
      expect(loadingNotified, isTrue);

      tab.updateUrl('https://example.com/test');
      expect(urlNotified, isTrue);
    });
  });
}
