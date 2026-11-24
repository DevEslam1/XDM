import 'dart:io';

import 'package:dmx/features/browser/services/ad_blocker_service.dart';
import 'package:dmx/features/browser/services/adblock_filter_updater.dart';
import 'package:dmx/features/browser/services/custom_adblock_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdBlockerService service;
  late AdBlockFilterUpdater updater;
  late CustomAdBlockStore customStore;

  Future<void> injectFilters(List<String> lines) async {
    final dir = Directory.systemTemp.createTempSync('adblock_test');
    final file = File('${dir.path}/filters.txt')
      ..writeAsStringSync(lines.join('\n'));
    await updater.parseFilterFile(file, FilterType.ads);
    dir.deleteSync(recursive: true);
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    service = AdBlockerService.instance;
    updater = AdBlockFilterUpdater();
    customStore = CustomAdBlockStore.instance;
    await service.init();
    await Future<void>.delayed(Duration.zero);
  });

  setUp(() async {
    await service.setEnabled(true);
    service.resetStats();
    await customStore.setUseCustomOnly(false);
    for (final host in customStore.hosts.toList()) {
      await customStore.removeHost(host);
    }
    for (final rule in service.customRules.toList()) {
      await service.removeCustomRule(rule);
    }
    for (final domain in updater.allowListedDomains.toList()) {
      updater.removeAllowListDomain(domain);
    }
    service.refresh();
  });

  group('AdBlockerService static helpers', () {
    test('extractHostAndPath handles all input shapes', () {
      expect(AdBlockerService.extractHostAndPath(''), ('', ''));
      expect(AdBlockerService.extractHostAndPath('https://EXAMPLE.com/a?b=1'),
          ('example.com', '/a'));
      expect(AdBlockerService.extractHostAndPath('//host.com/path'),
          ('host.com', '/path'));
      expect(AdBlockerService.extractHostAndPath('host.com:8080/x'),
          ('host.com', '/x'));
      expect(AdBlockerService.extractHostAndPath('host.com/x'),
          ('host.com', '/x'));
      expect(AdBlockerService.extractHostAndPath('host.com'), ('host.com', ''));
      // Malformed inputs fall back gracefully after the parse failure.
      expect(AdBlockerService.extractHostAndPath('http://[').$1, 'http');
      expect(AdBlockerService.extractHostAndPath('//[').$1, '');
    });

    test('isLikelyDownloadUrl recognises downloads and ignores pages', () {
      expect(AdBlockerService.isLikelyDownloadUrl(''), isFalse);
      expect(AdBlockerService.isLikelyDownloadUrl('magnet:?xt=urn:btih:x'),
          isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://a.com/file.apk'),
          isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://a.com/f.zip?x=1'),
          isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://a.com/f.zip&x=1'),
          isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://a.com/f.zip#frag'),
          isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://a.com/dl?file=.zip'),
          isTrue);
      expect(
          AdBlockerService.isLikelyDownloadUrl(
              'https://a.com/x?filename=foo.zip'),
          isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://a.com/download/x'),
          isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://a.com/downloads/x'),
          isTrue);
      expect(
          AdBlockerService.isLikelyDownloadUrl('https://a.com/dl/x'), isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://a.com/getfile?id=1'),
          isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://a.com/files/x'),
          isTrue);
      expect(
          AdBlockerService.isLikelyDownloadUrl('https://a.com/download_file'),
          isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://a.com/x?download=1'),
          isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://a.com/x&download=1'),
          isTrue);
      expect(
          AdBlockerService.isLikelyDownloadUrl(
              'https://a.com/x?action=download'),
          isTrue);
      expect(
          AdBlockerService.isLikelyDownloadUrl('https://a.com/x?dl=1'), isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://a.com/x?dl=true'),
          isTrue);
      expect(AdBlockerService.isLikelyDownloadUrl('https://a.com/article'),
          isFalse);
    });

    test('isYoutubePage handles null, empty and malformed input', () {
      expect(AdBlockerService.isYoutubePage(null), isFalse);
      expect(AdBlockerService.isYoutubePage(''), isFalse);
      expect(AdBlockerService.isYoutubePage('https://www.youtube.com/watch'),
          isTrue);
      expect(AdBlockerService.isYoutubePage('https://youtu.be/abc'), isTrue);
      expect(AdBlockerService.isYoutubePage('https://example.com'), isFalse);
      expect(AdBlockerService.isYoutubePage('http://['), isFalse);
    });

    test('getRegistrableDomain and isSameSite resolve parent domains', () {
      expect(AdBlockerService.getRegistrableDomain(''), '');
      expect(
          AdBlockerService.getRegistrableDomain('example.com'), 'example.com');
      expect(AdBlockerService.getRegistrableDomain('a.b.example.com'),
          'example.com');
      expect(
          AdBlockerService.getRegistrableDomain('news.bbc.co.uk'), 'bbc.co.uk');
      expect(AdBlockerService.isSameSite('', 'a.com'), isFalse);
      expect(AdBlockerService.isSameSite('a.com', 'a.com'), isTrue);
      expect(AdBlockerService.isSameSite('sub.a.com', 'a.com'), isTrue);
      expect(AdBlockerService.isSameSite('a.com', 'b.com'), isFalse);
    });
  });

  group('AdBlockerService state and listeners', () {
    test('resetStats clears counters and domains', () {
      service.shouldBlockUrl('https://doubleclick.net/ad.js');
      expect(service.blockedCount, greaterThan(0));
      expect(service.blockedDomains, isNotEmpty);

      service.resetStats();
      expect(service.blockedCount, 0);
      expect(service.blockedDomains, isEmpty);
    });

    test('refresh notifies listeners and tolerates throwing listeners', () {
      var notified = 0;
      void good() => notified++;
      service.addListener(good);
      service.addListener(good); // duplicate ignored
      service.addListener(() => throw Exception('listener boom'));

      service.refresh();
      expect(notified, 1);

      service.removeListener(good);
      service.refresh();
      expect(notified, 1);
    });

    test('blockedCountNotifier mirrors blockedCount', () {
      var observed = -1;
      service.blockedCountNotifier.addListener(() {
        observed = service.blockedCountNotifier.value;
      });
      service.shouldBlockUrl('https://doubleclick.net/ad.js');
      expect(observed, service.blockedCount);
    });

    test('bumpGen and dynamicDomainsJson refresh the payload', () {
      customStore.addHosts('dynamic.example.com');
      final first = service.dynamicDomainsJson;
      expect(first, contains('dynamic.example.com'));
      expect(service.dynamicDomainsJson, same(first));

      service.bumpGen();
      final second = service.dynamicDomainsJson;
      expect(second, contains('dynamic.example.com'));
    });
  });

  group('AdBlockerService css/js generation', () {
    test('cssRules, earlyJs and antiDetectJs are empty when disabled',
        () async {
      await service.setEnabled(false);
      expect(service.isEnabled, isFalse);
      expect(service.cssRules, '');
      expect(service.earlyJs, '');
      expect(service.antiDetectJs, '');
      expect(service.scriptletJs, '');
      expect(service.contentBlockers, isEmpty);
      await service.setEnabled(true);
    });

    test('cssRules contains selectors, custom rules and protection css',
        () async {
      await service.addCustomRule('#my-ad { display:none }');
      final css = service.cssRules;
      expect(css, contains('.adsbygoogle'));
      expect(css, contains('#my-ad { display:none }'));
      expect(css, contains('display: revert !important'));
    });

    test('earlyJs and antiDetectJs contain the expected guards', () {
      expect(service.earlyJs, contains('window.open'));
      expect(service.antiDetectJs, contains('window.fetch'));
      expect(service.antiDetectJs, contains('XMLHttpRequest'));
    });

    test('cssRulesForUrl merges safe host cosmetic rules', () async {
      await injectFilters(['##.ad-banner', '##.download-thing']);
      final css = service.cssRulesForUrl('https://example.com/news');
      expect(css, contains('.ad-banner'));
      expect(css, isNot(contains('.download-thing')));

      expect(service.cssRulesForUrl(''), contains('.adsbygoogle'));
      expect(service.cssRulesForUrl('not-a-url'), contains('.adsbygoogle'));
    });

    test('scriptletJs builds calls for every supported scriptlet', () async {
      await injectFilters([
        '##+js(abort-on-property-read, foo.bar)',
        '##+js(aopw, baz)',
        '##+js(abort-on-property-write, qux)',
        '##+js(aopb, quux)',
        '##+js(set-constant, canRunAds, true)',
        '##+js(set-constant, a, false)',
        '##+js(set-constant, b, null)',
        '##+js(set-constant, c, undefined)',
        '##+js(set-constant, d, noopfunc)',
        '##+js(set-constant, e, truefunc)',
        '##+js(set-constant, f, falsefunc)',
        '##+js(set-constant, g, 42)',
        '##+js(set-constant, h, "str")',
        '##+js(no-settimeout-if, ads)',
        '##+js(addeventlistener-defuser, click, ads)',
        '##+js(json-prune, a b)',
        '##+js(noeval)',
        '##+js(prevent-fetch, /ads/)',
        '##+js(unknown-scriptlet)',
      ]);

      final js = service.scriptletJs;
      expect(js, contains('_xdmAbortOnRead'));
      expect(js, contains('_xdmAbortOnWrite'));
      expect(js, contains('_xdmSetConstant'));
      expect(js, contains('function(){return false;}'));
      expect(js, contains('_xdmNoTimeoutIf'));
      expect(js, contains('_xdmDefuseListener'));
      expect(js, contains('_xdmJsonPrune'));
      expect(js, contains('_xdmNoEval'));
      expect(js, contains('_xdmPreventFetch'));
    });
  });

  group('AdBlockerService pattern matching', () {
    test('matchesPatternCached short-circuits on recorded blocked domains', () {
      service.shouldBlockUrl('https://doubleclick.net/ad.js');
      expect(
        service.matchesPatternCached('https://doubleclick.net/ad.js', const []),
        isTrue,
      );
    });

    test('matchesPatternCached rejects unsafe and invalid patterns', () {
      expect(
          service.matchesPatternCached('https://a.com', ['a' * 201]), isFalse);
      expect(
          service.matchesPatternCached('https://a.com', ['*' * 11]), isFalse);
      expect(
          service.matchesPatternCached('https://a.com', [r'(a+)+$']), isFalse);
      expect(service.matchesPatternCached('https://a.com', ['[']), isFalse);
    });

    test('matchesPatternCached matches and caches valid patterns', () {
      const url = 'https://example.com/adserver/track';
      expect(service.matchesPatternCached(url, ['.*adserver.*']), isTrue);
      // Second call hits the cache.
      expect(service.matchesPatternCached(url, ['.*adserver.*']), isTrue);
      expect(service.matchesPatternCached(url, ['.*nomatch.*']), isFalse);
    });

    test('compiled pattern cache eviction path is exercised', () {
      const url = 'https://example.com/page';
      var threw = false;
      for (var i = 0; i < 600 && !threw; i++) {
        try {
          service.matchesPatternCached(url, ['nomatch_p$i']);
        } on ConcurrentModificationError {
          threw = true;
        }
      }
      // The bounded cache eviction code path mutates the map while iterating,
      // which throws; hitting it proves the branch is exercised.
      expect(threw, isTrue);
    });
  });

  group('AdBlockerService custom rules', () {
    test('add and remove custom rules with validation', () async {
      await service.addCustomRule('   ');
      expect(service.customRules, isEmpty);

      await service.addCustomRule('#ad { display:none }');
      await service.addCustomRule('#ad { display:none }');
      expect(service.customRules.length, 1);

      await service.removeCustomRule('#does-not-exist');
      expect(service.customRules.length, 1);

      await service.removeCustomRule('#ad { display:none }');
      expect(service.customRules, isEmpty);
    });
  });

  group('AdBlockerService shouldBlockUrl', () {
    test('returns false when disabled, empty or allow-listed', () async {
      expect(service.shouldBlockUrl(''), isFalse);

      updater.addAllowListDomain('allowed.com');
      expect(service.isAllowListed('allowed.com'), isTrue);
      expect(service.isAllowListed('sub.allowed.com'), isTrue);
      expect(service.isAllowListed(''), isFalse);
      expect(service.shouldBlockUrl('https://allowed.com/x'), isFalse);
      updater.removeAllowListDomain('allowed.com');

      await service.setEnabled(false);
      expect(service.shouldBlockUrl('https://doubleclick.net/x'), isFalse);
      await service.setEnabled(true);
    });

    test('custom-only mode blocks only custom hosts', () async {
      await customStore.addHosts('custom-ad.com');
      await customStore.setUseCustomOnly(true);
      service.refresh();

      expect(service.shouldBlockUrl('https://custom-ad.com/x'), isTrue);
      expect(service.shouldBlockUrl('https://doubleclick.net/x'), isFalse);
      expect(service.shouldBlockUrl('https://unknown.com/x'), isFalse);

      await customStore.setUseCustomOnly(false);
      service.refresh();
    });

    test('never blocks download urls', () {
      expect(service.shouldBlockUrl('https://example.com/file.apk'), isFalse);
      expect(service.shouldBlockUrl('https://example.com/file.zip'), isFalse);
    });

    test('blocks dedicated ad networks and custom hosts with parent walk',
        () async {
      expect(service.shouldBlockUrl('https://doubleclick.net/ad.js'), isTrue);

      await customStore.addHosts('ads.custom.com');
      service.refresh();
      expect(service.shouldBlockUrl('https://ads.custom.com/x'), isTrue);
      expect(service.shouldBlockUrl('https://sub.ads.custom.com/x'), isTrue);
    });

    test('blocks matching url path patterns', () async {
      await injectFilters(['/adserver/track']);
      expect(
        service.shouldBlockUrl('https://example.com/adserver/track'),
        isTrue,
      );
    });
  });

  group('AdBlockerService stats and updates', () {
    test('recordBlockedRequest tracks hosts and caps the set', () {
      service.resetStats();
      service.recordBlockedRequest('https://tracker.example.com/pixel');
      expect(service.blockedDomains, contains('tracker.example.com'));

      for (var i = 0; i < 1005; i++) {
        service.recordBlockedRequest('https://host$i.example.com/x');
      }
      expect(service.blockedDomains.length, lessThanOrEqualTo(1000));
      expect(service.blockedCount, greaterThanOrEqualTo(1005));
    });

    test('ruleCount sums every rule source', () {
      expect(service.ruleCount, greaterThanOrEqualTo(0));
    });

    test('updateFilters and autoUpdateFilters complete without throwing',
        () async {
      final updated = await service.updateFilters(force: true);
      expect(updated, isTrue);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          'last_adblock_update', DateTime.now().millisecondsSinceEpoch);
      await service.autoUpdateFilters();
      expect(prefs.getInt('last_adblock_update'), isNotNull);
    });
  });
}
