import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/shared/widgets/pausable_loop_animation.dart';
import 'package:dmx/shared/widgets/dmx_backdrop_filter.dart';

void main() {
  group('PausableLoopAnimation Widget (U-03)', () {
    testWidgets('renders child and loops animation', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PausableLoopAnimation(
              duration: const Duration(seconds: 1),
              builder: (context, value, child) {
                return Opacity(
                  opacity: value,
                  child: const Text('Looping Text'),
                );
              },
            ),
          ),
        ),
      );

      expect(find.text('Looping Text'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Looping Text'), findsOneWidget);
    });
  });

  group('DmxBackdropFilter Widget (U-04)', () {
    testWidgets('falls back to Container with forceSolid true', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DmxBackdropFilter(
              sigmaX: 10,
              sigmaY: 10,
              forceSolid: true,
              child: Text('Backdrop Content'),
            ),
          ),
        ),
      );

      expect(find.text('Backdrop Content'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(Container), findsWidgets);
    });
  });
}
