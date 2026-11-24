import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/core/services/site_intelligence/site_intelligence_service.dart';
import 'package:dmx/core/services/site_intelligence/site_registry.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PowerMonitor.screenOff = false;
    PowerMonitor.isAppForegrounded = true;
  });

  tearDown(() {
    PowerMonitor.screenOff = false;
    PowerMonitor.isAppForegrounded = true;
    SiteRegistry.registry.remove('refsite.test');
  });

  SiteIntelligenceService newService() {
    final service = SiteIntelligenceService();
    addTearDown(service.dispose);
    return service;
  }

  group('analyzeUrl extras', () {
    test('an unparsable url falls back', () {
      final service = newService();
      final result = service.analyzeUrl('http://[invalid');
      expect(result.siteType, SiteType.genericWebpage);
      expect(result.inferredCategory, 'Other');
    });

    test('a referer-requiring profile injects a Referer header', () {
      SiteRegistry.registry['refsite.test'] = const SiteProfile(
        domain: 'refsite.test',
        type: SiteType.fileHosting,
        requiresReferer: true,
      );
      final service = newService();
      final result = service.analyzeUrl('https://refsite.test/file');
      expect(result.recommendedHeaders['Referer'], 'https://refsite.test/');
    });

    test('a profile refererValue overrides the derived referer', () {
      SiteRegistry.registry['refsite.test'] = const SiteProfile(
        domain: 'refsite.test',
        type: SiteType.fileHosting,
        requiresReferer: true,
        refererValue: 'https://custom.example/',
      );
      final service = newService();
      final result = service.analyzeUrl('https://refsite.test/file');
      expect(result.recommendedHeaders['Referer'], 'https://custom.example/');
    });
  });

  group('analyzeMagnet extras', () {
    test('release group and crack keywords are captured', () {
      final service = newService();
      final result = service.analyzeMagnet(
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567'
          '&dn=%5BGROUP%5DSomeGame.Cracked.2020');
      expect(result.contentKeywords, contains('GROUP'));
      expect(result.isSoftware, isTrue);
      expect(result.contentHint, ContentHint.softwarePackage);
    });
  });

  group('_persist gating', () {
    test('skips persistence while backgrounded with the screen off', () {
      PowerMonitor.screenOff = true;
      PowerMonitor.isAppForegrounded = false;
      final service = newService();
      service.recordOutcome('https://bg.example.com/f', true);
      // No flush scheduled; still recordable.
      expect(service.getReliability('bg.example.com'), isNotNull);
    });

    test('flushes immediately at the foreground dirty threshold', () async {
      final service = newService();
      for (var i = 0; i < 5; i++) {
        service.recordOutcome('https://thresh.example.com/f$i', true);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('site_reliability_data'),
          contains('thresh.example.com'));
    });

    test('debounced persist timer flushes after the interval', () {
      fakeAsync((async) {
        final service = SiteIntelligenceService();
        service.recordOutcome('https://debounce.example.com/f', true);
        async.elapse(const Duration(seconds: 61));
        async.flushMicrotasks();
        expect(service.getReliability('debounce.example.com'), isNotNull);
        service.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
