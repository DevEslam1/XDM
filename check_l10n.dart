// ignore_for_file: avoid_print

import 'lib/core/utils/l10n/app_ar.dart';
import 'lib/core/utils/l10n/app_de.dart';
import 'lib/core/utils/l10n/app_en.dart';
import 'lib/core/utils/l10n/app_es.dart';
import 'lib/core/utils/l10n/app_fr.dart';

void main() {
  final files = {
    'en': enTranslations,
    'ar': arTranslations,
    'de': deTranslations,
    'es': esTranslations,
    'fr': frTranslations,
  };

  final enKeys = enTranslations.keys.toSet();
  bool allMatch = true;

  print('=== Translation Key Audit ===');
  print('EN keys: ${enKeys.length}');

  files.forEach((lang, map) {
    if (lang == 'en') return;
    final keys = map.keys.toSet();
    final missingInLang = enKeys.difference(keys);
    final extraInLang = keys.difference(enKeys);

    if (missingInLang.isNotEmpty) {
      allMatch = false;
      print('Missing in $lang (${missingInLang.length}):');
      for (final k in missingInLang) {
        print('  - $k');
      }
    }
    if (extraInLang.isNotEmpty) {
      allMatch = false;
      print('Extra in $lang (${extraInLang.length}):');
      for (final k in extraInLang) {
        print('  - $k');
      }
    }
  });

  if (allMatch) {
    print('All files match English keys perfectly!');
  }

  print('\n=== Alphabetical Sorting Audit ===');
  files.forEach((lang, map) {
    final keys = map.keys.toList();
    final sortedKeys = List<String>.from(keys)..sort();
    bool isSorted = true;
    for (int i = 0; i < keys.length; i++) {
      if (keys[i] != sortedKeys[i]) {
        isSorted = false;
        break;
      }
    }
    print('$lang sorted alphabetically: ${isSorted ? "YES" : "NO"}');
  });
}
