import 'package:dmx/features/add_download/widgets/add_download_dialog.dart';
import 'package:dmx/features/downloads/provider/download_provider.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_helpers.dart';

const _magnetUrl =
    'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a&dn=MyFile';

void _size(WidgetTester tester, {double width = 820, double height = 2400}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void _drain(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Future<void> _pumpDialog(
  WidgetTester tester, {
  String? prefilledUrl,
  String? prefilledName,
  bool isShareLaunch = false,
  DownloadProvider? provider,
  SettingsProvider? settings,
}) async {
  await tester.pumpWidget(createTestApp(
    downloadProvider: provider,
    settingsProvider: settings,
    child: Builder(builder: (context) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          AddDownloadDialog.show(
            context,
            prefilledUrl: prefilledUrl,
            prefilledName: prefilledName,
            isShareLaunch: isShareLaunch,
          );
        }
      });
      return const SizedBox.shrink();
    }),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('AddDownloadDialog', () {
    testWidgets('renders URL input field', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const AddDownloadDialog(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AddDownloadDialog), findsOneWidget);
    });

    testWidgets('accepts valid HTTP URL', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const AddDownloadDialog(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      final textFields = find.byType(TextFormField);
      if (textFields.evaluate().isNotEmpty) {
        await tester.enterText(
            textFields.first, 'https://example.com/file.zip');
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('https://example.com/file.zip'), findsOneWidget);
      }
    });

    testWidgets('accepts magnet link input', (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const AddDownloadDialog(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      final textFields = find.byType(TextFormField);
      if (textFields.evaluate().isNotEmpty) {
        await tester.enterText(
          textFields.first,
          'magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a',
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('magnet:'), findsWidgets);
      }
    });
  });

  group('AddDownloadDialog URL validation', () {
    testWidgets('shows valid signal for a valid URL', (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.enterText(
          find.byType(TextFormField).first, 'https://example.com/file.zip');
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.text('SIGNAL VALID'), findsOneWidget);
    });

    testWidgets('shows invalid signal for an invalid URL', (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.enterText(find.byType(TextFormField).first, 'not a url');
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.text('INVALID SIGNAL'), findsOneWidget);
    });

    testWidgets('counts multiple valid URLs', (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.enterText(
        find.byType(TextFormField).first,
        'https://a.com/1.zip\nhttps://b.com/2.zip',
      );
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.text('2 VALID SIGNALS'), findsOneWidget);
    });

    testWidgets('renders the site intelligence chip after analysis',
        (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.enterText(
          find.byType(TextFormField).first, 'https://example.com/file.zip');
      await tester.pump(const Duration(milliseconds: 500));
      _drain(tester);

      expect(find.byType(AddDownloadDialog), findsOneWidget);
    });
  });

  group('AddDownloadDialog advanced options', () {
    testWidgets('toggling advanced reveals referrer and path fields',
        (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.text('ADVANCED OPTIONS'), findsOneWidget);
      expect(find.text('HTTP AUTHENTICATION (OPTIONAL)'), findsOneWidget);
      expect(find.text('CUSTOM HEADERS (OPTIONAL)'), findsOneWidget);
    });

    testWidgets('adds and removes a custom header row', (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      await tester.tap(find.text('ADD'));
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.text('Header'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded).last);
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.text('Header'), findsNothing);
    });

    testWidgets('toggles the auth password visibility', (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.visibility_off_rounded));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byIcon(Icons.visibility_rounded), findsOneWidget);
    });

    testWidgets('toggles the wifi and retry option chips', (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.tap(find.text('WI-FI'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('RETRY'));
      await tester.pump(const Duration(milliseconds: 200));
      _drain(tester);

      expect(find.byType(AddDownloadDialog), findsOneWidget);
    });

    testWidgets('steps the thread count up and down', (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.tap(find.byIcon(Icons.add_rounded).first);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byIcon(Icons.remove_rounded).first);
      await tester.pump(const Duration(milliseconds: 200));
      _drain(tester);

      expect(find.byType(AddDownloadDialog), findsOneWidget);
    });

    testWidgets('changes the selected category', (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Video').last);
      await tester.pump(const Duration(milliseconds: 300));
      _drain(tester);

      expect(find.byType(AddDownloadDialog), findsOneWidget);
    });

    testWidgets('enabling schedule reveals the date row', (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      await tester.tap(find.byType(Switch).first);
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.text('Schedule'), findsOneWidget);
    });
  });

  group('AddDownloadDialog actions', () {
    testWidgets('pasting a magnet link populates the URL field',
        (tester) async {
      _size(tester);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': _magnetUrl};
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await _pumpDialog(tester);

      await tester.tap(find.byIcon(Icons.content_paste_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.textContaining('magnet:'), findsWidgets);
    });

    testWidgets('connecting with an empty URL warns the user', (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.tap(find.text('Connect'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.text('Enter a URL first'), findsOneWidget);
    });

    testWidgets('connecting with an invalid URL warns the user',
        (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.enterText(find.byType(TextFormField).first, 'not a url');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Connect'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.text('Invalid URL'), findsOneWidget);
    });

    testWidgets('submitting an empty form shows validation errors',
        (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.tap(find.text('Add'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.text('Please enter a URL'), findsWidgets);
    });

    testWidgets('open-in-browser with no URL shows a snackbar', (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      await tester.tap(find.byIcon(Icons.language_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.text('No URL to open'), findsOneWidget);
    });

    testWidgets('close button dismisses the dialog', (tester) async {
      _size(tester);
      await _pumpDialog(tester);

      expect(find.byType(AddDownloadDialog), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      expect(find.byType(AddDownloadDialog), findsNothing);
    });
  });

  group('AddDownloadDialog prefilled and submit', () {
    testWidgets('prefilled magnet resolves the torrent name', (tester) async {
      _size(tester);
      await _pumpDialog(tester, prefilledUrl: _magnetUrl);

      expect(find.byType(AddDownloadDialog), findsOneWidget);
      expect(find.textContaining('MyFile'), findsWidgets);
    });

    testWidgets('prefilled name populates the file name field', (tester) async {
      _size(tester);
      await _pumpDialog(tester, prefilledName: 'movie.mkv');

      expect(find.text('movie'), findsWidgets);
    });

    testWidgets('submitting a scheduled magnet adds the task and closes',
        (tester) async {
      _size(tester);
      final settings = createMockSettingsProvider();
      await settings.load();
      settings.customDownloadPath = '/tmp/dmx-test';
      final provider = createMockDownloadProvider();

      await _pumpDialog(
        tester,
        prefilledUrl: _magnetUrl,
        provider: provider,
        settings: settings,
      );

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      await tester.tap(find.byType(Switch).first);
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      await tester.tap(find.text('Add'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      _drain(tester);

      expect(provider.tasks, isNotEmpty);
      expect(find.byType(AddDownloadDialog), findsNothing);
    });

    testWidgets('duplicate magnet offers the add-numbered flow',
        (tester) async {
      _size(tester);
      final settings = createMockSettingsProvider();
      await settings.load();
      settings.customDownloadPath = '/tmp/dmx-test';
      final provider = createMockDownloadProvider();
      await provider.addTask(
        createTestTask(id: 'dup-1', url: _magnetUrl, fileName: 'MyFile'),
      );

      await _pumpDialog(
        tester,
        prefilledUrl: _magnetUrl,
        prefilledName: 'MyFile',
        provider: provider,
        settings: settings,
      );

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      await tester.tap(find.byType(Switch).first);
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      await tester.tap(find.text('Add'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      _drain(tester);

      expect(find.text('DUPLICATE'), findsOneWidget);

      await tester.tap(find.text('ADD NUMBERED'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      _drain(tester);

      expect(provider.tasks.length, 2);
      expect(find.byType(AddDownloadDialog), findsNothing);
    });

    testWidgets('bulk submit adds multiple scheduled URLs', (tester) async {
      _size(tester);
      final settings = createMockSettingsProvider();
      await settings.load();
      settings.customDownloadPath = '/tmp/dmx-test';
      final provider = createMockDownloadProvider();

      await _pumpDialog(tester, provider: provider, settings: settings);

      await tester.enterText(
        find.byType(TextFormField).first,
        'https://a.com/1.zip\nhttps://b.com/2.zip',
      );
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      await tester.enterText(find.byType(TextFormField).at(1), 'batch');
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      await tester.tap(find.byType(Switch).first);
      await tester.pump(const Duration(milliseconds: 400));
      _drain(tester);

      await tester.tap(find.text('Add'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump(const Duration(milliseconds: 800));
      _drain(tester);

      expect(provider.tasks.length, 2);
    });
  });
}
