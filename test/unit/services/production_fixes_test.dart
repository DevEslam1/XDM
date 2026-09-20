import 'package:dmx/core/services/background_gate.dart';
import 'package:dmx/core/services/network/cookie_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Phase 1: BackgroundGate Tests', () {
    test('BackgroundGate adaptInterval scales base duration correctly', () {
      const base = Duration(seconds: 5);
      final adapted = BackgroundGate.adaptInterval(base);
      expect(adapted.inSeconds, greaterThanOrEqualTo(5));
    });
  });

  group('Phase 2: CookieCache Tests', () {
    test('CookieCache stores, retrieves, and clears entries', () {
      final cache = CookieCache();
      cache.put('https://example.com', 'session_id=12345');
      expect(cache.get('https://example.com'), equals('session_id=12345'));

      cache.clear();
      expect(cache.get('https://example.com'), isNull);
    });
  });

}
