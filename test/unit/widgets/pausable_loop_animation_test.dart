import 'package:dmx/shared/widgets/dmx_backdrop_filter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
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
      expect(find.byType(ColoredBox), findsWidgets);
    });
  });
}
