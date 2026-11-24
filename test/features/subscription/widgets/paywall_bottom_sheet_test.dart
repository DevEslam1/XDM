import 'package:dmx/core/app_theme.dart';
import 'package:dmx/core/services/subscription/subscription_service.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/features/subscription/widgets/paywall_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SubscriptionService service;
  late SettingsProvider settings;

  setUp(() {
    settings = SettingsProvider.instance;
    service = SubscriptionService();
  });

  tearDown(() {
    service.dispose();
  });

  Widget wrap({
    String? featureName,
    VoidCallback? onDismiss,
    Widget? home,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SubscriptionService>.value(value: service),
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ],
      child: MaterialApp(
        theme: ThemeData.dark(),
        routes: {
          '/subscription': (_) => const Scaffold(body: Text('SUBSCRIPTION')),
        },
        home: home ??
            Scaffold(
              body: PaywallBottomSheet(
                subscriptionService: service,
                featureName: featureName,
                onDismiss: onDismiss,
              ),
            ),
      ),
    );
  }

  group('PaywallBottomSheet', () {
    testWidgets('renders all plans, popular badge and subscribe CTA',
        (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Monthly'), findsOneWidget);
      expect(find.text('Annual'), findsOneWidget);
      expect(find.text('Lifetime'), findsOneWidget);
      expect(find.text('POPULAR'), findsOneWidget);
      expect(find.text('Subscribe Now'), findsOneWidget);
      expect(find.text('Go Premium'), findsOneWidget);
      expect(find.byIcon(Icons.diamond_rounded), findsOneWidget);
    });

    testWidgets('shows the unlock title when a feature name is supplied',
        (tester) async {
      await tester.pumpWidget(wrap(featureName: 'HD Streaming'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Unlock This Feature'), findsOneWidget);
      expect(find.text('Go Premium'), findsNothing);
    });

    testWidgets('selecting a different plan moves the highlight',
        (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(milliseconds: 300));

      Border borderOf(String label) {
        final container = tester.widget<AnimatedContainer>(find.ancestor(
          of: find.text(label),
          matching: find.byType(AnimatedContainer),
        ));
        final decoration = container.decoration as BoxDecoration;
        return decoration.border as Border;
      }

      expect(borderOf('Annual').top.color, AppTheme.neonCyan);

      await tester.tap(find.text('Monthly'));
      await tester.pump(const Duration(milliseconds: 250));

      expect(borderOf('Monthly').top.color, AppTheme.neonCyan);
      expect(borderOf('Annual').top.color, isNot(AppTheme.neonCyan));
    });

    testWidgets('subscribe pops the sheet and navigates to subscription',
        (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Subscribe Now'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('SUBSCRIPTION'), findsOneWidget);
    });
  });

  group('PaywallBottomSheet.show', () {
    testWidgets('opens as a modal and can be dismissed', (tester) async {
      await tester.pumpWidget(
        wrap(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      PaywallBottomSheet.show(context, featureName: 'x'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Unlock This Feature'), findsOneWidget);

      await tester.tap(find.text('Subscribe Now'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('SUBSCRIPTION'), findsOneWidget);
    });
  });
}
