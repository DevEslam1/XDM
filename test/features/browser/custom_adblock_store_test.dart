import 'package:dmx/features/browser/services/ad_blocker_service.dart';
import 'package:dmx/features/browser/services/custom_adblock_store.dart';
import 'package:flutter_test/flutter_test.dart';
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

    test('isValidHost handles IPv6, ports, paths and trailing dots', () {
      expect(CustomAdBlockStore.isValidHost('[::1]'), isTrue);
      expect(CustomAdBlockStore.isValidHost('example.com:8080'), isTrue);
      expect(CustomAdBlockStore.isValidHost('http://example.com/a/b'), isTrue);
      expect(CustomAdBlockStore.isValidHost('example.com.'), isTrue);
      expect(CustomAdBlockStore.isValidHost('localhost'), isTrue);
      expect(CustomAdBlockStore.isValidHost('bad host!'), isFalse);
    });

    test('addHosts sanitizes, splits and deduplicates input', () async {
      final store = CustomAdBlockStore.instance;
      for (final host in store.hosts.toList()) {
        await store.removeHost(host);
      }

      await store.addHosts('https://ads.one.com/x, ads.two.com\nads.one.com  ');
      expect(store.hosts.contains('ads.one.com'), isTrue);
      expect(store.hosts.contains('ads.two.com'), isTrue);

      final before = store.hosts.length;
      await store.addHosts('ads.one.com');
      expect(store.hosts.length, before);

      await store.addHosts('bad!@#host');
      expect(store.hosts.length, before);
    });

    test('removeHost sanitizes the target before removal', () async {
      final store = CustomAdBlockStore.instance;
      for (final host in store.hosts.toList()) {
        await store.removeHost(host);
      }
      await store.addHosts('remove.me.com');
      await store.removeHost('https://remove.me.com/path');
      expect(store.hosts.contains('remove.me.com'), isFalse);

      // Removing a non-existent host is a no-op.
      await store.removeHost('missing.com');
      expect(store.hosts.contains('missing.com'), isFalse);
    });

    test('contains walks parent domains', () async {
      final store = CustomAdBlockStore.instance;
      for (final host in store.hosts.toList()) {
        await store.removeHost(host);
      }
      await store.addHosts('ads.example.com');
      expect(store.contains('ads.example.com'), isTrue);
      expect(store.contains('sub.ads.example.com'), isTrue);
      expect(store.contains('other.com'), isFalse);
      expect(store.contains(''), isFalse);
    });

    test('setUseCustomOnly persists and toggles the flag', () async {
      final store = CustomAdBlockStore.instance;
      await store.setUseCustomOnly(true);
      expect(store.useCustomOnly, isTrue);

      await store.setUseCustomOnly(true);
      expect(store.useCustomOnly, isTrue);

      await store.setUseCustomOnly(false);
      expect(store.useCustomOnly, isFalse);
    });

    test('init loads persisted hosts and flag', () async {
      SharedPreferences.setMockInitialValues({
        'custom_adblock_hosts': ['persisted.com'],
        'custom_adblock_use_custom_only': true,
      });
      final store = CustomAdBlockStore.instance;
      await store.init();
      expect(store.hosts.contains('persisted.com'), isTrue);
      expect(store.useCustomOnly, isTrue);
      await store.setUseCustomOnly(false);
    });
  });
}
