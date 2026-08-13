import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dmx/features/browser/services/custom_adblock_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CustomAdBlockStore', () {
    late CustomAdBlockStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = CustomAdBlockStore.instance;
      await store.init();
      // Clear previous state since it's a singleton
      for (var host in store.hosts.toList()) {
        await store.removeHost(host);
      }
      await store.setUseCustomOnly(false);
    });

    test('addHosts sanitizes and dedupes', () async {
      await store
          .addHosts('HTTPS://Example.Com/path, google.com\n  another.com  ');
      expect(store.hosts, contains('example.com'));
      expect(store.hosts, contains('google.com'));
      expect(store.hosts, contains('another.com'));
      expect(store.hosts.length, 3);
    });

    test('contains matches parent domains', () async {
      await store.addHosts('doubleclick.net');
      expect(store.contains('doubleclick.net'), isTrue);
      expect(store.contains('sub.doubleclick.net'), isTrue);
      expect(store.contains('even.more.sub.doubleclick.net'), isTrue);
      expect(store.contains('otherclick.net'), isFalse);
    });

    test('persistence round-trip', () async {
      await store.addHosts('persist.me');
      await store.setUseCustomOnly(true);

      // Re-init should load saved values
      await store.init();
      expect(store.hosts, contains('persist.me'));
      expect(store.useCustomOnly, isTrue);
    });

    test('removeHost works with raw URLs and uppercase strings', () async {
      await store.addHosts('delete.me');
      expect(store.hosts, contains('delete.me'));
      await store.removeHost('HTTPS://DELETE.ME/path?q=1');
      expect(store.hosts, isNot(contains('delete.me')));
    });

    test('addHosts accepts IP addresses and local domain names', () async {
      await store.addHosts('192.168.1.100, 127.0.0.1, router.local, mydevice.lan');
      expect(store.hosts, contains('192.168.1.100'));
      expect(store.hosts, contains('127.0.0.1'));
      expect(store.hosts, contains('router.local'));
      expect(store.hosts, contains('mydevice.lan'));
    });
  });
}
