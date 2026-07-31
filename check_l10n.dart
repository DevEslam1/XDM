// ignore_for_file: avoid_print

import 'lib/core/utils/l10n/app_en.dart';
import 'lib/core/utils/l10n/app_ar.dart';

void main() {
  final enKeys = enTranslations.keys.toSet();
  final arKeys = arTranslations.keys.toSet();
  final missingInAr = enKeys.difference(arKeys);
  final missingInEn = arKeys.difference(enKeys);
  print('EN keys: ${enKeys.length}');
  print('AR keys: ${arKeys.length}');
  if (missingInAr.isNotEmpty) {
    print('Missing in AR (${missingInAr.length}):');
    for (final k in missingInAr) {
      print('  - $k');
    }
  }
  if (missingInEn.isNotEmpty) {
    print('Missing in EN (${missingInEn.length}):');
    for (final k in missingInEn) {
      print('  - $k');
    }
  }
  if (missingInAr.isEmpty && missingInEn.isEmpty) {
    print('All keys match!');
  }
}
