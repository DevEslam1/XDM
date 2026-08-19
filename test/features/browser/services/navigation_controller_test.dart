import 'package:dmx/features/browser/models/browser_tab.dart';
import 'package:dmx/features/browser/services/navigation_controller.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settingsProvider;
  late NavigationController navController;
  BrowserTab? activeTab;
  String? openedUrl;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settingsProvider = SettingsProvider();

    activeTab = BrowserTab(
      id: 'tab-1',
      url: 'about:blank',
      title: 'New Tab',
      isHome: true,
    );

    navController = NavigationController(
      settingsProvider: settingsProvider,
      getActiveTab: () => activeTab,
      onOpenInNewTab: (url, {bool switchTo = true}) {
        openedUrl = url;
      },
      onResumeTab: (_) {},
    );
  });

  tearDown(() {
    navController.dispose();
  });

  group('NavigationController Tests', () {
    test('syncUrlController syncs blank text when on home tab', () {
      navController.syncUrlController(activeTab);
      expect(navController.urlController.text, isEmpty);
    });

    test('syncUrlController updates text when tab url changes', () {
      activeTab!.updateUrl('https://flutter.dev');
      activeTab!.isHome = false;

      navController.syncUrlController(activeTab);
      expect(navController.urlController.text, equals('https://flutter.dev'));
    });

    test('loadHome resets tab to blank state and cleans error flags', () {
      activeTab!.updateUrl('https://example.com');
      activeTab!.isHome = false;
      activeTab!.hasError = true;
      activeTab!.errorDescription = 'Network Error';

      navController.loadHome();

      expect(activeTab!.isHome, isTrue);
      expect(activeTab!.url, equals('about:blank'));
      expect(activeTab!.hasError, isFalse);
      expect(activeTab!.errorDescription, isNull);
      expect(navController.urlController.text, isEmpty);
    });

    test('goBack falls back to loadHome when tab cannot go back', () async {
      activeTab!.updateUrl('https://example.com');
      activeTab!.isHome = false;
      activeTab!.canGoBack = false;

      await navController.goBack();

      expect(activeTab!.isHome, isTrue);
      expect(activeTab!.url, equals('about:blank'));
    });

    test('navigateToUrl handles search queries when text has no dots',
        () async {
      await navController.navigateToUrl('dart flutter tutorial');
      expect(activeTab!.url, contains('google.com/search?q=dart'));
    });

    test('navigateToUrl auto-prefixes https for domain-like inputs', () async {
      await navController.navigateToUrl('github.com/flutter');
      expect(activeTab!.url, equals('https://github.com/flutter'));
    });

    test('onOpenInNewTab callback is invoked via navigationController', () {
      navController.onOpenInNewTab('https://example.com/new', switchTo: true);
      expect(openedUrl, equals('https://example.com/new'));
    });
  });
}
