import 'dart:convert';
import 'dart:io';

import 'package:dmx/core/services/widget_deep_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Widget Deep Link Complete Routing Table Tests [W-13]', () {
    late Map<String, dynamic> fixture;

    setUpAll(() {
      final file = File('test/fixtures/deep_links.json');
      expect(file.existsSync(), isTrue);
      fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    });

    test('All fixture valid routes resolve to recognized handlers', () {
      final validUrls = (fixture['routes'] as List).cast<String>();
      for (final url in validUrls) {
        expect(
          WidgetDeepLinkHandler.isValidDeepLink(url),
          isTrue,
          reason: 'Deep link "$url" must be valid and route to a handler',
        );
      }
    });

    test('Invalid routes in fixture are safely rejected', () {
      final invalidUrls = (fixture['invalidRoutes'] as List).cast<String>();
      for (final url in invalidUrls) {
        expect(
          WidgetDeepLinkHandler.isValidDeepLink(url),
          isFalse,
          reason: 'Invalid route "$url" must be rejected',
        );
      }
    });
  });
}
