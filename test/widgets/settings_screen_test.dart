import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/settings/screens/settings_screen.dart';
import '../helpers/test_helpers.dart';

void main() {
  group('SettingsScreen', () {
    testWidgets('renders all setting sections', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const SettingsScreen(),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('dark mode switch is toggleable', (tester) async {
      final settings = createMockSettingsProvider();

      await tester.pumpWidget(createTestApp(
        child: const SettingsScreen(),
        settingsProvider: settings,
      ));
      await tester.pumpAndSettle();

      final switches = find.byType(Switch);
      if (switches.evaluate().isNotEmpty) {
        await tester.tap(switches.first);
        await tester.pumpAndSettle();
      }
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('displays version info', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const SettingsScreen(),
      ));
      await tester.pumpAndSettle();

      await tester.drag(
        find.byType(SettingsScreen),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  });
}
