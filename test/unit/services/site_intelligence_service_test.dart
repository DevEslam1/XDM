import 'package:dmx/core/services/site_intelligence/site_intelligence_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SiteIntelligenceService Tests', () {
    late SiteIntelligenceService service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service = SiteIntelligenceService();
      service.clearFastPathCache();
    });

    tearDown(() async {
      await service.dispose();
    });

    test('analyzeUrl uses fast path cache for matching host+extension', () {
      const url1 = 'https://speed.hetzner.de/100MB.bin';
      final res1 = service.analyzeUrl(url1);

      expect(res1.detectedExtension, equals('.bin'));
      expect(res1.detectedFileName, equals('100MB.bin'));

      const url2 = 'https://speed.hetzner.de/1GB.bin';
      final res2 = service.analyzeUrl(url2);

      expect(res2.detectedExtension, equals('.bin'));
      expect(res2.detectedFileName, equals('1GB.bin'));
      expect(res2.siteType, equals(res1.siteType));
    });

    test('analyzeUrlsBatch processes small batch on main thread', () async {
      final service = SiteIntelligenceService();
      final urls = [
        'https://example.com/file1.zip',
        'https://example.com/file2.mp4',
        'https://example.com/file3.pdf',
      ];

      final results = await service.analyzeUrlsBatch(urls);
      expect(results.length, equals(3));
      expect(results[0].detectedExtension, equals('.zip'));
      expect(results[1].detectedExtension, equals('.mp4'));
      expect(results[2].detectedExtension, equals('.pdf'));
    });

    test('analyzeUrlsBatch processes large batch (>5 URLs) via isolate',
        () async {
      final service = SiteIntelligenceService();
      final urls = List.generate(
        8,
        (i) => 'https://example.com/archive_$i.tar.gz',
      );

      final results = await service.analyzeUrlsBatch(urls);
      expect(results.length, equals(8));
      for (int i = 0; i < 8; i++) {
        expect(results[i].detectedFileName, equals('archive_$i.tar.gz'));
      }
    });
  });
}
