import 'package:dmx/core/services/user_script_manager.dart';
import 'package:dmx/features/browser/screens/script_manager_screen.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_helpers.dart';

UserScript _script({
  String id = 's1',
  String name = 'My Script',
  String urlPattern = '*://*.example.com/*',
  String code = 'console.log(1);',
  bool isCss = false,
  bool enabled = true,
}) {
  return UserScript(
    id: id,
    name: name,
    urlPattern: urlPattern,
    code: code,
    isCss: isCss,
    enabled: enabled,
    permissions: const {ScriptPermission.domRead, ScriptPermission.domWrite},
  );
}

void main() {
  setUp(() {
    setupTestPluginMocks();
    UserScriptManager.resetInstance();
    SharedPreferences.setMockInitialValues({'isDarkMode': true});
  });

  // The script editor hosts a CodeField which cannot report intrinsic
  // dimensions, so the AlertDialog reports a non-fatal layout error. Drain
  // those reports and drive buttons directly to keep the focus on behavior.
  void drain(WidgetTester tester) {
    while (tester.takeException() != null) {}
  }

  Future<SettingsProvider> pumpScreen(WidgetTester tester) async {
    final settings = createMockSettingsProvider();
    await settings.load();

    await tester.pumpWidget(createTestApp(
      child: const ScriptManagerScreen(),
      settingsProvider: settings,
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    drain(tester);
    return settings;
  }

  testWidgets('shows empty state when no scripts', (tester) async {
    await pumpScreen(tester);

    expect(find.byType(ScriptManagerScreen), findsOneWidget);
    expect(find.text('No scripts yet'), findsOneWidget);
    expect(find.text('New Script'), findsOneWidget);
  });

  testWidgets('renders script card and toggles it', (tester) async {
    await pumpScreen(tester);
    await UserScriptManager.instance.add(_script());
    await tester.pump(const Duration(milliseconds: 100));
    drain(tester);

    expect(find.text('My Script'), findsOneWidget);

    await tester.tap(find.byType(Switch).first);
    await tester.pump(const Duration(milliseconds: 100));
    drain(tester);

    expect(UserScriptManager.instance.scripts.first.enabled, isFalse);
  });

  testWidgets('deleting a script asks for confirmation and removes it',
      (tester) async {
    await pumpScreen(tester);
    await UserScriptManager.instance.add(_script(name: 'Doomed'));
    await tester.pump(const Duration(milliseconds: 100));
    drain(tester);

    expect(find.text('Doomed'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    drain(tester);

    expect(find.textContaining('Are you sure'), findsOneWidget);

    await tester.tap(find.text('CONFIRM'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    drain(tester);

    expect(UserScriptManager.instance.scripts, isEmpty);
  });

  testWidgets('search filters the script list', (tester) async {
    await pumpScreen(tester);
    await UserScriptManager.instance.add(_script(name: 'Alpha', id: 'a'));
    await UserScriptManager.instance
        .add(_script(name: 'Beta', id: 'b', urlPattern: '*://beta.com/*'));
    await tester.pump(const Duration(milliseconds: 100));
    drain(tester);

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'alpha');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    drain(tester);

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('css script renders palette icon', (tester) async {
    await pumpScreen(tester);
    await UserScriptManager.instance
        .add(_script(name: 'Style', isCss: true, enabled: false));
    await tester.pump(const Duration(milliseconds: 100));
    drain(tester);

    expect(find.byIcon(Icons.palette_outlined), findsWidgets);
    expect(find.text('OFF'), findsOneWidget);
  });
}
