import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/share_url_handler.dart';

void main() {
  group('ShareUrlHandler - App Intents & Deep Links', () {
    String? receivedUrl;
    bool pauseAllCalled = false;
    bool resumeAllCalled = false;

    setUp(() {
      receivedUrl = null;
      pauseAllCalled = false;
      resumeAllCalled = false;
      ShareUrlHandler.setPauseAllCallback(() => pauseAllCalled = true);
      ShareUrlHandler.setResumeAllCallback(() => resumeAllCalled = true);
    });

    test('handles dmx://share?url= deep link', () async {
      final uri = Uri.parse('dmx://share?url=https://example.com/file.zip');
      await ShareUrlHandler.handleDeepLink(uri,
          onUrl: (url) => receivedUrl = url);

      expect(receivedUrl, equals('https://example.com/file.zip'));
    });

    test('handles dmx://pause-all deep link', () async {
      final uri = Uri.parse('dmx://pause-all');
      await ShareUrlHandler.handleDeepLink(uri, onUrl: (_) {});

      expect(pauseAllCalled, isTrue);
    });

    test('handles dmx://resume-all deep link', () async {
      final uri = Uri.parse('dmx://resume-all');
      await ShareUrlHandler.handleDeepLink(uri, onUrl: (_) {});

      expect(resumeAllCalled, isTrue);
    });

    test('ignores non-dmx schemes', () async {
      final uri = Uri.parse('https://example.com');
      await ShareUrlHandler.handleDeepLink(uri,
          onUrl: (url) => receivedUrl = url);

      expect(receivedUrl, isNull);
    });

    test('ignores unknown dmx hosts', () async {
      final uri = Uri.parse('dmx://unknown-action');
      await ShareUrlHandler.handleDeepLink(uri,
          onUrl: (url) => receivedUrl = url);

      expect(receivedUrl, isNull);
      expect(pauseAllCalled, isFalse);
    });

    test('handles URL-encoded share URLs', () async {
      final uri = Uri.parse(
        'dmx://share?url=magnet%3A%3Fxt%3Durn%3Abtih%3Ac12fe1c06bba254a9dc9f519b335aa7c1367a88a',
      );
      await ShareUrlHandler.handleDeepLink(uri,
          onUrl: (url) => receivedUrl = url);

      expect(receivedUrl, contains('magnet:'));
    });
  });
}
