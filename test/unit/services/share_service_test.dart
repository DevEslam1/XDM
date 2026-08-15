import 'package:dmx/core/services/share_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ShareService shareService;
  late List<String> receivedUrls;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('receive_sharing_intent/messages'),
      (methodCall) async {
        if (methodCall.method == 'getInitialMedia') {
          return '[]';
        }
        return null;
      },
    );

    shareService = ShareService();
    receivedUrls = [];
    shareService.init(
      onUrlReceived: (url, {bool isInitial = false}) {
        receivedUrls.add(url);
      },
    );
  });

  tearDown(() {
    shareService.dispose();
  });

  group('ShareService Hardening Unit Tests', () {
    test('Dedup: same URL twice within 2s → second is dropped', () async {
      const url = 'https://example.com/file.zip';

      shareService.handleUrl(url, source: 'media_stream');
      expect(receivedUrls, equals([url]));

      // Immediate second share within 2s
      shareService.handleUrl(url, source: 'initial_media');
      expect(receivedUrls, equals([url])); // Second is dropped
    });

    test('Dedup: same URL after 2s → second is accepted', () async {
      const url = 'https://example.com/file2.zip';

      shareService.handleUrl(url, source: 'media_stream');
      expect(receivedUrls, equals([url]));

      // Wait 2.1 seconds for dedup window to pass
      await Future<void>.delayed(const Duration(milliseconds: 2100));

      shareService.handleUrl(url, source: 'media_stream');
      expect(receivedUrls, equals([url, url])); // Second is accepted
    });

    test('Flood: 6 URLs in 1s → oldest dropped, warning logged', () {
      final urls = List.generate(6, (i) => 'https://example.com/item_$i.mp4');

      for (final url in urls) {
        shareService.handleUrl(url, source: 'media_stream');
      }

      // Max 5 items per second allowed; 6th triggers flood protection and is dropped
      expect(receivedUrls.length, equals(5));
      expect(receivedUrls.contains(urls.last), isFalse);
    });

    test('Invalid scheme rejected and logged', () {
      const invalidUrl = 'ftp://example.com/file.txt';

      shareService.handleUrl(invalidUrl, source: 'media_stream');
      expect(receivedUrls, isEmpty);
    });
  });
}
