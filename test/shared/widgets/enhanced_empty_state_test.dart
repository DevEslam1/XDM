import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/shared/widgets/enhanced_empty_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrapWithMaterial(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: child,
      ),
    );
  }

  group('EnhancedEmptyState', () {
    testWidgets('Renders noDownloads preset correctly with CTA button',
        (tester) async {
      var clicked = false;
      final widget = EnhancedEmptyState.noDownloads(
        onAddDownload: () => clicked = true,
      );

      await tester.pumpWidget(wrapWithMaterial(widget));
      await tester.pumpAndSettle();

      expect(find.text('No Downloads Yet'), findsOneWidget);
      expect(find.text('Add Download'), findsOneWidget);

      await tester.tap(find.text('Add Download'));
      expect(clicked, isTrue);
    });

    testWidgets('Renders noSearchResults preset correctly', (tester) async {
      final widget = EnhancedEmptyState.noSearchResults();

      await tester.pumpWidget(wrapWithMaterial(widget));
      await tester.pumpAndSettle();

      expect(find.text('No Matching Results'), findsOneWidget);
    });
  });
}
