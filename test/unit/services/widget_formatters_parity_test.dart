import 'dart:convert';
import 'dart:io';

import 'package:dmx/core/services/widget_data_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Widget Formatters Fixture & Parity Tests [Widget layer 10/10]', () {
    late Map<String, dynamic> fixture;

    setUpAll(() {
      final file = File('test/fixtures/widget_formatters.json');
      expect(file.existsSync(), isTrue);
      fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    });

    test('calculateSpeedTrend accurately calculates trends', () {
      expect(WidgetDataBridge.calculateSpeedTrend([]), equals('stable'));
      expect(WidgetDataBridge.calculateSpeedTrend([1000]), equals('stable'));
      expect(WidgetDataBridge.calculateSpeedTrend([1000, 1200]), equals('up'));
      expect(WidgetDataBridge.calculateSpeedTrend([1000, 800]), equals('down'));
      expect(
          WidgetDataBridge.calculateSpeedTrend([1000, 1050]), equals('stable'));
    });

    test('calculateEta and formatEta produce user-friendly strings', () {
      expect(WidgetDataBridge.calculateEta(0, 1000), isNull);
      expect(WidgetDataBridge.calculateEta(1000, 0), isNull);
      expect(WidgetDataBridge.calculateEta(1000, 1000), equals(1));

      expect(WidgetDataBridge.formatEta(null), equals('--'));
      expect(WidgetDataBridge.formatEta(0), equals('--'));
      expect(WidgetDataBridge.formatEta(30), equals('Almost done'));
      expect(WidgetDataBridge.formatEta(120), equals('~2 min'));
      expect(WidgetDataBridge.formatEta(3600), equals('~1h'));
      expect(WidgetDataBridge.formatEta(3660), equals('~1h 1m'));
    });

    test('isStorageLow and isStorageCritical thresholds validate boundaries',
        () {
      expect(WidgetDataBridge.isStorageLow(-1), isFalse);
      expect(WidgetDataBridge.isStorageLow(600 * 1024 * 1024), isFalse);
      expect(WidgetDataBridge.isStorageLow(400 * 1024 * 1024), isTrue);

      expect(WidgetDataBridge.isStorageCritical(-1), isFalse);
      expect(WidgetDataBridge.isStorageCritical(200 * 1024 * 1024), isFalse);
      expect(WidgetDataBridge.isStorageCritical(50 * 1024 * 1024), isTrue);
    });

    test('Fixture sizeClasses test data matches size categorization rules', () {
      final sizeClasses =
          (fixture['sizeClasses'] as List).cast<Map<String, dynamic>>();
      for (final sc in sizeClasses) {
        final width = sc['minWidthDp'] as int;
        final expected = sc['expected'] as String;
        final computed = width < 250
            ? 'mini'
            : width < 400
                ? 'wide'
                : width < 550
                    ? 'list'
                    : 'dashboard';
        expect(computed, equals(expected));
      }
    });
  });
}
