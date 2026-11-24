import 'package:dmx/core/services/widget_deep_link.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    WidgetDeepLinkHandler.navigatorKey = null;
  });

  group('WidgetDeepLinkHandler.isValidDeepLink', () {
    test('rejects empty and blank input', () {
      expect(WidgetDeepLinkHandler.isValidDeepLink(''), isFalse);
      expect(WidgetDeepLinkHandler.isValidDeepLink('   '), isFalse);
    });

    test('accepts magnet and torrent links', () {
      expect(
        WidgetDeepLinkHandler.isValidDeepLink(
          'magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10',
        ),
        isTrue,
      );
      expect(
        WidgetDeepLinkHandler.isValidDeepLink(
            'https://example.com/file.torrent'),
        isTrue,
      );
      expect(
        WidgetDeepLinkHandler.isValidDeepLink('magnet:?dn=test'),
        isTrue,
      );
    });

    test('accepts dmx and xdm schemes with known routes', () {
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://downloads'), isTrue);
      expect(WidgetDeepLinkHandler.isValidDeepLink('xdm://settings'), isTrue);
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://pause_all'), isTrue);
      expect(
        WidgetDeepLinkHandler.isValidDeepLink('dmx://resume-all'),
        isTrue,
      );
      expect(
        WidgetDeepLinkHandler.isValidDeepLink('dmx://category/video'),
        isTrue,
      );
    });

    test('rejects unknown routes and schemes', () {
      expect(WidgetDeepLinkHandler.isValidDeepLink('dmx://nope'), isFalse);
      expect(WidgetDeepLinkHandler.isValidDeepLink('http://example.com/a.zip'),
          isFalse);
      expect(
          WidgetDeepLinkHandler.isValidDeepLink('ftp://example.com'), isFalse);
    });
  });

  group('WidgetDeepLinkHandler.handleUrl without a navigator', () {
    test('ignores invalid links', () {
      expect(
          () => WidgetDeepLinkHandler.handleUrl('nonsense'), returnsNormally);
      expect(() => WidgetDeepLinkHandler.handleUrl(''), returnsNormally);
    });

    test('handles every recognized route without throwing', () {
      const urls = [
        'dmx://downloads',
        'dmx://download/task-1',
        'dmx://toggle/task-1',
        'dmx://pause/task-1',
        'dmx://cancel/task-1',
        'dmx://resume/task-1',
        'dmx://open/task-1',
        'dmx://settings',
        'dmx://settings/general',
        'dmx://category/video',
        'dmx://category/audio',
        'dmx://category/documents',
        'dmx://category/archive',
        'dmx://category/apk',
        'dmx://category/custom',
        'dmx://add?url=https%3A%2F%2Fexample.com%2Fa.zip',
        'dmx://share?url=https%3A%2F%2Fexample.com%2Fb.zip',
        'dmx://pause_all',
        'dmx://pause-all',
        'dmx://resume_all',
        'dmx://resume-all',
      ];
      for (final url in urls) {
        expect(() => WidgetDeepLinkHandler.handleUrl(url), returnsNormally,
            reason: url);
      }
    });

    test('handles magnet and torrent add links', () {
      expect(
        () => WidgetDeepLinkHandler.handleUrl(
          'magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10',
        ),
        returnsNormally,
      );
      expect(
        () => WidgetDeepLinkHandler.handleUrl(
          'https://example.com/file.torrent',
        ),
        returnsNormally,
      );
    });

    test('rejects an invalid target scheme in add query', () {
      expect(
        () => WidgetDeepLinkHandler.handleUrl('dmx://add?url=javascript:alert'),
        returnsNormally,
      );
    });

    test('init stores the navigator key and registers a handler', () {
      WidgetDeepLinkHandler.init();
      expect(WidgetDeepLinkHandler.navigatorKey, isNull);
    });

    test('init forwards onOpenUrl platform messages to handleUrl', () async {
      WidgetDeepLinkHandler.init();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        'com.dmx.app/widget_bridge',
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('onOpenUrl', 'dmx://downloads')),
        (_) {},
      );
      await messenger.handlePlatformMessage(
        'com.dmx.app/widget_bridge',
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('onOpenUrl', null)),
        (_) {},
      );
      expect(WidgetDeepLinkHandler.navigatorKey, isNull);
    });
  });
}
