import 'dart:async';

import 'package:dmx/core/services/share_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() {
  late ShareService service;

  setUp(() {
    service = ShareService();
    service.dispose();
  });

  tearDown(() {
    service.dispose();
  });

  group('ShareService.handleUrl', () {
    test('ignores null, empty and whitespace-only input', () {
      service.handleUrl(null, source: 'test');
      service.handleUrl('', source: 'test');
      service.handleUrl('    ', source: 'test');
      expect(service.isInitialized, isFalse);
    });

    test('rejects non-downloadable schemes', () {
      service.handleUrl('ftp://example.com/file', source: 'test');
      service.handleUrl('javascript:alert(1)', source: 'test');
      service.handleUrl('just some text', source: 'test');
      expect(service.isInitialized, isFalse);
    });

    test('accepts http, magnet and torrent URLs', () {
      service.handleUrl('https://example.com/file.zip', source: 'test');
      service.handleUrl(
        'magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10',
        source: 'test',
      );
      service.handleUrl('https://example.com/file.torrent', source: 'test');
    });

    test('extracts an embedded URL from surrounding text', () {
      service.handleUrl(
        'Check this out https://example.com/download.zip right now',
        source: 'test',
      );
    });

    test('deduplicates identical URLs inside the dedup window', () {
      service.handleUrl('https://example.com/dup.zip', source: 'a');
      service.handleUrl('https://example.com/dup.zip', source: 'b');
    });

    test('drops intents when the arrival queue floods', () {
      for (var i = 0; i < 10; i++) {
        service.handleUrl('https://example.com/flood$i.zip', source: 'test');
      }
    });

    test('init consumes initial media and stream events exactly once',
        () async {
      final controller = StreamController<List<SharedMediaFile>>.broadcast();
      ReceiveSharingIntent.setMockValues(
        initialMedia: [
          SharedMediaFile(
            path: 'https://example.com/init.zip',
            type: SharedMediaType.file,
          ),
        ],
        mediaStream: controller.stream,
      );

      final received = <String>[];
      service.init(
        onUrlReceived: (url, {isInitial = false}) =>
            received.add('$isInitial:$url'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.isInitialized, isTrue);
      expect(received.any((r) => r.startsWith('true:')), isTrue);

      controller.add([
        SharedMediaFile(
          path: 'https://example.com/stream.zip',
          type: SharedMediaType.file,
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received.any((r) => r.startsWith('false:')), isTrue);

      // Re-init short-circuits reprocessing of the already-consumed initial media.
      service.init(onUrlReceived: (url, {isInitial = false}) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      service.dispose();
      await controller.close();
    });
  });
}
