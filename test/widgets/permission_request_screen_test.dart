import 'package:dmx/features/onboarding/screens/permission_request_screen.dart';
import 'package:dmx/shared/widgets/main_navigation_container.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

void main() {
  setUp(() {
    setupTestPluginMocks();
  });

  void drain(WidgetTester tester) {
    while (tester.takeException() != null) {}
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final settings = createMockSettingsProvider();
    await settings.load();
    await settings.setCustomDownloadPath('C:/tmp/xdm');

    await tester.pumpWidget(createTestApp(
      child: const PermissionRequestScreen(),
      settingsProvider: settings,
    ));
    await tester.pump(const Duration(milliseconds: 200));
    drain(tester);
  }

  testWidgets('renders permission cards and continue button', (tester) async {
    await pumpScreen(tester);

    expect(find.byType(PermissionRequestScreen), findsOneWidget);
    expect(find.text('App Permissions'), findsOneWidget);
    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Battery Optimization'), findsOneWidget);
    expect(find.text('Download Location'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsWidgets);
  });

  testWidgets('continue navigates to main navigation container',
      (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    drain(tester);

    expect(find.byType(MainNavigationContainer), findsOneWidget);
  });
}
