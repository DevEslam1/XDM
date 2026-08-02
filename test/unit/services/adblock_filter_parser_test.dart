import 'dart:io';
import 'package:dmx/features/browser/services/adblock_filter_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Adblock Filter Parser Tests', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('adblock_parser_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('parses EasyList format rules correctly', () async {
      final file = File(p.join(tempDir.path, 'filter.txt'));
      await file.writeAsString('''
! This is a comment - should be ignored
[Adblock Plus 2.0]
||example.com^
||ads.tracking.org^
@@||allowed-domain.com^
##.ad-banner
##div[class="advertisement"]
/ads/banner/
/pixel/track
''');

      final updater = AdBlockFilterUpdater();
      await updater.init();

      final parsedDomains = await updater.parseFilterFile(file, FilterType.ads);

      // Verify domain blocking
      expect(parsedDomains.contains('example.com'), isTrue);
      expect(parsedDomains.contains('ads.tracking.org'), isTrue);

      // Verify cosmetic rules
      expect(updater.cosmeticRules.contains('.ad-banner'), isTrue);
      expect(updater.cosmeticRules.contains('div[class="advertisement"]'), isTrue);

      // Verify URL pattern rules
      expect(updater.urlPatterns.contains('/ads/banner/'), isTrue);
      expect(updater.urlPatterns.contains('/pixel/track'), isTrue);
    });

    test('handles exception rules (@@)', () async {
      final file = File(p.join(tempDir.path, 'filter_exceptions.txt'));
      await file.writeAsString('''
||block-me.com^
@@||block-me.com^
''');

      final updater = AdBlockFilterUpdater();
      await updater.init();

      final parsedDomains = await updater.parseFilterFile(file, FilterType.ads);

      // Since the exception rule comes after (or gets processed), the domain should be removed/absent
      expect(parsedDomains.contains('block-me.com'), isFalse);
    });
  });
}
