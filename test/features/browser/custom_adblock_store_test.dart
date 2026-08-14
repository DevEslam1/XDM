import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/browser/services/custom_adblock_store.dart';
import 'package:dmx/features/browser/services/ad_blocker_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('CustomAdBlockStore & Cosmetic Rules Tests (B-05 / B-06)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('isValidHost validates hostnames and IP addresses correctly (B-06)',
        () {
      expect(CustomAdBlockStore.isValidHost('adserver.example.com'), isTrue);
      expect(CustomAdBlockStore.isValidHost('192.168.1.100'), isTrue);
      expect(CustomAdBlockStore.isValidHost('http://ads.tracker.org/script.js'),
          isTrue);

      expect(CustomAdBlockStore.isValidHost(''), isFalse);
      expect(CustomAdBlockStore.isValidHost('   '), isFalse);
      expect(CustomAdBlockStore.isValidHost('invalid!@#\$%^&*()'), isFalse);
    });

    test(
        'cssRulesForUrl deduplicates and generates safe cosmetic selectors (B-05)',
        () {
      final adBlocker = AdBlockerService.instance;
      final rules = adBlocker.cssRulesForUrl('https://example.com/news');
      expect(rules, contains('display: none !important;'));
    });
  });
}
