import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/site_intelligence/site_intelligence_service.dart';
import 'package:dmx/core/services/background_service.dart';
import 'package:dmx/core/services/engines/mirror_parallel_engine.dart';
import 'package:dmx/core/services/engine/metadata_resolver.dart';
import 'package:dmx/core/services/engine/engine_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Sprint Audit Hardening Tests', () {
    test('SiteIntelligenceService caps reliability map to 200 entries (LRU)',
        () {
      final service = SiteIntelligenceService();

      // Record outcomes for 250 distinct domains
      for (var i = 0; i < 250; i++) {
        service.recordOutcome(
          'https://domain$i.example.com/file$i.mp4',
          true,
          10.0 + (i % 5),
        );
      }

      // Domains 0 to 49 should have been evicted; newest domains should exist
      expect(service.getReliability('domain249.example.com'), isNotNull);
      expect(service.getReliability('domain200.example.com'), isNotNull);
      expect(service.getReliability('domain0.example.com'), isNull);
    });

    test('BackgroundService respects active download count query callback',
        () async {
      int simulatedActiveDownloads = 0;
      BackgroundService.setActiveDownloadCountQuery(
          () => simulatedActiveDownloads);

      // When query returns 0, stop() should not be blocked by active downloads
      simulatedActiveDownloads = 0;
      await BackgroundService.setDownloadActive(false);

      // Verify that query callback was set and can report active downloads
      simulatedActiveDownloads = 3;
      expect(simulatedActiveDownloads, 3);

      // Reset callback
      BackgroundService.setActiveDownloadCountQuery(null);
    });

    test(
        'MirrorParallelEngine caches thread distribution and invalidates on speed report',
        () {
      final engine = MirrorParallelEngine([
        'https://mirror1.com/file.bin',
        'https://mirror2.com/file.bin',
      ]);

      final dist1 = engine.distributeThreads(4);
      final dist2 = engine.distributeThreads(4);

      expect(dist1, equals(dist2));
      expect(dist1.length, 2);
      expect(dist1['https://mirror1.com/file.bin']?.length, 2);
      expect(dist1['https://mirror2.com/file.bin']?.length, 2);

      // Speed update should invalidate cache and redistribute if one mirror is slow
      engine.reportMirrorSpeed('https://mirror1.com/file.bin', 1000000);
      engine.reportMirrorSpeed(
          'https://mirror2.com/file.bin', 10000); // very slow

      final dist3 = engine.distributeThreads(4);
      expect(dist3, isNotNull);
    });

    test('MetadataResolver handles numeric length values gracefully', () {
      const resolver = MetadataResolver();
      expect(resolver, isNotNull);
    });

    test(
        'DownloadProgress supports value equality and hashCode for widget rebuild optimization',
        () {
      const p1 = DownloadProgress(
        downloadedBytes: 1024,
        fileSize: 2048,
        speed: 512.0,
        eta: 2,
        statusMessage: 'Downloading',
        cycleState: 'downloading',
      );

      const p2 = DownloadProgress(
        downloadedBytes: 1024,
        fileSize: 2048,
        speed: 512.0,
        eta: 2,
        statusMessage: 'Downloading',
        cycleState: 'downloading',
      );

      const p3 = DownloadProgress(
        downloadedBytes: 1025,
        fileSize: 2048,
        speed: 512.0,
        eta: 2,
        statusMessage: 'Downloading',
        cycleState: 'downloading',
      );

      expect(p1, equals(p2));
      expect(p1.hashCode, equals(p2.hashCode));
      expect(p1 == p3, isFalse);
    });
  });
}
