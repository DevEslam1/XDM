import 'package:dmx/features/browser/services/ad_blocker_service.dart';
import 'package:dmx/features/browser/services/adblock_filter_updater.dart';
import 'package:dmx/features/browser/services/filter_line_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AdBlockerService.isSameSite and getRegistrableDomain', () {
    test('identifies same-site across subdomains', () {
      expect(AdBlockerService.isSameSite('m.example.com', 'static.example.com'), isTrue);
      expect(AdBlockerService.isSameSite('assets.example.com', 'example.com'), isTrue);
      expect(AdBlockerService.isSameSite('cdn.example.com', 'www.example.com'), isTrue);
      expect(AdBlockerService.isSameSite('api.example.com', 'app.example.com'), isTrue);
    });

    test('handles two-part public suffix TLDs', () {
      expect(AdBlockerService.isSameSite('news.bbc.co.uk', 'static.bbc.co.uk'), isTrue);
      expect(AdBlockerService.isSameSite('news.bbc.co.uk', 'bbc.co.uk'), isTrue);
      expect(AdBlockerService.isSameSite('abc.com.au', 'static.abc.com.au'), isTrue);
      expect(AdBlockerService.isSameSite('abc.com.au', 'xyz.com.au'), isFalse);
    });

    test('rejects different sites', () {
      expect(AdBlockerService.isSameSite('example.com', 'different.com'), isFalse);
      expect(AdBlockerService.isSameSite('google.com', 'doubleclick.net'), isFalse);
      expect(AdBlockerService.isSameSite('', 'example.com'), isFalse);
    });

    test('getRegistrableDomain extracts root domains correctly', () {
      expect(AdBlockerService.getRegistrableDomain('example.com'), 'example.com');
      expect(AdBlockerService.getRegistrableDomain('sub.example.com'), 'example.com');
      expect(AdBlockerService.getRegistrableDomain('a.b.c.example.com'), 'example.com');
      expect(AdBlockerService.getRegistrableDomain('news.bbc.co.uk'), 'bbc.co.uk');
      expect(AdBlockerService.getRegistrableDomain(''), '');
    });
  });

  group('AdBlockFilterUpdater path matching safety', () {
    final updater = AdBlockFilterUpdater.instance;

    test('does not match standard web asset paths', () {
      expect(updater.matchesUrlPath('/assets/vendor/main.js'), isFalse);
      expect(updater.matchesUrlPath('/static/css/style.css'), isFalse);
      expect(updater.matchesUrlPath('/dist/bundle.js'), isFalse);
      expect(updater.matchesUrlPath('/vendor/lodash.min.js'), isFalse);
      expect(updater.matchesUrlPath('/wp-content/themes/theme.css'), isFalse);
      expect(updater.matchesUrlPath('/wp-includes/js/jquery.js'), isFalse);
      expect(updater.matchesUrlPath('/chunks/app-4ad8.js'), isFalse);
    });

    test('does not match download paths', () {
      expect(updater.matchesUrlPath('/download/app.apk'), isFalse);
      expect(updater.matchesUrlPath('/dl/item.zip'), isFalse);
      expect(updater.matchesUrlPath('/getfile/file.pdf'), isFalse);
    });

    test('rejects path strings that are too short', () {
      expect(updater.matchesUrlPath(''), isFalse);
      expect(updater.matchesUrlPath('/ad'), isFalse);
      expect(updater.matchesUrlPath('/pop'), isFalse);
    });
  });

  group('FilterLineParser path rule safeguards', () {
    test('excludes common web asset keywords from urlPatterns', () {
      final lines = [
        '/assets/main.js',
        '/static/theme.css',
        '/vendor/bootstrap.js',
        '/plugin/slider.js',
        '/widget/carousel.js',
        '/module/loader.js',
        '/script/app.js',
        '/style/base.css',
        '/admin/login.js',
        '/adaptive_stream.m3u8',
        '/build/output.js',
        '/dist/bundle.js',
        '/adserver/banner.png', // Legit ad pattern
      ];

      final result = FilterLineParser.parse(lines, FilterType.ads);
      expect(result.urlPatterns, contains('/adserver/banner.png'));
      expect(result.urlPatterns.contains('/assets/main.js'), isFalse);
      expect(result.urlPatterns.contains('/static/theme.css'), isFalse);
      expect(result.urlPatterns.contains('/vendor/bootstrap.js'), isFalse);
      expect(result.urlPatterns.contains('/plugin/slider.js'), isFalse);
      expect(result.urlPatterns.contains('/widget/carousel.js'), isFalse);
      expect(result.urlPatterns.contains('/admin/login.js'), isFalse);
      expect(result.urlPatterns.contains('/adaptive_stream.m3u8'), isFalse);
    });
  });
}
