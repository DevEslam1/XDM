import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/utils/localization.dart';
import 'package:dmx/core/utils/l10n/app_en.dart';
import 'package:dmx/core/utils/l10n/app_ar.dart';
import 'package:dmx/core/utils/l10n/app_de.dart';
import 'package:dmx/core/utils/l10n/app_es.dart';
import 'package:dmx/core/utils/l10n/app_fr.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('L10n Localization Unit Tests', () {
    test('CI Lint: All keys in app_en.dart exist in AR, DE, ES, FR with non-empty values', () {
      final otherLocales = <String, Map<String, String>>{
        'ar': arTranslations,
        'de': deTranslations,
        'es': esTranslations,
        'fr': frTranslations,
      };

      for (final enKey in enTranslations.keys) {
        for (final entry in otherLocales.entries) {
          final locName = entry.key;
          final map = entry.value;
          expect(
            map.containsKey(enKey),
            isTrue,
            reason: 'Missing key "$enKey" in locale "$locName"',
          );
          expect(
            map[enKey]?.trim().isNotEmpty,
            isTrue,
            reason: 'Empty string value for key "$enKey" in locale "$locName"',
          );
        }
      }
    });

    test('L10n.translate translates keys across EN, AR, ES, FR, DE', () {
      expect(L10n.translate('en', 'title_transmissions'), equals('Downloads'));
      expect(L10n.translate('ar', 'title_transmissions'), equals('التنزيلات'));
      expect(L10n.translate('es', 'title_transmissions'), equals('Descargas'));
      expect(L10n.translate('fr', 'title_transmissions'),
          equals('Téléchargements'));
      expect(L10n.translate('de', 'title_transmissions'), equals('Downloads'));
    });

    test('L10n falls back to English when key is missing in target locale', () {
      final res = L10n.translate('es', 'unknown_key_xyz');
      expect(res, equals('unknown_key_xyz'));
    });

    test('Parameterized string substitution works for dynamic values', () {
      final res5 = L10n.translate('en', 'delete_downloads_count', args: {'count': 5});
      expect(res5, equals('Delete 5 Downloads?'));

      final resAr = L10n.translate('ar', 'delete_downloads_count', args: {'count': 3});
      expect(resAr, equals('حذف 3 تنزيل؟'));
    });

    test('Plural / singular rules work correctly for count = 0, 1, 2, 100', () {
      final singular = L10n.translate('en', 'items_count_plural', args: {'count': 1});
      expect(singular, equals('1 item'));

      final plural0 = L10n.translate('en', 'items_count_plural', args: {'count': 0});
      expect(plural0, equals('0 items'));

      final plural2 = L10n.translate('en', 'items_count_plural', args: {'count': 2});
      expect(plural2, equals('2 items'));

      final plural100 = L10n.translate('en', 'items_count_plural', args: {'count': 100});
      expect(plural100, equals('100 items'));
    });
  });
}
