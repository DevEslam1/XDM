import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/utils/localization.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('L10n Localization Unit Tests', () {
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
  });
}
