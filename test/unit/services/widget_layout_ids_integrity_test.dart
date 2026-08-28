import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Widget Layout XML & Kotlin ID Integrity Tests [W-11 & W-12]', () {
    test(
        'DMXRemoteViewsFactory layout references match widget_dashboard.xml IDs dynamically',
        () {
      final factoryFile = File(
          'android/app/src/main/kotlin/com/xdm/downloadmanager/widget/DMXRemoteViewsFactory.kt');
      expect(factoryFile.existsSync(), isTrue);
      final factoryKotlin = factoryFile.readAsStringSync();

      final dashLayoutFile =
          File('android/app/src/main/res/layout/widget_dashboard.xml');
      expect(dashLayoutFile.existsSync(), isTrue);
      final dashXml = dashLayoutFile.readAsStringSync();

      // Extract all R.id.widget_dash_* referenced in Kotlin factory
      final dashIdRegex = RegExp(r'R\.id\.(widget_dash_[a-zA-Z0-9_]+)');
      final matchedIds =
          dashIdRegex.allMatches(factoryKotlin).map((m) => m.group(1)!).toSet();

      expect(matchedIds.isNotEmpty, isTrue);

      for (final id in matchedIds) {
        expect(
          dashXml.contains('@+id/$id') || dashXml.contains('@id/$id'),
          isTrue,
          reason:
              'Dynamic Kotlin ID R.id.$id must exist in widget_dashboard.xml',
        );
      }
    });

    test(
        'DMXRemoteViewsFactory layout references match widget_list.xml IDs dynamically',
        () {
      final factoryFile = File(
          'android/app/src/main/kotlin/com/xdm/downloadmanager/widget/DMXRemoteViewsFactory.kt');
      expect(factoryFile.existsSync(), isTrue);
      final factoryKotlin = factoryFile.readAsStringSync();

      final listLayoutFile =
          File('android/app/src/main/res/layout/widget_list.xml');
      expect(listLayoutFile.existsSync(), isTrue);
      final listXml = listLayoutFile.readAsStringSync();

      final listIdRegex = RegExp(r'R\.id\.(widget_list_[a-zA-Z0-9_]+)');
      final matchedIds =
          listIdRegex.allMatches(factoryKotlin).map((m) => m.group(1)!).toSet();

      for (final id in matchedIds) {
        expect(
          listXml.contains('@+id/$id') || listXml.contains('@id/$id'),
          isTrue,
          reason: 'Dynamic Kotlin ID R.id.$id must exist in widget_list.xml',
        );
      }
    });

    test('WidgetFormatters.kt exists and contains pure formatting methods', () {
      final formattersFile = File(
          'android/app/src/main/kotlin/com/xdm/downloadmanager/widget/WidgetFormatters.kt');
      expect(formattersFile.existsSync(), isTrue);
      final content = formattersFile.readAsStringSync();
      expect(content.contains('fun sizeClassFromWidth'), isTrue);
      expect(content.contains('fun formatSpeed'), isTrue);
      expect(content.contains('fun formatBytes'), isTrue);
      expect(content.contains('fun formatSmartEta'), isTrue);
    });
  });
}
