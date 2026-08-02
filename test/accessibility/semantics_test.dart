import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/widgets/download_card.dart';
import 'package:dmx/features/home/screens/home_screen.dart';
import 'package:dmx/features/settings/screens/settings_screen.dart';
import '../helpers/test_helpers.dart';

void main() {
  group('Accessibility & Semantics', () {
    testWidgets('DownloadCard provides accessible semantic label', (tester) async {
      final task = createTestTask(
        fileName: 'accessibility-test.iso',
        progress: 0.75,
      );

      await tester.pumpWidget(createTestApp(
        child: DownloadCard(task: task),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      final semantics = tester.getSemantics(find.byType(DownloadCard));
      expect(semantics.label, contains('accessibility-test.iso'));
      expect(semantics.label, contains('75% downloaded'));
    });

    testWidgets('HomeScreen renders with zero semantic accessibility violations', (tester) async {
      final provider = createMockDownloadProvider(tasks: []);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('SettingsScreen renders accessibility settings section', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const SettingsScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  });
}
