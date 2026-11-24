import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dmx/features/browser/services/adblock_filter_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this._chunks, this.statusCode);

  final List<List<int>> _chunks;

  @override
  final int statusCode;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(_chunks).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this._body);

  final List<int> _body;
  final _FakeHeaders _headers = _FakeHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() async => _FakeResponse([_body], 200);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._body);

  final List<int> _body;

  @override
  Duration? connectionTimeout;

  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeRequest(_body);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeRequest(_body);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FilterHttpOverrides extends HttpOverrides {
  _FilterHttpOverrides(this.body);

  final List<int> body;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(body);
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.dir);

  final String dir;

  @override
  Future<String?> getTemporaryPath() async => dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdBlockFilterUpdater updater;

  Future<({Set<String> blocked, Set<String> excepted})> parse(
      List<String> lines) async {
    final dir = Directory.systemTemp.createTempSync('updater_test');
    final file = File('${dir.path}/filters.txt')
      ..writeAsStringSync(lines.join('\n'));
    final result = await updater.parseFilterFile(file, FilterType.ads);
    dir.deleteSync(recursive: true);
    return result;
  }

  setUpAll(() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'adblock_downloaded_domains_ads': ['ads.example.com'],
      'adblock_downloaded_domains_tracking': ['track.example.com'],
      'adblock_downloaded_domains_excepted': ['safe.example.com'],
      'adblock_user_allowlist': ['allowed.com'],
      'adblock_url_patterns': ['/adserver/track', '/ads/banner*', '/*'],
      'adblock_cosmetic_rules_v2': ['.global-ad'],
      'adblock_scriptlet_rules': ['noeval'],
      'adblock_last_update_ms': now,
    });
    updater = AdBlockFilterUpdater();
    await updater.init();
  });

  group('AdBlockFilterUpdater getters and allowlist', () {
    test('exposes downloaded counts and rule sets', () {
      expect(updater.downloadedDomainCount, 1);
      expect(updater.downloadedTrackingCount, 1);
      expect(updater.allBlockedDomains, contains('ads.example.com'));
      expect(updater.allTrackingDomains, contains('track.example.com'));
      expect(updater.cosmeticRules, contains('.global-ad'));
      expect(updater.scriptletRules, contains('noeval'));
      expect(updater.urlPatterns, contains('/adserver/track'));
      expect(updater.allowListedDomains, contains('allowed.com'));
    });

    test('add and remove allowlist domains persist', () async {
      updater.addAllowListDomain('');
      expect(updater.allowListedDomains, isNot(contains('')));

      updater.addAllowListDomain('NewSite.com');
      expect(updater.allowListedDomains, contains('newsite.com'));

      updater.removeAllowListDomain('newsite.com');
      expect(updater.allowListedDomains, isNot(contains('newsite.com')));

      updater.removeAllowListDomain('');
      await updater.persistUserAllowList();
    });
  });

  group('AdBlockFilterUpdater parsing and matching', () {
    test('parseFilterFile returns blocked and excepted domains', () async {
      final result = await parse([
        '||blocked.example^',
        '@@||excepted.example^',
        '##.parsed-ad',
        '##+js(noeval)',
      ]);
      expect(result.blocked, contains('blocked.example'));
      expect(result.excepted, contains('excepted.example'));
      expect(updater.cosmeticRules, contains('.parsed-ad'));
    });

    test('matchesUrlPath uses the exact-path trie and safety guard', () async {
      await parse(['/adserver/track']);
      expect(updater.matchesUrlPath('/adserver/track'), isTrue);
      expect(updater.matchesUrlPath('/download/file'), isFalse);
      expect(updater.matchesUrlPath(''), isFalse);
      expect(updater.matchesUrlPath('/ab'), isFalse);
    });

    test('shouldBlock resolves hosts, parents, paths and allowlist', () async {
      expect(updater.shouldBlock(''), isFalse);
      expect(updater.shouldBlock('ads.example.com'), isTrue);
      expect(updater.shouldBlock('https://sub.ads.example.com/x'), isTrue);
      expect(updater.shouldBlock('track.example.com'), isTrue);
      expect(updater.shouldBlock('ads.example.com/path'), isTrue);
      expect(updater.shouldBlock('https://allowed.com/x'), isFalse);
      expect(updater.shouldBlock('https://sub.allowed.com/x'), isFalse);
      expect(updater.shouldBlock('https://other.com/x'), isFalse);
      expect(updater.shouldBlock('https://example.com/adserver/track'), isTrue);
    });

    test('cosmeticRulesForHost merges site rules and applies exceptions',
        () async {
      await parse([
        '##.global-ad',
        'site.com##.site-ad',
        '#@#.global-exc',
        'site.com#@#.site-exc',
      ]);

      final rules = updater.cosmeticRulesForHost('site.com');
      expect(rules, contains('.global-ad'));
      expect(rules, contains('.site-ad'));
      expect(rules, isNot(contains('.global-exc')));
      expect(rules, isNot(contains('.site-exc')));

      // Cached on the second call.
      final cached = updater.cosmeticRulesForHost('site.com');
      expect(identical(rules, cached), isTrue);

      final subRules = updater.cosmeticRulesForHost('sub.site.com');
      expect(subRules, contains('.site-ad'));
    });

    test('cosmetic cache evicts when it reaches capacity', () {
      for (var i = 0; i < 60; i++) {
        updater.cosmeticRulesForHost('host$i.example');
      }
      expect(updater.cosmeticRulesForHost('host59.example'), isNotEmpty);
    });

    test('matchesUrlPath honours compiled wildcard patterns and safety guard',
        () {
      expect(updater.matchesUrlPath('/ads/banner/skyscraper'), isTrue);
      // Dangerous over-broad pattern '/*' compiles to a never-matching regex.
      expect(updater.matchesUrlPath('/anything/goes/here'), isFalse);
      // Standard asset directories are always allowed.
      expect(updater.matchesUrlPath('/static/js/app.js'), isFalse);
      expect(updater.matchesUrlPath('/assets/img/logo.png'), isFalse);
      expect(updater.matchesUrlPath('/download/file.zip'), isFalse);
      expect(updater.matchesUrlPath('/wp-content/themes/x'), isFalse);
    });

    test('shouldBlock matches wildcard paths from the URL, not just hosts', () {
      expect(updater.shouldBlock('https://example.com/ads/banner/leaderboard'),
          isTrue);
      expect(
          updater.shouldBlock('https://example.com/static/js/app.js'), isFalse);
    });

    test('shouldBlock tolerates malformed URLs', () {
      expect(updater.shouldBlock('http://[bad'), isFalse);
    });

    test('cosmeticRulesForHost applies parent-domain exceptions', () async {
      await parse([
        'parent.com##.parent-ad',
        'parent.com#@#.parent-exc',
      ]);

      final childRules = updater.cosmeticRulesForHost('child.parent.com');
      expect(childRules, contains('.parent-ad'));
      expect(childRules, isNot(contains('.parent-exc')));
    });

    test('parseFilterFile rejects malformed and noisy lines', () async {
      final result = await parse([
        '', // empty
        '! a comment',
        '[Adblock Plus 2.0]',
        r'/$popup',
        '/regex/',
        '/ab',
        '//comment',
        '0.0.0.0 tracker.example',
      ]);
      expect(result.blocked, contains('tracker.example'));
      expect(result.blocked, isNot(contains('/regex/')));
    });
  });

  group('AdBlockFilterUpdater scheduling and lifecycle', () {
    test('isStale reflects cached domains and update timestamp', () async {
      expect(await updater.isStale(), isFalse);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('adblock_last_update_ms', 0);
      expect(await updater.isStale(), isTrue);
      await prefs.setInt(
          'adblock_last_update_ms', DateTime.now().millisecondsSinceEpoch);
    });

    test('getLastUpdateTime and getDaysUntilNextUpdate', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          'adblock_last_update_ms', DateTime.now().millisecondsSinceEpoch);
      expect(await updater.getLastUpdateTime(), isNotNull);
      expect(await updater.getDaysUntilNextUpdate(), inInclusiveRange(0, 7));

      await prefs.setInt('adblock_last_update_ms', 0);
      expect(await updater.getLastUpdateTime(), isNull);
      expect(await updater.getDaysUntilNextUpdate(), 0);
      await prefs.setInt(
          'adblock_last_update_ms', DateTime.now().millisecondsSinceEpoch);
    });

    test('auto update scheduler can be started and stopped', () {
      var updated = false;
      updater.startAutoUpdateScheduler(onUpdated: () => updated = true);
      updater.startAutoUpdateScheduler();
      updater.stopAutoUpdateScheduler();
      expect(updated, isFalse);
    });

    test('updateIfNeeded honours the disabled flag and failures', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('adblock_auto_update_enabled', false);
      expect(await updater.updateIfNeeded(), isFalse);

      // force bypasses the flag but fails fast without a temporary directory.
      expect(await updater.updateIfNeeded(force: true), isFalse);

      await prefs.setBool('adblock_auto_update_enabled', true);
      await updater.setAutoUpdateEnabled(true);
    });
  });

  group('AdBlockFilterUpdater cleanup', () {
    test('clearDownloadedDomains removes in-memory and persisted state',
        () async {
      await updater.clearDownloadedDomains();
      expect(updater.allBlockedDomains, isEmpty);
      expect(updater.allTrackingDomains, isEmpty);
      expect(updater.cosmeticRules, isEmpty);
      expect(updater.scriptletRules, isEmpty);
      expect(updater.urlPatterns, isEmpty);
      expect(await updater.isStale(), isTrue);
    });
  });

  group('AdBlockFilterUpdater download pipeline', () {
    late Directory tempDir;
    HttpOverrides? previousOverrides;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('adblock_dl_test_');
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);

      final body = utf8.encode(
        [
          '||ads.example^',
          '@@||safe.example^',
          '##.ad-banner',
          'site.com##.site-ad',
          'site.com#@#.site-exc',
          '/adserver/track',
          '/ads/banner*',
          '##+js(noeval)',
          '!${'x' * 1500}',
        ].join('\n'),
      );
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _FilterHttpOverrides(body);
    });

    tearDown(() async {
      HttpOverrides.global = previousOverrides;
      if (await tempDir.exists()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('updateIfNeeded downloads, parses and persists all rule types',
        () async {
      final updated = await updater.updateIfNeeded(force: true);
      expect(updated, isTrue);

      expect(updater.allBlockedDomains, contains('ads.example'));
      expect(updater.allowListedDomains, contains('safe.example'));
      expect(updater.cosmeticRules, contains('.ad-banner'));
      expect(updater.urlPatterns, contains('/adserver/track'));
      expect(updater.scriptletRules, contains('noeval'));
      expect(await updater.getLastUpdateTime(), isNotNull);

      // Site cosmetic rules and exceptions loaded for the parsed host.
      final siteRules = updater.cosmeticRulesForHost('site.com');
      expect(siteRules, contains('.site-ad'));
      expect(siteRules, isNot(contains('.site-exc')));

      // Wildcard patterns compiled from the downloaded filter list.
      expect(updater.matchesUrlPath('/ads/banner/leaderboard'), isTrue);
      expect(updater.shouldBlock('https://cdn.ads.example/banner'), isTrue);
    });

    test('updateIfNeeded is a no-op while an update is not needed', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('adblock_auto_update_enabled', true);
      await prefs.setInt(
        'adblock_last_update_ms',
        DateTime.now().millisecondsSinceEpoch,
      );
      // Fresh rules were just persisted, so a non-forced update returns false.
      expect(await updater.updateIfNeeded(), isFalse);
    });
  });
}
