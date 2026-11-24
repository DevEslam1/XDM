import 'package:dmx/core/services/site_intelligence/site_intelligence_service.dart';
import 'package:dmx/core/services/site_intelligence/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SiteRegistry', () {
    test('contains representative domains and valid profiles', () {
      expect(SiteRegistry.registry, isNotEmpty);
      for (final entry in SiteRegistry.registry.entries) {
        expect(entry.value.domain, entry.key,
            reason: 'profile domain must match its key');
      }
    });

    test('well-known profiles carry expected attributes', () {
      final youtube = SiteRegistry.registry['youtube.com']!;
      expect(youtube.type, SiteType.videoStreaming);
      expect(youtube.requiresCookies, isTrue);
      expect(youtube.urlsExpire, isTrue);

      final github = SiteRegistry.registry['github.com']!;
      expect(github.strategy, DownloadStrategy.multiThread);
      expect(github.supportsRangeRequests, isTrue);
    });
  });
}
