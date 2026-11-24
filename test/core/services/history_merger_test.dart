import 'package:dmx/core/services/history_merger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mergeHistoryEntries', () {
    test('deduplicates by URL and counts visits', () {
      final result = mergeHistoryEntries([
        {'url': 'https://a.com', 'title': 'A', 'visitedAt': 100},
        {'url': 'https://a.com', 'title': 'A', 'visitedAt': 200},
        {'url': 'https://b.com', 'title': 'B', 'visitedAt': 100},
      ]);

      expect(result.failed, isEmpty);
      expect(result.merged.length, 2);
      final a = result.merged.firstWhere((m) => m.url == 'https://a.com');
      expect(a.visitCount, 2);
      expect(a.visitedAt, 200);
    });

    test('newer visit updates title but older does not', () {
      final result = mergeHistoryEntries([
        {'url': 'https://a.com', 'title': 'Old', 'visitedAt': 200},
        {'url': 'https://a.com', 'title': 'Newer', 'visitedAt': 100},
      ]);
      expect(result.merged.single.title, 'Old');

      final result2 = mergeHistoryEntries([
        {'url': 'https://a.com', 'title': 'Old', 'visitedAt': 100},
        {'url': 'https://a.com', 'title': 'Newer', 'visitedAt': 200},
      ]);
      expect(result2.merged.single.title, 'Newer');
    });

    test('favicon is captured and replaced when present', () {
      final result = mergeHistoryEntries([
        {'url': 'https://a.com', 'title': 'A', 'visitedAt': 1},
        {
          'url': 'https://a.com',
          'title': 'A',
          'visitedAt': 2,
          'faviconUrl': 'https://a.com/fav.ico',
        },
      ]);
      expect(result.merged.single.faviconUrl, 'https://a.com/fav.ico');
    });

    test('skips entries with empty URL', () {
      final result = mergeHistoryEntries([
        {'url': '', 'title': 'empty'},
        {'title': 'missing-url'},
      ]);
      expect(result.merged, isEmpty);
      expect(result.failed, isEmpty);
    });

    test('applies default title and visitedAt when absent', () {
      final result = mergeHistoryEntries([
        {'url': 'https://a.com'},
      ]);
      final item = result.merged.single;
      expect(item.title, 'https://a.com');
      expect(item.visitedAt, greaterThan(0));
    });

    test('non-map values are collected as failed', () {
      final result = mergeHistoryEntries(['nope', 42, null]);
      expect(result.merged, isEmpty);
      expect(result.failed.length, 3);
    });

    test('map that throws during parse is collected as failed', () {
      final result = mergeHistoryEntries([
        {'url': 123},
      ]);
      expect(result.merged, isEmpty);
      expect(result.failed.length, 1);
    });
  });
}
