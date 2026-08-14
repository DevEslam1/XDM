import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/features/settings/screens/settings_screen.dart';
import 'package:dmx/features/settings/screens/appearance_settings_page.dart';
import 'package:dmx/features/settings/screens/torrent_settings_page.dart';
import 'package:dmx/features/settings/screens/advanced_settings_page.dart';
import '../../helpers/test_helpers.dart';

void main() {
  group('SettingsScreen Lazy Build Tests (U-09)', () {
    testWidgets('inactive tabs are not mounted in the widget tree',
        (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const SettingsScreen(initialSection: 'appearance'),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AppearanceSettingsPage), findsOneWidget);
      expect(find.byType(TorrentSettingsPage), findsNothing);
      expect(find.byType(AdvancedSettingsPage), findsNothing);
    });

    testWidgets('selecting another tab mounts only that active tab',
        (tester) async {
      await tester.pumpWidget(createTestApp(
        child: const SettingsScreen(initialSection: 'torrent'),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(TorrentSettingsPage), findsOneWidget);
      expect(find.byType(AppearanceSettingsPage), findsNothing);
      expect(find.byType(AdvancedSettingsPage), findsNothing);
    });
  });
}
