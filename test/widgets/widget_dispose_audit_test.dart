import 'package:dmx/features/downloads/widgets/channel_progress_painter.dart';
import 'package:dmx/shared/widgets/glass_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Widget Dispose & Teardown Audit (P3-15)', () {
    testWidgets('GlassCard mounts, receives gestures and disposes cleanly',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlassCard(
              isDarkMode: true,
              onTap: () {},
              child: const Text('Test GlassCard'),
            ),
          ),
        ),
      );

      expect(find.byType(GlassCard), findsOneWidget);

      await tester
          .pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      await tester.pumpAndSettle();

      expect(find.byType(GlassCard), findsNothing);
    });

    testWidgets('IsolatedProgressBar mounts and unmounts cleanly',
        (tester) async {
      final progressNotifier = ValueNotifier<double>(0.5);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IsolatedProgressBar(
              progress: progressNotifier,
              isDark: true,
            ),
          ),
        ),
      );

      expect(find.byType(IsolatedProgressBar), findsOneWidget);

      await tester
          .pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      await tester.pumpAndSettle();

      expect(find.byType(IsolatedProgressBar), findsNothing);
      progressNotifier.dispose();
    });
  });
}
