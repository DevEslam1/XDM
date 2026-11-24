import 'package:dmx/core/utils/responsive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('Responsive Layout Helpers', () {
    testWidgets('Phone portrait (390x844) uses single column and single pane',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              expect(isMultiColumnLayout(context), isFalse);
              expect(shouldShowTwoPaneDetails(context), isFalse);
              expect(isTablet(context), isFalse);
              return const SizedBox();
            },
          ),
        ),
      );
    });

    testWidgets(
        'Tablet portrait (768x1024) uses single column and single pane to prevent cramped cards',
        (tester) async {
      tester.view.physicalSize = const Size(768, 1024);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              expect(isMultiColumnLayout(context), isFalse);
              expect(shouldShowTwoPaneDetails(context), isFalse);
              expect(isTablet(context), isTrue);
              return const SizedBox();
            },
          ),
        ),
      );
    });

    testWidgets(
        'Tablet landscape (1024x768) activates multi-column and two-pane details',
        (tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              expect(isMultiColumnLayout(context), isTrue);
              expect(shouldShowTwoPaneDetails(context), isTrue);
              expect(isTablet(context), isTrue);
              return const SizedBox();
            },
          ),
        ),
      );
    });

    testWidgets(
        'Desktop (1440x900) activates multi-column and two-pane details',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              expect(isMultiColumnLayout(context), isTrue);
              expect(shouldShowTwoPaneDetails(context), isTrue);
              expect(isDesktop(context), isTrue);
              return const SizedBox();
            },
          ),
        ),
      );
    });
  });
}
