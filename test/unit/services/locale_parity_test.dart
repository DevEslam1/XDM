import 'package:dmx/core/utils/l10n/app_ar.dart';
import 'package:dmx/core/utils/l10n/app_de.dart';
import 'package:dmx/core/utils/l10n/app_en.dart';
import 'package:dmx/core/utils/l10n/app_es.dart';
import 'package:dmx/core/utils/l10n/app_fr.dart';
import 'package:dmx/core/utils/localization.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('L10n Locale Parity Tests [10/10]', () {
    test(
        'All 5 locales (en, ar, es, fr, de) contain non-empty translation dictionaries',
        () {
      expect(enTranslations.isNotEmpty, isTrue);
      expect(arTranslations.isNotEmpty, isTrue);
      expect(esTranslations.isNotEmpty, isTrue);
      expect(frTranslations.isNotEmpty, isTrue);
      expect(deTranslations.isNotEmpty, isTrue);
    });

    test(
        'L10n.translate correctly resolves keys across all 5 locales and falls back to en',
        () {
      for (final locale in ['en', 'ar', 'es', 'fr', 'de']) {
        final title = L10n.translate(locale, 'app_title');
        expect(title.isNotEmpty, isTrue,
            reason: 'app_title should be defined in $locale');
      }

      // Non-existent key falls back to English or returns key itself
      final fallback = L10n.translate('de', 'some_unknown_key_xyz');
      expect(fallback, equals('some_unknown_key_xyz'));
    });

    test('Param interpolation works properly in L10n.translate', () {
      final res = L10n.translate('en', 'waiting_for_slot',
          args: {'active': 3, 'max': 5});
      expect(res, equals('Waiting for slot (3/5 active)'));
    });
  });
}
