import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dmx/features/browser/services/ad_blocker_service.dart';
import 'package:dmx/features/browser/services/custom_adblock_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AdBlockerService with CustomAdBlockStore', () {
    late AdBlockerService service;
    late CustomAdBlockStore customStore;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      service = AdBlockerService.instance;
      customStore = CustomAdBlockStore.instance;
      await customStore.init();
      await service.init();

      // Clear custom store state
      for (var host in customStore.hosts.toList()) {
        await customStore.removeHost(host);
      }
      await customStore.setUseCustomOnly(false);
      service.refresh();
    });

    test('useCustomOnly correctly bypasses downloaded lists', () async {
      // By default, it should have some blocked domains (static ones + downloaded if any)
      expect(service.shouldBlockUrl('doubleclick.net'), isTrue);

      await customStore.addHosts('my-custom-ad.com');
      await customStore.setUseCustomOnly(true);
      service.refresh();

      // Should block custom one
      expect(service.shouldBlockUrl('my-custom-ad.com'), isTrue);

      // Should NOT block standard ones anymore
      expect(service.shouldBlockUrl('doubleclick.net'), isFalse);

      // Toggle back
      await customStore.setUseCustomOnly(false);
      service.refresh();
      expect(service.shouldBlockUrl('doubleclick.net'), isTrue);
    });

    test('isAllowListed domain overrides block rules', () async {
      // Allow-listed domain should return false for shouldBlockUrl
      expect(service.isAllowListed('recaptcha'), isFalse);
      expect(service.shouldBlockUrl('https://doubleclick.net/ad.js'), isTrue);
    });

    test('running blockedCount and blockedCountNotifier update on block',
        () async {
      service.resetStats();
      expect(service.blockedCount, 0);

      var notifiedValue = -1;
      service.blockedCountNotifier.addListener(() {
        notifiedValue = service.blockedCountNotifier.value;
      });

      service.shouldBlockUrl('https://doubleclick.net/ad.js');
      expect(service.blockedCount, equals(1));
      expect(notifiedValue, equals(1));
      expect(service.blockedDomains, contains('doubleclick.net'));
    });

    test('extractHostAndPath normalizes hostnames and paths correctly', () {
      expect(
          AdBlockerService.extractHostAndPath(
              'https://DOUBLECLICK.NET/ad.js?v=1'),
          equals(('doubleclick.net', '/ad.js')));
      expect(
          AdBlockerService.extractHostAndPath(
              '//adservice.google.com:8080/page'),
          equals(('adservice.google.com', '/page')));
      expect(
          AdBlockerService.extractHostAndPath('doubleclick.net/path/to/ad.js'),
          equals(('doubleclick.net', '/path/to/ad.js')));
      expect(AdBlockerService.extractHostAndPath('doubleclick.net:8443/ad.js'),
          equals(('doubleclick.net', '/ad.js')));
      expect(AdBlockerService.extractHostAndPath('doubleclick.net'),
          equals(('doubleclick.net', '')));
    });

    test(
        'shouldBlockUrl handles schemeless URLs and ports without polluting blockedDomains',
        () {
      service.resetStats();
      expect(service.shouldBlockUrl('doubleclick.net/some/path/ad.js'), isTrue);
      expect(service.blockedDomains, contains('doubleclick.net'));
      expect(service.blockedDomains,
          isNot(contains('doubleclick.net/some/path/ad.js')));

      expect(service.shouldBlockUrl('doubleclick.net:8080/ad.js'), isTrue);
      expect(service.blockedDomains, contains('doubleclick.net'));
    });

    test('youtubeEarlyJs safely hooks ytcfg via Object.defineProperty', () {
      const script = AdBlockerService.youtubeEarlyJs;
      expect(script, contains('Object.defineProperty(window, \'ytcfg\''));
      expect(script, contains('val.web_enable_adblock_detection = false'));
    });
  });
}
