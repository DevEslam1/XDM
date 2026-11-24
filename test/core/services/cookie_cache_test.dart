import 'dart:io';

import 'package:dmx/core/services/network/cookie_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CookieCache static helpers', () {
    test('computeExpiry honours Max-Age', () {
      final before = DateTime.now();
      final expiry = CookieCache.computeExpiry('session=abc; Max-Age=120');
      expect(expiry.difference(before).inSeconds, greaterThanOrEqualTo(119));
    });

    test('computeExpiry honours Expires header', () {
      final expiry = CookieCache.computeExpiry(
        'a=b; Expires=Wed, 21 Oct 2099 07:28:00 GMT',
      );
      expect(expiry.year, 2099);
    });

    test('computeExpiry falls back to default TTL on unparseable Expires', () {
      final before = DateTime.now();
      final expiry = CookieCache.computeExpiry('a=b; Expires=not-a-date');
      expect(expiry.difference(before).inHours, greaterThanOrEqualTo(0));
    });

    test('computeExpiry ignores malformed Max-Age and uses default', () {
      final before = DateTime.now();
      final expiry = CookieCache.computeExpiry('a=b; Max-Age=abc');
      expect(expiry.isAfter(before), isTrue);
    });

    test('extractCookieName handles = and no =', () {
      expect(CookieCache.extractCookieName('sid=123; Path=/'), 'sid');
      expect(CookieCache.extractCookieName('flag; Path=/'), 'flag');
    });

    test('extractCookiePath returns path or default /', () {
      expect(CookieCache.extractCookiePath('a=b; Path=/x'), '/x');
      expect(CookieCache.extractCookiePath('a=b'), '/');
    });

    test('buildKey composes origin|name|path', () {
      expect(
        CookieCache.buildKey('https://e.com', 'sid=1; Path=/a'),
        'https://e.com|sid|/a',
      );
    });
  });

  group('CookieCache instance behaviour', () {
    late CookieCache cache;

    setUp(() {
      cache = CookieCache();
    });

    tearDown(() async {
      await cache.dispose();
    });

    test('put then get by name returns cookie', () {
      cache.put('https://e.com', 'sid=1; Path=/');
      expect(cache.get('https://e.com', name: 'sid'), 'sid=1; Path=/');
    });

    test('get by name returns null when missing', () {
      expect(cache.get('https://e.com', name: 'nope'), isNull);
    });

    test('expired entry is evicted on get by name', () {
      cache.put(
        'https://e.com',
        'sid=1; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      );
      expect(cache.get('https://e.com', name: 'sid'), isNull);
    });

    test('get without name aggregates cookies by origin', () {
      cache.put('https://e.com', 'a=1; Path=/');
      cache.put('https://e.com', 'b=2; Path=/');
      final combined = cache.get('https://e.com');
      expect(combined, contains('a=1'));
      expect(combined, contains('b=2'));
    });

    test('get without name returns null for unknown origin', () {
      expect(cache.get('https://none.com'), isNull);
    });

    test('expired entries are skipped in origin aggregation', () {
      cache.put(
        'https://e.com',
        'old=1; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      );
      cache.put('https://e.com', 'fresh=2; Path=/');
      final combined = cache.get('https://e.com')!;
      expect(combined.contains('fresh=2'), isTrue);
      expect(combined.contains('old=1'), isFalse);
    });

    test('clear empties the cache', () {
      cache.put('https://e.com', 'a=1; Path=/');
      cache.clear();
      expect(cache.get('https://e.com', name: 'a'), isNull);
    });

    test('onMemoryPressure clears the cache', () {
      cache.put('https://e.com', 'a=1; Path=/');
      cache.onMemoryPressure();
      expect(cache.get('https://e.com', name: 'a'), isNull);
    });

    test('evicts oldest entry when over the 100-entry limit', () async {
      cache.put('https://e0.com', 'k0=v0; Path=/');
      // Ensure the first entry is strictly older than the rest: DateTime.now()
      // has coarse resolution on some platforms, so an immediate loop would
      // tie every timestamp and evict the newest entry instead.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      for (var i = 1; i < 101; i++) {
        cache.put('https://e$i.com', 'k$i=v$i; Path=/');
      }
      // Oldest origin (index 0) should have been evicted.
      expect(cache.get('https://e0.com', name: 'k0'), isNull);
      expect(cache.get('https://e100.com', name: 'k100'), isNotNull);
    });

    test('get by name honours an explicit path', () {
      cache.put('https://e.com', 'sid=1; Path=/a');
      expect(
        cache.get('https://e.com', name: 'sid', path: '/a'),
        'sid=1; Path=/a',
      );
      expect(cache.get('https://e.com', name: 'sid', path: '/b'), isNull);
      expect(cache.get('https://e.com', name: 'sid'), isNull);
    });

    test('put eagerly evicts entries that are already expired', () {
      cache.put(
        'https://e.com',
        'old=1; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      );
      cache.put('https://e.com', 'fresh=2; Path=/');
      final combined = cache.get('https://e.com');
      expect(combined, contains('fresh=2'));
      expect(combined, isNot(contains('old=1')));
    });

    test('dispose clears the cache', () async {
      cache.put('https://e.com', 'a=1; Path=/');
      await cache.dispose();
      expect(cache.get('https://e.com', name: 'a'), isNull);
    });

    test('entries that expire after insertion are lazily removed on read',
        () async {
      cache.put('https://e.com', 'sid=1; Path=/; Max-Age=1');
      cache.put('https://e.com', 'other=2; Path=/; Max-Age=1');
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      // get-by-name removes the expired entry.
      expect(cache.get('https://e.com', name: 'sid'), isNull);
      // origin aggregation removes remaining expired entries.
      expect(cache.get('https://e.com'), isNull);
    });
  });

  group('CookieCache usages', () {
    test('works with dart:io HttpDate style expiry', () {
      final expiry = CookieCache.computeExpiry(
        'x=y; Expires=${HttpDate.format(DateTime.utc(2030, 1, 1))}',
      );
      expect(expiry.toUtc().year, 2030);
    });
  });
}
