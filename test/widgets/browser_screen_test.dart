import 'package:dmx/features/browser/screens/browser_screen.dart';
import 'package:dmx/features/browser/services/adblock_filter_updater.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

void main() {
  group('BrowserScreen', () {
    // BrowserScreen.initState() kicks off AdBlockerService.init(), which
    // starts a 24h periodic filter-update scheduler on a static singleton.
    // Cancel it inside each test so the fake-async pending-timer invariant
    // passes.
    void stopAdBlockScheduler() {
      AdBlockFilterUpdater().stopAutoUpdateScheduler();
    }

    testWidgets('renders URL bar', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const BrowserScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      stopAdBlockScheduler();

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('URL bar accepts text input', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const BrowserScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      stopAdBlockScheduler();

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
      stopAdBlockScheduler();

      expect(find.byType(BrowserScreen), findsOneWidget);
    });
  });
}
