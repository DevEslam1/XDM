import 'package:dmx/core/services/widget_deep_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WidgetDeepLinkHandler Tests (I-01 / I-02)', () {
    test('isValidDeepLink accepts valid dmx and xdm URIs (I-01)', () {
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://downloads'), isTrue);
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://download/task-123'),
          isTrue);
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://pause/task-123'),
          isTrue);
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://resume/task-123'),
          isTrue);
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://settings/network'),
          isTrue);
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://category/video'),
          isTrue);
      expect(
          WidgetDeepLinkHandler.isValidDeepLink(
              'dmx://add?url=https%3A%2F%2Fexample.com%2Ffile.zip'),
          isTrue);
      expect(WidgetDeepLinkHandler.isValidDeepLink('xdm://downloads'), isTrue);
    });

    test(
        'isValidDeepLink rejects invalid schemes, empty strings and malformed routes (I-02)',
        () {
      expect(WidgetDeepLinkHandler.isValidDeepLink(''), isFalse);
      expect(
          WidgetDeepLinkHandler.isValidDeepLink('http://example.com'), isFalse);
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://unknown_route/123'),
          isFalse);
      expect(WidgetDeepLinkHandler.isValidDeepLink('javascript:alert(1)'),
          isFalse);
      expect(
          WidgetDeepLinkHandler.isValidDeepLink('file:///etc/passwd'), isFalse);
    });
  });
}
