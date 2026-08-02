import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/downloads/widgets/download_card.dart';
import 'package:dmx/features/home/screens/home_screen.dart';
import 'package:dmx/features/settings/screens/settings_screen.dart';
import '../helpers/test_helpers.dart';

void main() {
  group('RTL Layout', () {
    testWidgets('DownloadCard renders correctly in RTL', (tester) async {
      final task = createTestTask();

      await tester.pumpWidget(createTestApp(
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: DownloadCard(task: task),
        ),
        locale: const Locale('ar'),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(find.byType(DownloadCard), findsOneWidget);
    });

    testWidgets('HomeScreen renders correctly in RTL', (tester) async {
      final provider = createMockDownloadProvider(
        tasks: createMixedTaskList(),
      );

      await tester.pumpWidget(createTestApp(
        child: const Directionality(
          textDirection: TextDirection.rtl,
          child: HomeScreen(),
        ),
        downloadProvider: provider,
        locale: const Locale('ar'),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
    });

    testWidgets('Settings renders correctly in RTL', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const Directionality(
          textDirection: TextDirection.rtl,
          child: SettingsScreen(),
        ),
        locale: const Locale('ar'),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
    });
  });

  group('Text Scaling', () {
    testWidgets('DownloadCard handles 2x text scale', (tester) async {
      final task = createTestTask();

      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: createTestApp(
          child: DownloadCard(task: task),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
    });

    testWidgets('HomeScreen handles 1.5x text scale', (tester) async {
      final provider = createMockDownloadProvider(
        tasks: createMixedTaskList(),
      );

      await tester.binding.setSurfaceSize(const Size(800, 1200));

      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: createTestApp(
          child: const HomeScreen(),
          downloadProvider: provider,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
    });
  });
}
