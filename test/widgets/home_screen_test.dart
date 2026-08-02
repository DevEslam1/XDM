import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/home/screens/home_screen.dart';
import '../helpers/test_helpers.dart';

void main() {
  group('HomeScreen', () {
    testWidgets('renders home screen widget', (tester) async {
      final provider = createMockDownloadProvider(tasks: []);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('renders active tasks list when tasks are provided', (tester) async {
      final provider = createMockDownloadProvider(
        tasks: createMixedTaskList(),
      );

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('ubuntu.iso'), findsOneWidget);
    });

    testWidgets('FAB is visible on home screen', (tester) async {
      final provider = createMockDownloadProvider(tasks: []);

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('pull to refresh does not crash', (tester) async {
      final provider = createMockDownloadProvider(
        tasks: createMixedTaskList(),
      );

      await tester.pumpWidget(createTestApp(
        child: const HomeScreen(),
        downloadProvider: provider,
      ));
      await tester.pumpAndSettle();

      await tester.drag(
        find.byType(HomeScreen),
        const Offset(0, 300),
      );
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });
}
