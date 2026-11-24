import 'dart:convert';

import 'package:dmx/core/services/site_intelligence/site_intelligence_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  SiteIntelligenceService newService() {
    final service = SiteIntelligenceService();
    addTearDown(service.dispose);
    return service;
  }

  group('analyzeUrl', () {
    test('empty input yields a generic fallback', () {
      final service = newService();
      final result = service.analyzeUrl('   ');
      expect(result.siteType, SiteType.genericWebpage);
      expect(result.inferredCategory, 'Other');
      expect(result.confidence, 0.5);
    });

    test('magnet links are routed to magnet analysis', () {
      final service = newService();
      final result = service.analyzeUrl(
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567');
      expect(result.siteType, SiteType.magnetSource);
      expect(result.recommendedStrategy, DownloadStrategy.magnetDht);
      expect(result.confidence, 1.0);
    });

    test('known site profile is matched (YouTube)', () {
      final service = newService();
      final result = service.analyzeUrl('https://www.youtube.com/watch?v=abc');
      expect(result.siteType, SiteType.videoStreaming);
      expect(result.profile?.domain, 'youtube.com');
      expect(result.recommendedStrategy, DownloadStrategy.apiExtraction);
      expect(result.confidence, 0.9);
    });

    test('urls without a scheme get https prepended', () {
      final service = newService();
      final result = service.analyzeUrl('example.com/file.mp4');
      expect(result.detectedFileName, 'file.mp4');
      expect(result.detectedExtension, '.mp4');
    });

    test('generic direct content hints by extension', () {
      final service = newService();
      final cases = {
        'https://v.example.com/a.mp4': ContentHint.videoFile,
        'https://a.example.com/a.mp3': ContentHint.audioFile,
        'https://z.example.com/a.zip': ContentHint.archiveFile,
        'https://e.example.com/a.exe': ContentHint.softwarePackage,
        'https://d.example.com/a.pdf': ContentHint.document,
        'https://i.example.com/a.png': ContentHint.image,
      };
      cases.forEach((url, hint) {
        final result = service.analyzeUrl(url);
        expect(result.siteType, SiteType.genericDirect, reason: url);
        expect(result.contentHint, hint, reason: url);
        expect(result.confidence, 0.7, reason: url);
      });
    });

    test('generic webpage when there is no extension', () {
      final service = newService();
      final result = service.analyzeUrl('https://h.example.com/some/page');
      expect(result.siteType, SiteType.genericWebpage);
      expect(result.contentHint, ContentHint.unknown);
      expect(result.confidence, 0.4);
    });

    test('quality marker and expiry parameter are detected', () {
      final service = newService();
      final result = service
          .analyzeUrl('https://h.example.com/movie.1080p.mkv?token=deadbeef');
      expect(result.detectedQuality?.toLowerCase(), '1080p');
      expect(result.isExpiredOrSigned, isTrue);
    });

    test('host fast-path cache returns consistent results', () {
      final service = newService();
      final first = service.analyzeUrl('https://cache.example.com/file.bin');
      final second = service.analyzeUrl('https://cache.example.com/other.bin');
      expect(second.siteType, first.siteType);
      expect(second.recommendedStrategy, first.recommendedStrategy);
      service.clearFastPathCache();
    });

    test('ftp scheme is preserved rather than mangled', () {
      final service = newService();
      final result = service.analyzeUrl('ftp://files.example.com/a.bin');
      expect(result.siteType, SiteType.genericDirect);
      expect(result.detectedFileName, 'a.bin');
    });

    test('analyzeUrl after dispose returns fallback', () async {
      final service = SiteIntelligenceService();
      await service.dispose();
      expect(service.analyzeUrl('https://example.com/a.mp4').siteType,
          SiteType.genericWebpage);
    });
  });

  group('analyzeMagnet', () {
    test('parses name, hash, trackers and quality tiers', () {
      final service = newService();
      const magnet =
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567'
          '&dn=Movie.2021.1080p.x265.WEB-DL.GROUP'
          '&tr=udp%3A%2F%2Ft1%2Fa&tr=udp%3A%2F%2Ft2%2Fa&tr=udp%3A%2F%2Ft3%2Fa'
          '&tr=udp%3A%2F%2Ft4%2Fa&tr=udp%3A%2F%2Ft5%2Fa';
      final result = service.analyzeMagnet(magnet);
      expect(result.infoHash, '0123456789abcdef0123456789abcdef01234567');
      expect(result.trackerCount, 5);
      expect(result.quality, MagnetQuality.excellent);
      expect(result.displayName, contains('Movie.2021'));
      expect(result.inferredQuality?.toLowerCase(), '1080p');
      expect(result.contentHint, ContentHint.videoFile);
      expect(result.isVideoContent, isTrue);
    });

    test('audio content is detected from codec/extension', () {
      final service = newService();
      final result = service.analyzeMagnet(
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567'
          '&dn=Album.flac&tr=udp%3A%2F%2Ft1');
      expect(result.contentHint, ContentHint.audioFile);
      expect(result.isAudioContent, isTrue);
      expect(result.quality, MagnetQuality.fair);
    });

    test('software content is detected from extension/keywords', () {
      final service = newService();
      final result = service.analyzeMagnet(
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567'
          '&dn=SomeApp.setup.repack.exe&tr=udp%3A%2F%2Ft1'
          '&tr=udp%3A%2F%2Ft2&tr=udp%3A%2F%2Ft3');
      expect(result.contentHint, ContentHint.softwarePackage);
      expect(result.isSoftware, isTrue);
      expect(result.quality, MagnetQuality.good);
    });

    test('a bare magnet with no trackers is poor quality', () {
      final service = newService();
      final result = service.analyzeMagnet(
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567');
      expect(result.quality, MagnetQuality.poor);
      expect(result.contentHint, ContentHint.unknown);
      expect(result.trackerCount, 0);
    });
  });

  group('resolveCategory', () {
    test('prefers content hints', () {
      final service = newService();
      expect(
          service.resolveCategory(
              url: 'x', contentHint: ContentHint.videoStream),
          'Video');
      expect(
          service.resolveCategory(url: 'x', contentHint: ContentHint.audioFile),
          'Audio');
      expect(
          service.resolveCategory(
              url: 'x', contentHint: ContentHint.archiveFile),
          'Archive');
      expect(
          service.resolveCategory(
              url: 'x', contentHint: ContentHint.softwarePackage),
          'Software');
      expect(
          service.resolveCategory(url: 'x', contentHint: ContentHint.document),
          'Document');
      expect(service.resolveCategory(url: 'x', contentHint: ContentHint.image),
          'Image');
    });

    test('falls back to site type then keyword search', () {
      final service = newService();
      expect(
          service.resolveCategory(url: 'x', siteType: SiteType.videoStreaming),
          'Video');
      expect(
          service.resolveCategory(url: 'x', siteType: SiteType.audioStreaming),
          'Audio');
      expect(service.resolveCategory(url: 'the.movie.1080p'), 'Video');
      expect(service.resolveCategory(url: 'some.flac.album'), 'Audio');
      expect(service.resolveCategory(url: 'app.setup.exe'), 'Software');
      expect(service.resolveCategory(url: 'my.pdf.ebook'), 'Document');
    });

    test('falls back to extension then Other', () {
      final service = newService();
      expect(service.resolveCategory(url: 'x', fileName: 'a.zip'), 'Archive');
      expect(service.resolveCategory(url: 'x', fileName: 'a.png'), 'Image');
      expect(service.resolveCategory(url: 'x', fileName: 'a.unknown'), 'Other');
      expect(service.resolveCategory(url: 'x'), 'Other');
    });
  });

  group('analyzeUrlsBatch', () {
    test('empty list returns empty', () async {
      final service = newService();
      expect(await service.analyzeUrlsBatch([]), isEmpty);
    });

    test('small list analyzes inline', () async {
      final service = newService();
      final results = await service.analyzeUrlsBatch(
          ['https://a.example.com/f.mp4', 'https://b.example.com/f.mp3']);
      expect(results, hasLength(2));
    });

    test('large list analyzes through compute', () async {
      final service = newService();
      final urls =
          List.generate(6, (i) => 'https://h$i.example.com/file$i.mp4');
      final results = await service.analyzeUrlsBatch(urls);
      expect(results, hasLength(6));
    });
  });

  group('reliability tracking + persistence', () {
    test('recordOutcome tracks success, failure and speed', () {
      final service = newService();
      service.recordOutcome('https://s.example.com/a', true, 10);
      service.recordOutcome('https://s.example.com/a', true, 20);
      service.recordOutcome('https://s.example.com/a', false, null, 'timeout');

      final stat = service.getReliability('S.EXAMPLE.COM');
      expect(stat, isNotNull);
      expect(stat!.totalAttempts, 3);
      expect(stat.successes, 2);
      expect(stat.failures, 1);
      expect(stat.lastError, 'timeout');
      expect(stat.score, 67);
      expect(stat.averageSpeedMbps, greaterThan(10));
    });

    test('recordOutcome ignores invalid or hostless urls', () {
      final service = newService();
      service.recordOutcome('not a url', true);
      service.recordOutcome('', true);
      expect(service.getReliability('not a url'), isNull);
    });

    test('getReliability returns null for unknown hosts', () {
      final service = newService();
      expect(service.getReliability('unknown.example.com'), isNull);
    });

    test('LRU evicts beyond the configured cap', () {
      final service = newService();
      for (var i = 0; i <= SiteIntelligenceService.maxReliabilityEntries; i++) {
        service.recordOutcome('https://h$i.example.com/f', true);
      }
      expect(service.getReliability('h0.example.com'), isNull);
    });

    test('init loads persisted reliability data', () async {
      SharedPreferences.setMockInitialValues({
        'site_reliability_data': jsonEncode({
          'loaded.example.com': {
            'domain': 'loaded.example.com',
            'totalAttempts': 4,
            'successes': 3,
            'failures': 1,
            'averageSpeedMbps': 5.0,
          },
        }),
      });
      final service = newService();
      await service.init();
      final stat = service.getReliability('loaded.example.com');
      expect(stat, isNotNull);
      expect(stat!.totalAttempts, 4);
      expect(stat.successes, 3);
    });

    test('init tolerates malformed persistence data', () async {
      SharedPreferences.setMockInitialValues({
        'site_reliability_data': 'not-json',
      });
      final service = newService();
      await service.init();
      expect(service.getReliability('anything'), isNull);
    });

    test('flushPending persists the reliability map', () async {
      final service = newService();
      service.recordOutcome('https://flush.example.com/f', true);
      await service.flushPending();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('site_reliability_data'),
          contains('flush.example.com'));
    });

    test('onMemoryPressure clears the fast-path cache and flushes', () {
      final service = newService();
      service.analyzeUrl('https://m.example.com/f.bin');
      service.onMemoryPressure();
    });

    test('SiteReliability serializes round-trip', () {
      final stat = SiteReliability(
        domain: 'd',
        totalAttempts: 2,
        successes: 1,
        failures: 1,
        averageSpeedMbps: 3.5,
        lastSuccess: DateTime(2024),
        lastFailure: DateTime(2024),
        lastError: 'e',
      );
      final restored = SiteReliability.fromJson(stat.toJson());
      expect(restored.domain, 'd');
      expect(restored.totalAttempts, 2);
      expect(restored.averageSpeedMbps, 3.5);
      expect(restored.lastError, 'e');
      expect(SiteReliability(domain: 'x').score, 100);
    });
  });
}
