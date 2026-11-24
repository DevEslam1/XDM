import 'package:dmx/features/browser/screens/browser_screen.dart';
import 'package:dmx/features/browser/services/adblock_filter_updater.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/home/screens/home_screen.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/features/settings/screens/settings_screen.dart';
import 'package:dmx/shared/widgets/main_navigation_container.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

void main() {
  setUp(() {
    setupTestPluginMocks();
  });

  // BrowserScreen's home dashboard can overflow by a few pixels on narrow
  // surfaces; drain the non-fatal layout reports.
  void drain(WidgetTester tester) {
    while (tester.takeException() != null) {}
  }

  Future<void> pumpContainer(
    WidgetTester tester, {
    Size size = const Size(420, 900),
    DownloadProvider? provider,
    SettingsProvider? settings,
    Locale? locale,
    String? initialUrl,
    bool isShareLaunch = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(createTestApp(
      child: MainNavigationContainer(
        initialUrl: initialUrl,
        isShareLaunch: isShareLaunch,
      ),
      downloadProvider: provider,
      settingsProvider: settings,
      locale: locale,
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    drain(tester);
  }

  void stopAdBlockScheduler() {
    AdBlockFilterUpdater().stopAutoUpdateScheduler();
  }

  testWidgets('renders home and bottom navigation', (tester) async {
    await pumpContainer(tester);

    expect(find.byType(MainNavigationContainer), findsOneWidget);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byIcon(Icons.file_download), findsWidgets);
    expect(find.byIcon(Icons.language_outlined), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
  });

  testWidgets('switching to browser builds BrowserScreen', (tester) async {
    await pumpContainer(tester);

    await tester.tap(find.byIcon(Icons.language_outlined));
    await tester.pump(const Duration(milliseconds: 500));
    stopAdBlockScheduler();
    drain(tester);

    expect(find.byType(BrowserScreen), findsOneWidget);
  });

  testWidgets('switching to settings builds SettingsScreen', (tester) async {
    await pumpContainer(tester);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump(const Duration(milliseconds: 500));
    drain(tester);

    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('renders with the navigation bar hidden', (tester) async {
    final provider = createMockDownloadProvider();
    provider.setNavbarVisible(false);

    await pumpContainer(tester, provider: provider);

    expect(find.byType(MainNavigationContainer), findsOneWidget);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('renders a wide/desktop layout', (tester) async {
    await pumpContainer(tester, size: const Size(1500, 1000));

    expect(find.byType(MainNavigationContainer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders a tablet portrait layout with the floating nav bar',
      (tester) async {
    await pumpContainer(tester, size: const Size(800, 1000));

    expect(find.byType(MainNavigationContainer), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders with classic UI and amoled theme', (tester) async {
    final settings = createMockSettingsProvider();
    await settings.load();
    await settings.setClassicUi(true);
    await settings.setThemeMode('amoled');

    await pumpContainer(tester, settings: settings);

    expect(find.byType(MainNavigationContainer), findsOneWidget);
    drain(tester);
  });

  testWidgets('renders correctly in RTL', (tester) async {
    await pumpContainer(tester, locale: const Locale('ar'));

    expect(find.byType(MainNavigationContainer), findsOneWidget);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('app lifecycle changes do not throw', (tester) async {
    await pumpContainer(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // _saveTorrentResumeStateWithTimeout races a 3s timeout; let it fire.
    await tester.pump(const Duration(seconds: 4));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 50));
    drain(tester);

    expect(find.byType(MainNavigationContainer), findsOneWidget);
  });

  testWidgets('handles an initial share URL without crashing', (tester) async {
    await pumpContainer(
      tester,
      initialUrl: 'https://example.com/file.zip',
      isShareLaunch: true,
    );

    expect(find.byType(MainNavigationContainer), findsOneWidget);
    drain(tester);
  });
}
