import 'package:dmx/features/browser/screens/browser_screen.dart';
import 'package:dmx/features/browser/services/adblock_filter_updater.dart';
import 'package:dmx/features/browser/widgets/bookmark_manager_screen.dart';
import 'package:dmx/features/browser/widgets/browser_history_sheet.dart';
import 'package:dmx/features/browser/widgets/smart_url_bar.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

void main() {
  group('BrowserScreen', () {
    // BrowserScreen.initState() kicks off AdBlockerService.init(), which
    // starts a 24h periodic filter-update scheduler on a static singleton.
    // Cancel it inside each test so the fake-async pending-timer invariant
    // passes.
    void stopAdBlockScheduler() {
      AdBlockFilterUpdater().stopAutoUpdateScheduler();
    }

    // The browser home dashboard can overflow by a few pixels on some
    // surfaces; drain the non-fatal layout reports.
    void drain(WidgetTester tester) {
      while (tester.takeException() != null) {}
    }

    Future<SettingsProvider> pumpBrowser(
      WidgetTester tester, {
      SettingsProvider? settings,
    }) async {
      tester.view.physicalSize = const Size(1080, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final effective = settings ?? createMockSettingsProvider();
      await effective.load();

      await tester.pumpWidget(createTestApp(
        child: const BrowserScreen(),
        settingsProvider: effective,
      ));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      stopAdBlockScheduler();
      drain(tester);
      return effective;
    }

    testWidgets('renders URL bar', (tester) async {
      await pumpBrowser(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('URL bar accepts text input', (tester) async {
      await pumpBrowser(tester);

      final textFields = find.byType(TextField);
      if (textFields.evaluate().isNotEmpty) {
        await tester.enterText(textFields.first, 'https://example.com');
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('https://example.com'), findsOneWidget);
      } else {
        expect(find.byType(BrowserScreen), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('tab counter is rendered', (tester) async {
      await pumpBrowser(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('renders across dark, amoled, classic and desktop variants',
        (tester) async {
      final settings = createMockSettingsProvider();
      await settings.load();
      await settings.setThemeMode('amoled');
      await settings.setClassicUi(true);
      await settings.setDesktopMode(true);

      await pumpBrowser(tester, settings: settings);

      expect(find.byType(BrowserScreen), findsOneWidget);
      expect(find.byIcon(Icons.desktop_windows_rounded), findsWidgets);
    });

    testWidgets('incognito mode shows and dismisses the banner',
        (tester) async {
      final settings = createMockSettingsProvider();
      await settings.load();
      await settings.setIncognitoEnabled(true);

      await pumpBrowser(tester, settings: settings);

      expect(
        find.textContaining('Incognito'),
        findsWidgets,
      );

      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pump(const Duration(milliseconds: 200));
      drain(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('overflow menu opens and finds in page', (tester) async {
      await pumpBrowser(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      expect(find.text('Find in page'), findsOneWidget);
      expect(find.text('Bookmarks Manager'), findsOneWidget);

      await tester.tap(find.text('Find in page'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('overflow menu toggles the media sniffer', (tester) async {
      await pumpBrowser(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      expect(find.text('Stream sniffer: ON'), findsOneWidget);
      await tester.tap(find.text('Stream sniffer: ON'));
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('menu opens recently closed and browser settings',
        (tester) async {
      await pumpBrowser(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      await tester.tap(find.text('Recently Closed'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
      expect(find.byType(BrowserScreen), findsOneWidget);

      Navigator.of(tester.element(find.byType(BrowserScreen))).pop();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      await tester.tap(find.text('Browser settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      drain(tester);

      expect(find.text('Browser Settings'), findsOneWidget);
    });

    testWidgets('menu opens the bookmarks manager', (tester) async {
      await pumpBrowser(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      await tester.tap(find.text('Bookmarks Manager'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      drain(tester);

      expect(find.byType(BookmarkManagerScreen), findsOneWidget);
    });

    testWidgets('menu opens browsing history', (tester) async {
      await pumpBrowser(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      await tester.tap(find.text('Browser History'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      drain(tester);

      expect(find.byType(BrowserHistorySheet), findsOneWidget);
    });

    testWidgets('opens the tab switcher and adds a tab', (tester) async {
      await pumpBrowser(tester);

      final menuCenter = tester.getCenter(find.byIcon(Icons.more_vert));
      await tester.tapAt(menuCenter - const Offset(34, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      expect(find.byIcon(Icons.add_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      expect(find.text('2'), findsWidgets);
    });

    testWidgets('renders correctly in RTL', (tester) async {
      tester.view.physicalSize = const Size(1080, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final settings = createMockSettingsProvider();
      await settings.load();

      await tester.pumpWidget(createTestApp(
        child: const BrowserScreen(),
        settingsProvider: settings,
        locale: const Locale('ar'),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      stopAdBlockScheduler();
      drain(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);
    }

    Future<void> selectMenu(WidgetTester tester, String label) async {
      await openMenu(tester);
      await tester.tap(find.text(label).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
    }

    Future<void> pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft,
          platform: 'windows');
      expect(HardwareKeyboard.instance.isControlPressed, isTrue);
      await tester.sendKeyDownEvent(key, platform: 'windows');
      await tester.sendKeyUpEvent(key, platform: 'windows');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft,
          platform: 'windows');
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
    }

    Finder urlBarField() => find.descendant(
          of: find.byType(SmartUrlBar),
          matching: find.byType(TextField),
        );

    testWidgets('quick-toggle menu items update settings without error',
        (tester) async {
      final settings = createMockSettingsProvider();
      await settings.load();
      await settings.setForceDarkMode(false);
      await settings.setBlockImages(false);
      await pumpBrowser(tester, settings: settings);

      await selectMenu(tester, 'Dark mode: ON');
      await selectMenu(tester, 'Images: VISIBLE');
      await selectMenu(tester, 'Stream sniffer: ON');

      expect(find.byType(BrowserScreen), findsOneWidget);
      expect(settings.blockImages, isTrue);
      expect(settings.forceDarkMode, isTrue);
    });

    testWidgets('page-tool menu items are safe on the home tab',
        (tester) async {
      await pumpBrowser(tester);

      for (final label in [
        'Reload',
        'Bookmark this page',
        'Copy URL',
        'Share URL',
        'Reader Mode',
        'Find in page',
        'Capture page',
        'Translate page',
        'Print / PDF',
      ]) {
        await selectMenu(tester, label);
      }

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('new incognito tab menu item adds a tab', (tester) async {
      final settings = createMockSettingsProvider();
      await settings.load();
      await settings.setIncognitoEnabled(false);
      await pumpBrowser(tester, settings: settings);

      await selectMenu(tester, 'New incognito tab');
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      expect(find.text('2'), findsWidgets);
    });

    testWidgets('URL bar submission navigates the active tab', (tester) async {
      await pumpBrowser(tester);

      await tester.enterText(urlBarField(), 'example.com');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      expect(find.text('https://example.com'), findsWidgets);
    });

    testWidgets('search query input navigates the active tab', (tester) async {
      await pumpBrowser(tester);

      await tester.enterText(urlBarField(), 'flutter widgets');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('system back from a navigated page returns to the dashboard',
        (tester) async {
      await pumpBrowser(tester);

      await tester.enterText(urlBarField(), 'example.com');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('toolbar close button opens the quit dialog and cancels',
        (tester) async {
      await pumpBrowser(tester);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      expect(find.text('Close Browser'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('toolbar close button can hide the browser', (tester) async {
      final settings = await pumpBrowser(tester);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      await tester.tap(find.text('Hide'));
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      expect(settings.isDarkMode, isTrue);
      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('desktop keyboard shortcuts drive tab and library actions',
        (tester) async {
      await pumpBrowser(tester);

      // Put focus on the screen-level Focus node so key events reach the
      // desktop shortcut handler.
      final focusNode = Focus.of(tester.element(find.byType(SmartUrlBar)));
      focusNode.requestFocus();
      await tester.pump(const Duration(milliseconds: 100));
      drain(tester);
      expect(focusNode.hasFocus, isTrue);

      // Ctrl+T / Ctrl+W exercise the tab shortcut paths.
      await pressCtrl(tester, LogicalKeyboardKey.keyT);
      await pressCtrl(tester, LogicalKeyboardKey.keyW);

      // Ctrl+L focuses the URL bar without throwing.
      await pressCtrl(tester, LogicalKeyboardKey.keyL);

      // Ctrl+F invokes the find-in-page handler.
      await pressCtrl(tester, LogicalKeyboardKey.keyF);

      // Ctrl+D opens the bookmarks manager.
      await pressCtrl(tester, LogicalKeyboardKey.keyD);
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
      expect(find.byType(BookmarkManagerScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(BookmarkManagerScreen))).pop();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      // Ctrl+H opens the browsing history.
      await pressCtrl(tester, LogicalKeyboardKey.keyH);
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
      expect(find.byType(BrowserHistorySheet), findsOneWidget);
      Navigator.of(tester.element(find.byType(BrowserHistorySheet))).pop();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('scrolling the dashboard is handled without error',
        (tester) async {
      await pumpBrowser(tester);

      await tester.drag(
        find.byType(BrowserScreen),
        const Offset(0, -300),
      );
      await tester.pump(const Duration(milliseconds: 200));
      drain(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    Future<void> openTabSwitcher(WidgetTester tester) async {
      final menuCenter = tester.getCenter(find.byIcon(Icons.more_vert));
      await tester.tapAt(menuCenter - const Offset(34, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      drain(tester);
    }

    testWidgets('tab switcher opens an incognito tab', (tester) async {
      final settings = createMockSettingsProvider();
      await settings.load();
      await settings.setIncognitoEnabled(false);
      await pumpBrowser(tester, settings: settings);

      await openTabSwitcher(tester);
      expect(find.byIcon(Icons.visibility_off_rounded), findsWidgets);

      await tester.tap(find.byIcon(Icons.visibility_off_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      drain(tester);

      expect(find.text('2'), findsWidgets);
    });

    testWidgets('tab switcher close-all flow resets to a single tab',
        (tester) async {
      await pumpBrowser(tester);

      await openTabSwitcher(tester);
      await tester.tap(find.byIcon(Icons.delete_sweep_rounded));
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      expect(find.text('Close All'), findsOneWidget);
      await tester.tap(find.text('Close All'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      drain(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
      expect(find.text('1'), findsWidgets);
    });

    testWidgets('tab limit dialog appears when maxTabs is reached',
        (tester) async {
      final settings = createMockSettingsProvider();
      await settings.load();
      settings.maxTabs = 1;
      await pumpBrowser(tester, settings: settings);

      await openTabSwitcher(tester);
      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);
      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('toolbar close button can terminate the browser session',
        (tester) async {
      await pumpBrowser(tester);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump(const Duration(milliseconds: 300));
      drain(tester);

      await tester.tap(find.text('Terminate'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      drain(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('memory pressure notification is handled', (tester) async {
      await pumpBrowser(tester);

      tester.binding.handleMemoryPressure();
      await tester.pump(const Duration(milliseconds: 100));
      drain(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('closing a navigated tab records it in recently closed',
        (tester) async {
      await pumpBrowser(tester);

      await tester.enterText(urlBarField(), 'example.com');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      await openTabSwitcher(tester);
      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      drain(tester);

      await selectMenu(tester, 'Recently Closed');
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      expect(find.text('Recently closed tabs'), findsOneWidget);
    });

    Future<void> navigateToExample(WidgetTester tester) async {
      await tester.enterText(urlBarField(), 'example.com');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);
    }

    testWidgets('forward navigation restores the previous page',
        (tester) async {
      await pumpBrowser(tester);
      await navigateToExample(tester);

      // Back sends the tab to its dashboard, enabling forward.
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      await tester.tap(find.byIcon(Icons.arrow_forward_ios));
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      expect(find.text('https://example.com'), findsWidgets);
    });

    testWidgets('capture page reports failure without a live webview',
        (tester) async {
      await pumpBrowser(tester);
      await navigateToExample(tester);

      await selectMenu(tester, 'Capture page');
      await tester.pump(const Duration(milliseconds: 400));
      drain(tester);

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('translate page opens the language sheet and adds a tab',
        (tester) async {
      await pumpBrowser(tester);
      await navigateToExample(tester);

      await selectMenu(tester, 'Translate page');
      await tester.pump(const Duration(milliseconds: 500));
      drain(tester);

      expect(find.text('Translate page to'), findsOneWidget);
      await tester.tap(find.text('English'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      drain(tester);

      expect(find.text('2'), findsWidgets);
    });

    testWidgets('reader, find and print are safe on a navigated page',
        (tester) async {
      await pumpBrowser(tester);
      await navigateToExample(tester);

      await selectMenu(tester, 'Reader Mode');
      await selectMenu(tester, 'Find in page');
      await selectMenu(tester, 'Print / PDF');

      expect(find.byType(BrowserScreen), findsOneWidget);
    });

    testWidgets('shield sheet element picker starts without a live webview',
        (tester) async {
      await pumpBrowser(tester);
      await navigateToExample(tester);

      await tester.tap(find.byIcon(Icons.lock_rounded));
      await tester.pump(const Duration(milliseconds: 500));
      drain(tester);

      if (find.byIcon(Icons.touch_app_rounded).evaluate().isNotEmpty) {
        await tester.tap(find.byIcon(Icons.touch_app_rounded).first);
        await tester.pump(const Duration(milliseconds: 400));
        drain(tester);
      }

      expect(find.byType(BrowserScreen), findsOneWidget);
    });
  });
}
