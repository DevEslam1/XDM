import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/browser/services/browser_controller.dart';
import 'package:dmx/features/browser/widgets/browser_menu_button.dart';
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

  testWidgets('BrowserMenuButton opens overflow popup with 17 actions',
      (WidgetTester tester) async {
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

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
          ChangeNotifierProvider<BrowserController>.value(value: controller),
        ],
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                BrowserMenuButton(
                  controller: controller,
                  settings: settings,
                  isDark: true,
                  textClr: Colors.white,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.byType(BrowserMenuButton), findsOneWidget);
    await tester.tap(find.byType(BrowserMenuButton));
    await tester.pumpAndSettle();

    // Verify key menu actions appear in popup
    expect(find.byIcon(Icons.add_box_outlined), findsOneWidget);
    expect(find.byIcon(Icons.bookmark_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.history_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radar_rounded), findsOneWidget);
    expect(find.byIcon(Icons.cloud_download_outlined), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    downloads.dispose();
    settings.dispose();
  });
}
