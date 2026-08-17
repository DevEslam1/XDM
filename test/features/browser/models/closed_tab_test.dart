import 'package:dmx/features/browser/models/closed_tab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClosedTab Model Tests', () {
    test('JSON serialization round-trip', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final original = ClosedTab(
        url: 'https://dart.dev',
        title: 'Dart programming language',
        closedAt: nowMs,
        isIncognito: false,
      );

      final map = original.toMap();
      final fromMap = ClosedTab.fromMap(map);

      expect(fromMap.url, original.url);
      expect(fromMap.title, original.title);
      expect(fromMap.isIncognito, original.isIncognito);
      expect(fromMap.closedAt, original.closedAt);
    });

    test('Equality and hashCode', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final tab1 = ClosedTab(url: 'https://a.com', title: 'A', closedAt: nowMs);
      final tab2 = ClosedTab(url: 'https://a.com', title: 'A', closedAt: nowMs);

      expect(tab1, equals(tab2));
      expect(tab1.hashCode, equals(tab2.hashCode));
    });
  });
}
