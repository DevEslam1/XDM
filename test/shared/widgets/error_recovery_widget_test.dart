import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/shared/widgets/error_recovery_widget.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // L10n.of(context, ...) resolves the current language through the
  // SettingsProvider, so the widget tree must provide one (as in production).
  Widget wrapWithMaterial(Widget child) {
    return ChangeNotifierProvider<SettingsProvider>.value(
      value: SettingsProvider.instance,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: child),
        ),
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

      expect(find.text('Show error details'), findsOneWidget);
      await tester.tap(find.text('Show error details'));
      await tester.pumpAndSettle();

      expect(find.text('Hide error details'), findsOneWidget);
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
