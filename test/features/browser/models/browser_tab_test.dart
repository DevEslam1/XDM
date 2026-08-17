import 'dart:typed_data';

import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BrowserTab Model Tests', () {
    test('Favicon setter detaches and bounds byte buffer to 10KB (B2)', () {
      final tab = BrowserTab(id: 'tab-1', url: 'https://example.com');
      final largeBytes = Uint8List(20480); // 20 KB
      for (int i = 0; i < largeBytes.length; i++) {
        largeBytes[i] = i % 256;
      }

      tab.faviconBytes = largeBytes;

      expect(tab.faviconBytes, isNotNull);
      expect(tab.faviconBytes!.length, 10240); // Capped at 10 KB
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
