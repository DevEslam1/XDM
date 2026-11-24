import 'package:dmx/features/add_download/widgets/youtube_playlist_sheet.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../helpers/test_helpers.dart';

void _big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void _drain(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Future<void> _pumpSheet(WidgetTester tester, {String? url}) async {
  await tester.pumpWidget(createTestApp(
    child: Builder(builder: (context) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          showModalBottomSheet<dynamic>(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => YoutubePlaylistSheet(
              playlistUrl:
                  url ?? 'https://www.youtube.com/playlist?list=PLTEST123',
            ),
          );
        }
      });
      return const SizedBox.shrink();
    }),
  ));
}

Future<void> _pumpUntilError(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (find.text('RETRY').evaluate().isNotEmpty) return;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('YoutubePlaylistSheet', () {
    testWidgets('shows loading then a failure state for a valid URL',
        (tester) async {
      _big(tester);
      await _pumpSheet(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(YoutubePlaylistSheet), findsOneWidget);
      expect(find.text('YOUTUBE PLAYLIST'), findsOneWidget);
      expect(find.text('Loading playlist...'), findsOneWidget);

      await _pumpUntilError(tester);
      _drain(tester);

      expect(
        find.text('Failed to load playlist. Check the URL and try again.'),
        findsOneWidget,
      );
      expect(find.text('RETRY'), findsOneWidget);

      await tester.tap(find.text('RETRY'));
      await tester.pump();
      expect(find.text('Loading playlist...'), findsOneWidget);

      await _pumpUntilError(tester);
      _drain(tester);
      expect(find.text('RETRY'), findsOneWidget);
    });

    testWidgets('an invalid playlist URL surfaces the error state',
        (tester) async {
      _big(tester);
      await _pumpSheet(tester, url: 'https://example.com/not-a-playlist');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await _pumpUntilError(tester);
      _drain(tester);
      expect(find.text('RETRY'), findsOneWidget);
      expect(find.text('YOUTUBE PLAYLIST'), findsOneWidget);

      await tester.tap(find.text('RETRY'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await _pumpUntilError(tester);
      _drain(tester);
      expect(find.text('RETRY'), findsOneWidget);
    });
  });
}
