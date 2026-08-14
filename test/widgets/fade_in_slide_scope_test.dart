import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/shared/widgets/fade_in_slide.dart';

void main() {
  group('FadeInSlideScope Shared Controller (U-08)', () {
    testWidgets('50 items inside FadeInSlideScope share single controller',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FadeInSlideScope(
              child: ListView.builder(
                itemCount: 50,
                itemBuilder: (context, index) {
                  return FadeInSlide(
                    child: Text('Item $index'),
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final states =
          tester.stateList<FadeInSlideState>(find.byType(FadeInSlide)).toList();

      expect(states, isNotEmpty);
      for (final state in states) {
        // Under scope, child states should not instantiate their own local controller
        expect(state.activeLocalController, isNull);
      }

      final scopeStates = tester
          .stateList<FadeInSlideScopeState>(find.byType(FadeInSlideScope))
          .toList();
      expect(scopeStates.length, equals(1));
    });

    testWidgets('Standalone FadeInSlide creates its own local controller',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FadeInSlide(
              child: Text('Standalone'),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final state = tester.state<FadeInSlideState>(find.byType(FadeInSlide));
      expect(state.activeLocalController, isNotNull);
    });
  });
}
