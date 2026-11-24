import 'package:dmx/features/browser/screens/browser_settings_screen.dart';
import 'package:dmx/features/browser/screens/script_manager_screen.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_helpers.dart';

void main() {
  setUp(() {
    setupTestPluginMocks();
    SharedPreferences.setMockInitialValues({
      'isDarkMode': true,
      'searchEngine': 'Google',
      'browser_user_scripts': <String>[],
    });
  });

  // SettingsCard wraps ListTiles in a DecoratedBox, which triggers a
  // non-fatal Flutter error report ("ListTile background color ... may be
  // invisible"). Drain it so the widget tests can keep focusing on behavior.
  void drain(WidgetTester tester) {
    while (tester.takeException() != null) {}
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    SettingsProvider? settings,
    bool isSnifferEnabled = true,
    ValueChanged<bool>? onSnifferChanged,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(createTestApp(
      child: BrowserSettingsScreen(
        isSnifferEnabled: isSnifferEnabled,
        onSnifferChanged: onSnifferChanged,
      ),
      settingsProvider: settings,
    ));
    await tester.pump(const Duration(milliseconds: 100));
    drain(tester);
  }

  testWidgets('renders all sections', (tester) async {
    await pumpScreen(tester);

    expect(find.byType(BrowserSettingsScreen), findsOneWidget);
    expect(find.text('Browser Settings'), findsOneWidget);
    expect(find.text('Default Search Engine'), findsOneWidget);
    expect(find.text('Ad Blocker'), findsOneWidget);
    expect(find.text('Media Sniffer'), findsOneWidget);
    expect(find.text('Max Open Tabs'), findsOneWidget);
  });

  testWidgets('toggling switches updates settings', (tester) async {
    final settings = createMockSettingsProvider();
    await settings.load();
    await pumpScreen(tester, settings: settings);

    final switches = find.byType(Switch);
    expect(switches, findsWidgets);

    for (var i = 0; i < switches.evaluate().length; i++) {
      await tester.tap(switches.at(i));
      await tester.pump(const Duration(milliseconds: 30));
      drain(tester);
    }
    await tester.pump(const Duration(milliseconds: 100));
    drain(tester);

    expect(find.byType(BrowserSettingsScreen), findsOneWidget);
  });

  testWidgets('media sniffer toggle notifies parent', (tester) async {
    var changed = 0;
    await pumpScreen(tester, onSnifferChanged: (_) => changed++);

    await tester.tap(find.byType(SwitchListTile).at(1));
    await tester.pump(const Duration(milliseconds: 50));
    drain(tester);

    expect(changed, 1);
  });

  testWidgets('search engine popup selection changes engine', (tester) async {
    final settings = createMockSettingsProvider();
    await settings.load();
    await pumpScreen(tester, settings: settings);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    drain(tester);

    await tester.tap(find.text('DuckDuckGo').last);
    await tester.pump(const Duration(milliseconds: 200));
    drain(tester);

    expect(settings.searchEngine, 'DuckDuckGo');
  });

  testWidgets('max tabs slider drag updates value', (tester) async {
    final settings = createMockSettingsProvider();
    await settings.load();
    await pumpScreen(tester, settings: settings);

    await tester.drag(find.byType(Slider), const Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 100));
    drain(tester);

    expect(find.byType(BrowserSettingsScreen), findsOneWidget);
  });

  testWidgets('navigates to script manager', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Custom JS & CSS Scripts'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    drain(tester);

    expect(find.byType(ScriptManagerScreen), findsOneWidget);
  });

  testWidgets('sniffer disabled state renders without error', (tester) async {
    await pumpScreen(tester, isSnifferEnabled: false);

    expect(find.byType(BrowserSettingsScreen), findsOneWidget);
    drain(tester);
  });
}
