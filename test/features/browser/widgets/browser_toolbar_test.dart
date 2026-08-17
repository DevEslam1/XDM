import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/browser/services/browser_controller.dart';
import 'package:dmx/features/browser/widgets/browser_toolbar.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setupTestPluginMocks();
  });

  testWidgets('BrowserToolbar renders navigation buttons, tab count and shield',
      (WidgetTester tester) async {
    final urlController = TextEditingController(text: 'https://flutter.dev');
    final focusNode = FocusNode();
    final settings = SettingsProvider();
    final db = DatabaseService();
    final downloads = DownloadProvider(
      databaseService: db,
      settingsProvider: settings,
      enableBackgroundTimers: false,
    );

    final controller = BrowserController(
      settingsProvider: settings,
      downloadProvider: downloads,
      databaseService: db,
    );

    bool tabSwitcherPressed = false;
    bool goBackPressed = false;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
          ChangeNotifierProvider<BrowserController>.value(value: controller),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: BrowserToolbar(
              controller: controller,
              urlController: urlController,
              focusNode: focusNode,
              isDark: true,
              isRtl: false,
              isLoading: false,
              canGoBack: true,
              isHomeTab: false,
              tabCount: 4,
              desktopMode: false,
              textClr: Colors.white,
              settings: settings,
              onGoBack: () => goBackPressed = true,
              onShowTabSwitcher: () => tabSwitcherPressed = true,
              onNavigateHome: () {},
              onNavigate: (_) {},
              onReload: () {},
              onStopLoading: () {},
              onQuitPressed: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('4'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);

    await tester.tap(find.text('4'));
    expect(tabSwitcherPressed, isTrue);

    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    expect(goBackPressed, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    downloads.dispose();
    settings.dispose();
  });
}
