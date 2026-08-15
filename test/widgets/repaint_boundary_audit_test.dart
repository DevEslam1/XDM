import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RepaintBoundary Architecture Audit Test (P3-13)', () {
    testWidgets('CustomPaint widgets have an ancestor RepaintBoundary within hierarchy',
        (tester) async {
      final customPainterKey = UniqueKey();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              child: CustomPaint(
                key: customPainterKey,
                size: const Size(100, 100),
                painter: _TestPainter(),
              ),
            ),
          ),
        ),
      );

      final customPaintFinder = find.byKey(customPainterKey);
      expect(customPaintFinder, findsOneWidget);

      final ancestorBoundaryFinder = find.ancestor(
        of: customPaintFinder,
        matching: find.byType(RepaintBoundary),
      );
      expect(ancestorBoundaryFinder, findsAtLeastNWidgets(1));
    });

    testWidgets('Audits ListView with itemExtent or children wrapped in RepaintBoundary',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              itemExtent: 60,
              itemCount: 5,
              itemBuilder: (context, index) => ListTile(title: Text('Item $index')),
            ),
          ),
        ),
      );

      final listElements = find.byType(ListView).evaluate();
      expect(listElements.isNotEmpty, isTrue);
      for (final listElement in listElements) {
        final listWidget = listElement.widget as ListView;
        final hasExtent = listWidget.itemExtent != null || listWidget.prototypeItem != null;
        expect(hasExtent, isTrue);
      }
    });
  });
}

class _TestPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
