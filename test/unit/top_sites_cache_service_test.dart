import 'package:dmx/features/browser/services/top_sites_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TopSitesCacheService Tests', () {
    setUp(() {
      TopSitesCacheService.instance.invalidate();
    });

    test('fetches from loader on cache miss and reuses on cache hit', () async {
      int loadCount = 0;
      Future<List<Map<String, String>>> fakeLoader() async {
        loadCount++;
        return [
          {'title': 'Site A', 'url': 'https://a.com'},
          {'title': 'Site B', 'url': 'https://b.com'},
        ];
      }

      final res1 =
          await TopSitesCacheService.instance.getTopSites(loader: fakeLoader);
      expect(loadCount, equals(1));
      expect(res1.length, equals(2));

      final res2 =
          await TopSitesCacheService.instance.getTopSites(loader: fakeLoader);
      expect(loadCount, equals(1)); // Reused cache
      expect(res2.length, equals(2));
    });

    test('invalidates cache and re-queries loader', () async {
      int loadCount = 0;
      Future<List<Map<String, String>>> fakeLoader() async {
        loadCount++;
        return [
          {'title': 'Site $loadCount', 'url': 'https://$loadCount.com'}
        ];
      }

      await TopSitesCacheService.instance.getTopSites(loader: fakeLoader);
      expect(loadCount, equals(1));

      TopSitesCacheService.instance.invalidate();

      final res2 =
          await TopSitesCacheService.instance.getTopSites(loader: fakeLoader);
      expect(loadCount, equals(2));
      expect(res2.first['title'], equals('Site 2'));
    });

    test('synchronously returns cachedSites when fresh', () async {
      expect(TopSitesCacheService.instance.cachedSites, isEmpty);

      await TopSitesCacheService.instance.getTopSites(
          loader: () async => [
                {'title': 'Sync Site', 'url': 'https://sync.com'},
              ]);

      expect(TopSitesCacheService.instance.cachedSites.length, equals(1));
      expect(TopSitesCacheService.instance.cachedSites.first['title'],
          equals('Sync Site'));
    });
  });
}
