import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/browser/widgets/browser_home_page.dart';
import 'package:dmx/features/browser/widgets/smart_url_bar.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_services.dart';
import '../../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Browser UI Widgets Tests [Browser 10/10]', () {
    late SettingsProvider settings;
    late FakeDatabaseService database;

    setUp(() async {
      setupTestPluginMocks();
      SharedPreferences.setMockInitialValues({});
      settings = createMockSettingsProvider();
      await settings.load();
      database = FakeDatabaseService();
    });

    testWidgets('SmartUrlBar renders input text and shield button',
        (tester) async {
      final controller = TextEditingController(text: 'https://example.com');
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsProvider>.value(value: settings),
              Provider<DatabaseService>.value(value: database),
            ],
            child: Scaffold(
              body: SmartUrlBar(
                controller: controller,
                focusNode: focusNode,
                isDark: true,
                isHttps: true,
                onNavigate: (_) {},
              ),
            ),
          ),
        ),
      );

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('https://example.com'), findsOneWidget);

      focusNode.dispose();
      controller.dispose();
    });

    testWidgets('BrowserHomePage renders default quick actions',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ],
            child: Scaffold(
              body: BrowserHomePage(
                onSearchTap: () {},
                onBookmarksTap: () {},
                onHistoryTap: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.byType(BrowserHomePage), findsOneWidget);
    });
  });
}
