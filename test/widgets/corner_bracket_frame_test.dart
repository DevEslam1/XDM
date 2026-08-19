import 'package:dmx/shared/widgets/corner_bracket_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CornerBracketFrame Widget Tests', () {
    testWidgets('renders child inside RepaintBoundary with custom painter',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CornerBracketFrame(
              color: Colors.cyan,
              bracketSize: 12.0,
              strokeWidth: 1.5,
              child: Text('Frame Content'),
            ),
          ),
        ),
      );

      expect(find.text('Frame Content'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(CornerBracketFrame),
          matching: find.byType(RepaintBoundary),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(CornerBracketFrame),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
    });
  });
}
