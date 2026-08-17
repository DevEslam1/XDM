import 'package:dmx/features/browser/services/adblock_filter_updater.dart';
import 'package:dmx/features/browser/services/filter_line_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FilterLineParser Tests', () {
    test('Parses network blocking ABP domain rules', () {
      final lines = ['||doubleclick.net^', '||ads.google.com^'];
      final res = FilterLineParser.parse(lines, FilterType.ads);

      expect(res.blocked.contains('doubleclick.net'), isTrue);
      expect(res.blocked.contains('ads.google.com'), isTrue);
    });

    test('Parses exception rules', () {
      final lines = ['@@||whitelist.com^'];
      final res = FilterLineParser.parse(lines, FilterType.ads);

      expect(res.excepted.contains('whitelist.com'), isTrue);
    });

    test('Parses cosmetic and site cosmetic rules', () {
      final lines = ['example.com##.ad-banner', '##.global-ad'];
      final res = FilterLineParser.parse(lines, FilterType.ads);

      expect(res.siteCosmeticRules['example.com']?.contains('.ad-banner'), isTrue);
      expect(res.cosmeticRules.contains('.global-ad'), isTrue);
    });

    test('Parses scriptlet rules with balanced parentheses (B27)', () {
      final lines = [
        'example.com##+js(set-constant, canRunAds, true)',
        '##+js(abort-on-property-read, I10c)',
      ];
      final res = FilterLineParser.parse(lines, FilterType.ads);

      expect(res.siteCosmeticRules['example.com']?.contains('set-constant, canRunAds, true'), isTrue);
      expect(res.scriptletRules.contains('abort-on-property-read, I10c'), isTrue);
    });

    test('Parentheses balance validator', () {
      expect(FilterLineParser.areParensBalanced('##+js(set, a, (b))'), isTrue);
      expect(FilterLineParser.areParensBalanced('##+js(set, a, (b)'), isFalse);
      expect(FilterLineParser.areParensBalanced(')('), isFalse);
    });

    test('Ignores comment lines and metadata', () {
      final lines = ['! This is a comment', '[Adblock Plus 2.0]', '# Comment line'];
      final res = FilterLineParser.parse(lines, FilterType.ads);

      expect(res.blocked.isEmpty, isTrue);
      expect(res.cosmeticRules.isEmpty, isTrue);
      expect(res.scriptletRules.isEmpty, isTrue);
    });
  });
}
