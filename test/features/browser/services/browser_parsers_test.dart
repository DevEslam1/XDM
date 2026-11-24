import 'package:dmx/features/browser/services/adblock_filter_updater.dart';
import 'package:dmx/features/browser/services/filter_line_parser.dart';
import 'package:dmx/features/browser/services/long_press_parser.dart';
import 'package:dmx/features/browser/services/search_engine_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FilterLineParser extra branches', () {
    test('parses hosts-file format, comments and trailing dots', () {
      final res = FilterLineParser.parse([
        '127.0.0.1 ads.example.com # inline comment',
        '0.0.0.0 tracker.net.',
        '127.0.0.1 not_a_domain',
      ], FilterType.ads);

      expect(res.blocked.contains('ads.example.com'), isTrue);
      expect(res.blocked.contains('tracker.net'), isTrue);
      expect(res.blocked.contains('not_a_domain'), isFalse);
    });

    test('skips malformed scriptlet rules', () {
      final unclosed = FilterLineParser.parse(['##+js(set, a'], FilterType.ads);
      expect(unclosed.scriptletRules, isEmpty);

      final unbalanced =
          FilterLineParser.parse(['##+js(set, a, (b)'], FilterType.ads);
      expect(unbalanced.scriptletRules, isEmpty);

      final empty = FilterLineParser.parse(['##+js()'], FilterType.ads);
      expect(empty.scriptletRules, isEmpty);
    });

    test('handles multi-domain and ~exception scriptlet/cosmetic rules', () {
      final scriptlet =
          FilterLineParser.parse(['a.com,b.com##+js(noeval)'], FilterType.ads);
      expect(scriptlet.siteCosmeticRules['a.com']?.contains('noeval'), isTrue);
      expect(scriptlet.siteCosmeticRules['b.com']?.contains('noeval'), isTrue);

      final cosmetic = FilterLineParser.parse(
          ['site.com,~exempt.com##.ad-box'], FilterType.ads);
      expect(
          cosmetic.siteCosmeticRules['site.com']?.contains('.ad-box'), isTrue);
      expect(cosmetic.cosmeticExceptions['exempt.com']?.contains('.ad-box'),
          isTrue);
    });

    test('parses cosmetic exception rules (global and per-site)', () {
      final res = FilterLineParser.parse(
          ['#@#.global-exc', 'site.com#@#.site-exc'], FilterType.ads);
      expect(res.globalCosmeticExceptions.contains('.global-exc'), isTrue);
      expect(res.cosmeticExceptions['site.com']?.contains('.site-exc'), isTrue);
    });

    test('ignores overly long cosmetic selectors', () {
      final longSelector = '##.${'a' * 150}';
      final res = FilterLineParser.parse([longSelector], FilterType.ads);
      expect(res.cosmeticRules, isEmpty);
    });

    test('ABP domain rule without a dot is ignored', () {
      final res = FilterLineParser.parse(['||localhost^'], FilterType.ads);
      expect(res.blocked, isEmpty);
    });

    test('plain domains support inline comments and trailing dots', () {
      final res = FilterLineParser.parse(
          ['plain.com # comment', 'dotted.org.'], FilterType.ads);
      expect(res.blocked.contains('plain.com'), isTrue);
      expect(res.blocked.contains('dotted.org'), isTrue);
    });

    test('URL path patterns are parsed and filtered', () {
      final res = FilterLineParser.parse([
        '/adserver/track',
        '/ads/*',
        '/\$popup',
        '/regex/',
        '/abc',
        '/downloads/file',
        '/static/app',
      ], FilterType.ads);

      expect(res.urlPatterns.contains('/adserver/track'), isTrue);
      expect(res.exactPathPatterns.contains('/adserver/track'), isTrue);
      expect(res.urlPatterns.contains('/ads/*'), isTrue);
      expect(res.exactPathPatterns.contains('/ads/*'), isFalse);
      expect(res.urlPatterns.contains('/\$popup'), isFalse);
      expect(res.urlPatterns.contains('/regex/'), isFalse);
      expect(res.urlPatterns.contains('/abc'), isFalse);
      expect(res.urlPatterns.contains('/downloads/file'), isFalse);
      expect(res.urlPatterns.contains('/static/app'), isFalse);
    });

    test('skips empty and over-long lines', () {
      final tooLong = 'a' * (FilterLineParser.maxLineLength + 1);
      final res =
          FilterLineParser.parse(['', tooLong, 'valid.com'], FilterType.ads);
      expect(res.blocked.contains('valid.com'), isTrue);
    });
  });

  group('LongPressPayload extra branches', () {
    test('decodes nested quoted and list payloads', () {
      final nested =
          LongPressPayload.tryParse('"{\\"url\\":\\"https://a.com/x\\"}"');
      expect(nested?.url, 'https://a.com/x');

      final list = LongPressPayload.tryParse('[1,2,3]');
      expect(list, isNull);
    });

    test('invalid inner JSON falls back to stripping quotes', () {
      final payload =
          LongPressPayload.tryParse('"{\\"url\\": \\"https://a.com/y\\"}"');
      expect(payload?.url, 'https://a.com/y');
    });

    test('handles malformed quoted and brace payloads', () {
      expect(LongPressPayload.tryParse('""a"'), isNull);
      expect(LongPressPayload.tryParse('{bad'), isNull);
    });
  });

  group('MediaSourceItem and filterSourcesForTarget', () {
    test('MediaSourceItem.fromMap reads label/src/url/type with defaults', () {
      final item = MediaSourceItem.fromMap(
          {'label': '720p', 'src': 'https://a.com/v.mp4', 'type': 'video'});
      expect(item.label, '720p');
      expect(item.url, 'https://a.com/v.mp4');
      expect(item.type, 'video');

      final fromUrl = MediaSourceItem.fromMap({'url': 'https://a.com/u.mp4'});
      expect(fromUrl.url, 'https://a.com/u.mp4');
      expect(fromUrl.label, '');
      expect(fromUrl.type, 'video');

      final empty = MediaSourceItem.fromMap({});
      expect(empty.label, '');
      expect(empty.url, '');
      expect(empty.type, 'video');
    });

    test('keeps target first and same-type/same-host alternatives', () {
      final sources = [
        const MediaSourceItem(
            label: '720p', url: 'https://cdn.com/video/720.mp4', type: 'video'),
        const MediaSourceItem(
            label: '1080p',
            url: 'https://cdn.com/video/1080.mp4',
            type: 'video'),
        const MediaSourceItem(
            label: 'audio', url: 'https://other.com/a.mp3', type: 'audio'),
        const MediaSourceItem(label: '', url: '', type: 'video'),
      ];

      final result = filterSourcesForTarget(
          sources, 'https://cdn.com/video/360.mp4', 'video');

      expect(result.length, 3);
      expect(result.first.url, 'https://cdn.com/video/360.mp4');
      expect(result.first.label, 'Direct video');
      expect(
          result.map((e) => e.url),
          containsAll([
            'https://cdn.com/video/720.mp4',
            'https://cdn.com/video/1080.mp4'
          ]));
    });

    test('default labels depend on media type', () {
      expect(
          filterSourcesForTarget([], 'https://a.com/a.mp3', 'audio')
              .first
              .label,
          'Direct audio');
      expect(
          filterSourcesForTarget([], 'https://a.com/a.png', 'image')
              .first
              .label,
          'Direct image');
      expect(filterSourcesForTarget([], 'https://a.com/a', 'link').first.label,
          'Direct link');
    });

    test('malformed urls are handled without throwing', () {
      final result = filterSourcesForTarget(const [], 'http://[', 'video');
      expect(result.length, 1);
      expect(result.first.url, 'http://[');
    });
  });

  group('SearchEngineConfig Tests', () {
    test('prefixFor returns matching engine or Google fallback', () {
      expect(SearchEngineConfig.prefixFor('Bing'),
          'https://www.bing.com/search?q=');
      expect(SearchEngineConfig.prefixFor('DuckDuckGo'),
          'https://duckduckgo.com/?q=');
      expect(SearchEngineConfig.prefixFor('Unknown'),
          SearchEngineConfig.engines.first.searchUrlPrefix);
    });

    test('isValid recognizes known engines only', () {
      expect(SearchEngineConfig.isValid('Google'), isTrue);
      expect(SearchEngineConfig.isValid('Startpage'), isTrue);
      expect(SearchEngineConfig.isValid('Nope'), isFalse);
    });
  });
}
