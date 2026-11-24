import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:dmx/shared/design/dmx_design.dart';
import 'package:dmx/shared/widgets/dmx_backdrop_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_helpers.dart';

void _drain(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Widget _bare(Widget child) {
  return MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;

  setUp(() async {
    settings = createMockSettingsProvider();
    await settings.load();
    settings.enableGlow = true;
    settings.isDarkMode = true;
    settings.themeMode = 'dark';
    await settings.setClassicUi(true);
  });

  group('DmxStatusColors', () {
    test('maps every status to a color for both themes', () {
      for (final status in DownloadStatus.values) {
        expect(DmxStatusColors.of(status, true), isA<Color>());
        expect(DmxStatusColors.of(status, false), isA<Color>());
      }
    });
  });

  group('DmxCardShell', () {
    testWidgets('falls back to settings without a provider', (tester) async {
      await tester.pumpWidget(_bare(
        DmxCardShell(
          accent: Colors.cyan,
          onTap: () {},
          onLongPress: () {},
          child: const SizedBox(width: 100, height: 60),
        ),
      ));
      await tester.pump();

      expect(find.byType(DmxCardShell), findsOneWidget);
    });

    testWidgets('honours showRail, tap and long press', (tester) async {
      var tapped = 0;
      var longPressed = 0;

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: Center(
          child: DmxCardShell(
            showRail: false,
            onTap: () => tapped++,
            onLongPress: () => longPressed++,
            child: const SizedBox(width: 120, height: 80, child: Text('card')),
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('card'));
      expect(tapped, 1);
      await tester.longPress(find.text('card'));
      expect(longPressed, 1);
    });

    testWidgets('renders the glow rail when enabled', (tester) async {
      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: const Center(
          child: DmxCardShell(
            accent: Colors.pink,
            child: SizedBox(width: 100, height: 60),
          ),
        ),
      ));
      await tester.pump();

      expect(find.byType(DmxCardShell), findsOneWidget);
    });

    testWidgets('renders in classic mode with glow disabled', (tester) async {
      settings.enableGlow = false;

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: const Center(
          child: DmxCardShell(
            child: SizedBox(width: 100, height: 60),
          ),
        ),
      ));
      await tester.pump();

      expect(find.byType(DmxCardShell), findsOneWidget);
    });
  });

  group('DmxDivider and sections', () {
    testWidgets('DmxDivider renders without a provider', (tester) async {
      await tester.pumpWidget(_bare(const DmxDivider()));
      await tester.pump();
      expect(find.byType(DmxDivider), findsOneWidget);
    });

    testWidgets('DmxSectionHeader renders title, accent and trailing',
        (tester) async {
      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: const Center(
          child: DmxSectionHeader(
            title: 'Downloads',
            isDark: true,
            trailing: Icon(Icons.chevron_right),
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('DOWNLOADS'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('DmxSectionGroup renders children with dividers',
        (tester) async {
      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: const Column(
          children: [
            DmxSectionGroup(
              accentColor: Colors.teal,
              children: [
                ListTile(title: Text('One')),
                ListTile(title: Text('Two')),
                ListTile(title: Text('Three')),
              ],
            ),
          ],
        ),
      ));
      await tester.pump();

      expect(find.text('One'), findsOneWidget);
      expect(find.text('Three'), findsOneWidget);
      expect(find.byType(DmxDivider), findsNWidgets(2));
    });

    testWidgets('DmxSectionGroup wraps with a backdrop in modern mode',
        (tester) async {
      await settings.setClassicUi(false);

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: const Column(
          children: [
            DmxSectionGroup(
              accentColor: Colors.teal,
              children: [ListTile(title: Text('Only'))],
            ),
          ],
        ),
      ));
      await tester.pump();

      expect(find.byType(DmxBackdropFilter), findsOneWidget);
    });
  });

  group('DmxDialog and confirm', () {
    testWidgets('DmxDialog shows title, icon and actions', (tester) async {
      var confirmed = false;

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: Center(
          child: DmxDialog(
            title: 'My Dialog',
            icon: Icons.info_outline,
            content: const Text('Body text'),
            actions: [
              DmxButton.filled(
                label: 'ok',
                onPressed: () => confirmed = true,
              ),
            ],
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('My Dialog'), findsOneWidget);
      expect(find.text('Body text'), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);

      await tester.tap(find.text('OK'));
      expect(confirmed, isTrue);
    });

    testWidgets('DmxConfirmDialog.show resolves true on confirm',
        (tester) async {
      bool? result;

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: Builder(builder: (context) {
          return Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await DmxConfirmDialog.show(
                  context,
                  title: 'Delete?',
                  message: 'Are you sure?',
                  confirmLabel: 'Delete',
                  cancelLabel: 'Keep',
                  isDestructive: true,
                );
              },
              child: const Text('open'),
            ),
          );
        }),
      ));

      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Delete?'), findsOneWidget);
      expect(find.text('Keep'), findsOneWidget);

      await tester.tap(find.text('DELETE'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(result, isTrue);
    });

    testWidgets('DmxConfirmDialog.show resolves false on cancel',
        (tester) async {
      bool? result;

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: Builder(builder: (context) {
          return Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await DmxConfirmDialog.show(
                  context,
                  title: 'Delete?',
                  message: 'Are you sure?',
                );
              },
              child: const Text('open'),
            ),
          );
        }),
      ));

      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(result, isFalse);
    });
  });

  group('DmxButton', () {
    testWidgets('renders each variant and fires onPressed', (tester) async {
      var pressed = 0;

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: Column(
          children: [
            DmxButton.filled(label: 'filled', onPressed: () => pressed++),
            DmxButton.outline(label: 'outline', onPressed: () => pressed++),
            DmxButton.destructive(
                label: 'destructive', onPressed: () => pressed++),
            DmxButton.ghost(label: 'ghost', onPressed: () => pressed++),
          ],
        ),
      ));
      await tester.pump();

      expect(find.text('FILLED'), findsOneWidget);
      expect(find.text('OUTLINE'), findsOneWidget);
      expect(find.text('DESTRUCTIVE'), findsOneWidget);
      expect(find.text('GHOST'), findsOneWidget);

      await tester.tap(find.text('FILLED'));
      expect(pressed, 1);
    });

    testWidgets('shows a spinner and blocks taps while loading',
        (tester) async {
      var pressed = 0;

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: Center(
          child: DmxButton.filled(
            label: 'save',
            isLoading: true,
            onPressed: () => pressed++,
          ),
        ),
      ));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('SAVE'), warnIfMissed: false);
      expect(pressed, 0);
      _drain(tester);
    });

    testWidgets('renders a leading icon when provided', (tester) async {
      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: Center(
          child: DmxButton.filled(
            label: 'add',
            icon: Icons.add,
            onPressed: () {},
          ),
        ),
      ));
      await tester.pump();

      expect(find.byIcon(Icons.add), findsOneWidget);
    });
  });

  group('DmxTextField', () {
    testWidgets('renders hint, icons and forwards text changes',
        (tester) async {
      final controller = TextEditingController();
      String? changed;

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: Center(
          child: DmxTextField(
            controller: controller,
            hintText: 'type here',
            prefixIcon: Icons.search,
            suffixIcon: const Icon(Icons.clear),
            onChanged: (v) => changed = v,
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('type here'), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.byIcon(Icons.clear), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'hello');
      expect(changed, 'hello');
      controller.dispose();
    });
  });

  group('DmxEmptyState', () {
    testWidgets('renders portrait layout and triggers the button',
        (tester) async {
      var pressed = 0;

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: DmxEmptyState(
          icon: Icons.inbox,
          title: 'Nothing here',
          subtitle: 'Come back later',
          buttonText: 'add',
          onButtonPressed: () => pressed++,
        ),
      ));
      await tester.pump();

      expect(find.text('Nothing here'), findsOneWidget);
      await tester.tap(find.text('ADD'));
      expect(pressed, 1);
    });

    testWidgets('renders the compact landscape layout', (tester) async {
      tester.view.physicalSize = const Size(1000, 320);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: const DmxEmptyState(
          icon: Icons.inbox,
          title: 'Nothing here',
          subtitle: 'Come back later',
        ),
      ));
      await tester.pump();

      expect(find.byIcon(Icons.inbox), findsOneWidget);
    });
  });

  group('DmxBanner', () {
    testWidgets('renders text and a custom icon', (tester) async {
      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: const DmxBanner(
          text: 'Heads up',
          icon: Icons.warning_amber_rounded,
        ),
      ));
      await tester.pump();

      expect(find.text('Heads up'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });
  });

  group('DmxPressable', () {
    testWidgets('invokes tap and long press callbacks', (tester) async {
      var taps = 0;
      var longs = 0;

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: Center(
          child: DmxPressable(
            onTap: () => taps++,
            onLongPress: () => longs++,
            child: const SizedBox(
              width: 80,
              height: 80,
              child: Text('press'),
            ),
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('press'));
      expect(taps, 1);

      await tester.longPress(find.text('press'));
      expect(longs, 1);
    });

    testWidgets('renders without callbacks', (tester) async {
      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: const Center(
          child: DmxPressable(
            child: SizedBox(width: 80, height: 80, child: Text('idle')),
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('idle'), findsOneWidget);
    });
  });

  group('showMediaChoiceDialog', () {
    testWidgets('returns single when Single Video is chosen', (tester) async {
      String? choice;

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: Builder(builder: (context) {
          return Center(
            child: ElevatedButton(
              onPressed: () async {
                choice = await showMediaChoiceDialog(
                  context,
                  videoTitle: 'A Clip',
                );
              },
              child: const Text('open'),
            ),
          );
        }),
      ));

      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Select Download Option'), findsOneWidget);

      await tester.tap(find.text('Single Video'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(choice, 'single');
    });

    testWidgets('returns playlist when Full Playlist is chosen',
        (tester) async {
      String? choice;

      await tester.pumpWidget(createTestApp(
        settingsProvider: settings,
        child: Builder(builder: (context) {
          return Center(
            child: ElevatedButton(
              onPressed: () async {
                choice = await showMediaChoiceDialog(
                  context,
                  videoTitle: 'A Clip',
                );
              },
              child: const Text('open'),
            ),
          );
        }),
      ));

      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('FULL PLAYLIST'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(choice, 'playlist');
    });
  });
}
