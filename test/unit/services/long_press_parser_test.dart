import 'package:dmx/features/browser/services/long_press_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LongPressPayload.tryParse', () {
    test('parses a valid JSON payload', () {
      final payload = LongPressPayload.tryParse(
        '{"url":"https://example.com/a.mp4","type":"video","text":"Sample"}',
      );
      expect(payload, isNotNull);
      expect(payload!.url, 'https://example.com/a.mp4');
      expect(payload.type, 'video');
      expect(payload.text, 'Sample');
    });

    test('normalizes type to lowercase and trims url', () {
      final payload = LongPressPayload.tryParse(
        '{"url":"  https://example.com/b.png  ","type":"IMAGE"}',
      );
      expect(payload, isNotNull);
      expect(payload!.url, 'https://example.com/b.png');
      expect(payload.type, 'image');
    });

    test('returns null for empty or invalid input', () {
      expect(LongPressPayload.tryParse(''), isNull);
      expect(LongPressPayload.tryParse('not json'), isNull);
      expect(LongPressPayload.tryParse('{"url":""}'), isNull);
      expect(LongPressPayload.tryParse('garbage 123'), isNull);
    });
  });

  group('filterSourcesForTarget', () {
    const sources = [
      MediaSourceItem(label: '720p', url: 'https://cdn.com/video/720p.mp4', type: 'video'),
      MediaSourceItem(label: '1080p', url: 'https://cdn.com/video/1080p.mp4', type: 'video'),
      MediaSourceItem(label: 'Audio', url: 'https://cdn.com/audio/english.m4a', type: 'audio'),
      MediaSourceItem(label: 'Other site', url: 'https://other.net/thing.mp4', type: 'video'),
    ];

    test('always includes the target url first', () {
      final filtered = filterSourcesForTarget(
        const [],
        'https://cdn.com/video/720p.mp4',
        'video',
      );
      expect(filtered.length, 1);
      expect(filtered.first.url, 'https://cdn.com/video/720p.mp4');
      expect(filtered.first.label, isNotEmpty);
    });

    test('includes same-type and same-base sources only', () {
      final filtered = filterSourcesForTarget(
        sources,
        'https://cdn.com/video/720p.mp4',
        'video',
      );
      final urls = filtered.map((s) => s.url).toList();
      expect(urls, contains('https://cdn.com/video/720p.mp4'));
      expect(urls, contains('https://cdn.com/video/1080p.mp4'));
      // Different host -> excluded.
      expect(urls, isNot(contains('https://other.net/thing.mp4')));
      // Different media type AND different base path -> not grouped in.
      expect(urls, isNot(contains('https://cdn.com/audio/english.m4a')));
    });

    test('deduplicates entries with the same url', () {
      final filtered = filterSourcesForTarget(
        sources,
        'https://cdn.com/video/720p.mp4',
        'video',
      );
      final urls = filtered.map((s) => s.url).toList();
      expect(urls.where((u) => u == 'https://cdn.com/video/720p.mp4').length, 1);
    });

    test('ignores empty source urls', () {
      final filtered = filterSourcesForTarget(
        const [MediaSourceItem(label: '', url: '', type: 'video')],
        'https://cdn.com/video/720p.mp4',
        'video',
      );
      expect(filtered.length, 1);
    });
  });
}
