import 'package:dmx/shared/widgets/error_recovery_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrapWithMaterial(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    );
  }

  group('ErrorRecoveryWidget', () {
    testWidgets('Displays categorized error message and retry button',
        (tester) async {
      var retried = false;
      final widget = ErrorRecoveryWidget(
        error: Exception('Network connection reset'),
        onRetry: () => retried = true,
      );

      await tester.pumpWidget(wrapWithMaterial(widget));
      await tester.pumpAndSettle();

      expect(find.text('NETWORK'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      expect(retried, isTrue);
    });

    testWidgets('Toggles expandable error details', (tester) async {
      final widget = ErrorRecoveryWidget(
        error: Exception('Detailed stack failure info'),
      );

      await tester.pumpWidget(wrapWithMaterial(widget));
      await tester.pumpAndSettle();

      expect(find.text('Show Error Details'), findsOneWidget);
      await tester.tap(find.text('Show Error Details'));
      await tester.pumpAndSettle();

      expect(find.text('Hide Error Details'), findsOneWidget);
      expect(find.textContaining('Detailed stack failure info'), findsWidgets);
    });

    testWidgets('Renders compact mode cleanly', (tester) async {
      final widget = ErrorRecoveryWidget(
        error: Exception('Disk space insufficient'),
        compact: true,
      );

      await tester.pumpWidget(wrapWithMaterial(widget));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.storage_rounded), findsOneWidget);
    });
  });
}
