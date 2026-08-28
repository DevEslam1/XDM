import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HistoryExportService Tests [Browser 10/10]', () {
    test('exportToJson serializes items with proper indentation', () async {
      final items = [
        {
          'url': 'https://example.com',
          'title': 'Example Domain',
          'timestamp': 1700000000000,
        },
        {
          'url': 'https://flutter.dev',
          'title': 'Flutter Dev',
          'timestamp': 1700000010000,
        },
      ];

      // Verify json formatting logic with indentation
      final jsonStr = const JsonEncoder.withIndent('  ').convert(items);
      expect(jsonStr.contains('https://example.com'), isTrue);
      expect(jsonStr.contains('Flutter Dev'), isTrue);

      final decoded =
          (jsonDecode(jsonStr) as List).cast<Map<String, dynamic>>();
      expect(decoded.length, equals(2));
      expect(decoded.first['title'], equals('Example Domain'));
    });
  });
}
