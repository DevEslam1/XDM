import 'package:dmx/core/services/widget_deep_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('App Flow & Deep Link Integration Tests [N-2]', () {
    testWidgets('Widget deep link router validation in integration environment', (tester) async {
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://downloads'), isTrue);
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://add'), isTrue);
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://pause_all'), isTrue);
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://resume_all'), isTrue);
    });
  });
}
