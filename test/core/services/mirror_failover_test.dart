import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dmx/core/services/mirror/mirror_selector.dart';
import 'package:dmx/core/services/mirror/mirror_registry.dart';
import 'package:dmx/core/services/protocol_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MirrorFailover & orderMirrorUrls', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await MirrorHealthStore.instance.init();
      await ProtocolCache.init();
    });

    test('initializes with active url and counts alternatives correctly', () {
      final mirrors = [
        'https://mirror1.example.com/file.zip',
        'https://mirror2.example.com/file.zip',
        'https://mirror3.example.com/file.zip',
      ];
      final failover = MirrorFailover(mirrors);

      expect(failover.activeUrl, 'https://mirror1.example.com/file.zip');
      expect(failover.hasAlternatives, true);
      expect(failover.remainingAlternatives, 2);
      expect(failover.mirrorSwitches, 0);
    });

    test('advance switches to next available mirror and increments switches count', () {
      final mirrors = [
        'https://mirror1.example.com/file.zip',
        'https://mirror2.example.com/file.zip',
      ];
      final failover = MirrorFailover(mirrors);

      final next = failover.advance();
      expect(next, isNotNull);
      expect(failover.mirrorSwitches, 1);
    });

    test('orderMirrorUrls places primary mirror first', () {
      final mirrors = [
        'https://mirror2.example.com',
        'https://mirror1.example.com',
        'https://mirror3.example.com',
      ];
      final ordered = orderMirrorUrls(mirrors, primary: 'https://mirror1.example.com');
      expect(ordered.first, 'https://mirror1.example.com');
    });

    test('filters out invalid non-http/https urls', () {
      final rawList = [
        'ftp://ftp.example.com/file',
        'https://secure.example.com/file',
        'invalid-url',
      ];
      final failover = MirrorFailover(rawList);
      expect(failover.activeUrl, 'https://secure.example.com/file');
      expect(failover.hasAlternatives, false);
    });

    test('handles empty mirror list gracefully without throwing', () {
      final failover = MirrorFailover([]);
      expect(failover.activeUrl, '');
      expect(failover.hasAlternatives, false);
      expect(failover.advance(), isNull);
    });
  });
}
