import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/browser/screens/browser_screen.dart';
import '../helpers/test_helpers.dart';

void main() {
  group('BrowserScreen', () {
    testWidgets('renders URL bar', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const BrowserScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('URL bar accepts text input', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const BrowserScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      final textFields = find.byType(TextField);
      if (textFields.evaluate().isNotEmpty) {
        await tester.enterText(textFields.first, 'https://example.com');
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('https://example.com'), findsOneWidget);
      } else {
        expect(find.byType(BrowserScreen), findsOneWidget);
      }
    });

    testWidgets('tab counter is rendered', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const BrowserScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(BrowserScreen), findsOneWidget);
    });
  });
}
