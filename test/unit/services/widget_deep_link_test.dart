import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/widget_deep_link.dart';
import '../../helpers/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WidgetDeepLinkHandler Unit Tests', () {
    testWidgets(
        'Asserts every registered deep link route is handled without throwing',
        (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      WidgetDeepLinkHandler.navigatorKey = navKey;

      await tester.pumpWidget(
        createTestApp(
          child: MaterialApp(
            navigatorKey: navKey,
            home: const Scaffold(body: Text('Home')),
          ),
        ),
      );

      final routesToTest = [
        'dmx://downloads',
        'dmx://download/task-123',
        'dmx://toggle/task-123',
        'dmx://pause/task-123',
        'dmx://resume/task-123',
        'dmx://open/task-123',
        'dmx://settings',
        'dmx://settings/general',
        'dmx://settings/network',
        'dmx://settings/appearance',
        'dmx://settings/advanced',
        'dmx://category/Video',
        'dmx://category/Audio',
        'dmx://category/Document',
        'dmx://category/Archive',
        'dmx://category/APK',
        'dmx://category/Other',
        'dmx://add?url=https%3A%2F%2Fexample.com%2Ffile.zip',
        'dmx://share?url=https%3A%2F%2Fexample.com%2Ffile.zip',
        'dmx://pause_all',
        'dmx://resume_all',
        'dmx://pause-all',
        'dmx://resume-all',
      ];

      for (final route in routesToTest) {
        expect(() => WidgetDeepLinkHandler.handleUrl(route), returnsNormally);
      }
    });
  });
}
