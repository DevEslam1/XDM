import 'package:dmx/features/onboarding/screens/onboarding_screen.dart';
import 'package:dmx/features/onboarding/screens/permission_request_screen.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/shared/widgets/neon_glow_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

void main() {
  setUp(() {
    setupTestPluginMocks();
    // Disable the button's shimmer overlay so it doesn't intercept taps.
    NeonGlowButton.enabled = false;
  });

  tearDown(() {
    NeonGlowButton.enabled = true;
  });

  Future<SettingsProvider> pumpOnboarding(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final settings = createMockSettingsProvider();
    await settings.load();
    await settings.setCustomDownloadPath('C:/tmp/xdm');
    await settings.setShowOnboarding(true);

    await tester.pumpWidget(createTestApp(
      child: const OnboardingScreen(),
      settingsProvider: settings,
    ));
    // Ambient particle/pulse animations never settle by design.
    await tester.pump(const Duration(milliseconds: 300));
    return settings;
  }

  testWidgets('renders first page with controls', (tester) async {
    await pumpOnboarding(tester);

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.text('Make it yours'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
    expect(find.text('1/5'), findsOneWidget);
  });

  testWidgets('Next advances through all pages to Get started', (tester) async {
    await pumpOnboarding(tester);

    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('Next'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('${i + 2}/5'), findsOneWidget);
    }

    expect(find.text('Get started'), findsOneWidget);
    expect(find.text('5/5'), findsOneWidget);
    expect(find.text('Smart control'), findsOneWidget);
  });

  testWidgets('Get started disables onboarding and navigates', (tester) async {
    final settings = await pumpOnboarding(tester);

    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('Next'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
    }

    await tester.tap(find.text('Get started'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(settings.showOnboarding, isFalse);
    expect(find.byType(PermissionRequestScreen), findsOneWidget);
  });

  testWidgets('Skip disables onboarding and navigates', (tester) async {
    final settings = await pumpOnboarding(tester);

    await tester.tap(find.text('Skip'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(settings.showOnboarding, isFalse);
    expect(find.byType(PermissionRequestScreen), findsOneWidget);
  });

  testWidgets('swiping the PageView advances the page', (tester) async {
    await pumpOnboarding(tester);

    await tester.fling(
      find.byType(PageView),
      const Offset(-600, 0),
      1200,
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('2/5'), findsOneWidget);
  });
}
