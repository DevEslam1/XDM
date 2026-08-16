import 'package:dmx/shared/widgets/dmx_backdrop_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DmxBackdropFilter Gating & Fallback (P1-12)', () {
    setUp(() {
      DmxBackdropFilter.resetActiveCount();
      DmxBackdropFilter.disabled = false;
    });

    tearDown(() {
      DmxBackdropFilter.resetActiveCount();
      DmxBackdropFilter.disabled = false;
    });

    testWidgets(
        'enableBlur: false renders static fallback without allocating filter',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DmxBackdropFilter(
              sigmaX: 10,
              sigmaY: 10,
              enableBlur: false,
              child: Text('Fallback Content'),
            ),
          ),
        ),
      );

      expect(DmxBackdropFilter.activeCount, equals(0));
      expect(find.text('Fallback Content'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('enabled: false renders solid fallback without BackdropFilter',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DmxBackdropFilter(
              sigmaX: 10,
              sigmaY: 10,
              enabled: false,
              child: Text('Disabled Blur Content'),
            ),
          ),
        ),
      );

      expect(DmxBackdropFilter.activeCount, equals(0));
      expect(find.text('Disabled Blur Content'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(RepaintBoundary), findsWidgets);
    });
  });
}
