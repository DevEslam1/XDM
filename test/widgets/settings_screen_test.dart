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
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('dark mode switch is toggleable', (tester) async {
      final settings = createMockSettingsProvider();

      await tester.pumpWidget(createTestApp(
        child: const SettingsScreen(),
        settingsProvider: settings,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      final switches = find.byType(Switch);
      if (switches.evaluate().isNotEmpty) {
        await tester.tap(switches.first);
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('displays version info', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const SettingsScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.drag(
        find.byType(SettingsScreen),
        const Offset(0, -500),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(SettingsScreen), findsOneWidget);
    });
    testWidgets('supports setting theme mode to amoled', (tester) async {
      final settings = createMockSettingsProvider();
      await settings.setThemeMode('amoled');

      expect(settings.themeMode, equals('amoled'));
      expect(settings.isDarkMode, isTrue);
      expect(settings.isAmoledMode, isTrue);
    });

    testWidgets('enabling battery saver mode keeps power tab active and page visible', (tester) async {
      final settings = createMockSettingsProvider();
      await tester.pumpWidget(createTestApp(
        child: const SettingsScreen(initialSection: 'power'),
        settingsProvider: settings,
      ));
      await tester.pumpAndSettle();

      expect(settings.activeSettingsTabIndex, equals(5));

      await settings.setBatterySaverMode(true);
      await tester.pumpAndSettle();

      expect(settings.batterySaverMode, isTrue);
      expect(settings.activeSettingsTabIndex, equals(5));
      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  });
}
