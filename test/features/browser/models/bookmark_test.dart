import 'package:dmx/core/app_theme.dart';
import 'package:dmx/features/browser/models/bookmark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Bookmark Model Tests', () {
    test('initial returns first uppercase character of title or domain', () {
      final b1 = Bookmark(
          id: '1',
          title: 'Google',
          url: 'https://google.com',
          createdAt: DateTime.now());
      expect(b1.initial, 'G');

      final b2 = Bookmark(
          id: '2',
          title: '',
          url: 'https://youtube.com',
          createdAt: DateTime.now());
      expect(b2.initial, 'Y');
    });

    test('accentColor returns consistent color from AppTheme.bookmarkPalette',
        () {
      final b1 = Bookmark(
          id: '1',
          title: 'Example',
          url: 'https://example.com',
          createdAt: DateTime.now());
      final b2 = Bookmark(
          id: '2',
          title: 'Example',
          url: 'https://example.com',
          createdAt: DateTime.now());
      expect(b1.accentColor, b2.accentColor);
      expect(AppTheme.bookmarkPalette.contains(b1.accentColor), isTrue);
    });

    test('JSON serialization round-trip works correctly', () {
      final now = DateTime.now();
      final original = Bookmark(
        id: 'bm-1',
        title: 'Flutter',
        url: 'https://flutter.dev',
        folder: 'Dev',
        createdAt: now,
      );

      final json = original.toJson();
      final fromJson = Bookmark.fromJson(json);

      expect(fromJson.id, original.id);
      expect(fromJson.title, original.title);
      expect(fromJson.url, original.url);
      expect(fromJson.folder, original.folder);
    });

    test('domain strips www and falls back to the raw url on parse failure',
        () {
      final withWww = Bookmark(
          id: '1',
          title: 't',
          url: 'https://www.example.com/path',
          createdAt: DateTime.now());
      expect(withWww.domain, 'example.com');

      final noHost = Bookmark(
          id: '2', title: 't', url: 'not-a-url', createdAt: DateTime.now());
      expect(noHost.domain, 'not-a-url');

      final malformed = Bookmark(
          id: '3', title: 't', url: 'http://[', createdAt: DateTime.now());
      expect(malformed.domain, 'http://[');
    });

    test('initial returns ? when both title and domain are empty', () {
      final b =
          Bookmark(id: '1', title: '', url: '', createdAt: DateTime.now());
      expect(b.initial, '?');
    });

    test('copyWith updates fields and clearFolder removes the folder', () {
      final original = Bookmark(
          id: '1',
          title: 'Title',
          url: 'https://a.com',
          folder: 'F',
          createdAt: DateTime.now());

      final updated = original.copyWith(title: 'New', url: 'https://b.com');
      expect(updated.title, 'New');
      expect(updated.url, 'https://b.com');
      expect(updated.folder, 'F');
      expect(updated.id, original.id);
      expect(updated.createdAt, original.createdAt);

      final cleared = original.copyWith(clearFolder: true);
      expect(cleared.folder, isNull);
    });

    test('toMap/fromMap handle missing fields with defaults', () {
      final fromEmpty = Bookmark.fromMap(const {});
      expect(fromEmpty.id, '');
      expect(fromEmpty.title, '');
      expect(fromEmpty.url, '');
      expect(fromEmpty.folder, isNull);
      expect(fromEmpty.createdAt,
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    });

    test('parseTimestamp supports int, num, ISO string, numeric string', () {
      expect(Bookmark.parseTimestamp(1000).millisecondsSinceEpoch, 1000);
      expect(Bookmark.parseTimestamp(1000.9).millisecondsSinceEpoch, 1000);
      final iso = DateTime(2020, 1, 2, 3, 4, 5);
      expect(Bookmark.parseTimestamp(iso.toIso8601String()), iso);
      expect(Bookmark.parseTimestamp('5000').millisecondsSinceEpoch, 5000);
      expect(Bookmark.parseTimestamp('not-a-date').millisecondsSinceEpoch, 0);
      expect(Bookmark.parseTimestamp(null).millisecondsSinceEpoch, 0);
      expect(Bookmark.parseTimestamp('').millisecondsSinceEpoch, 0);
    });

    test('equality is based on id only and hashCode matches', () {
      final now = DateTime.now();
      final a = Bookmark(
          id: 'same', title: 'A', url: 'https://a.com', createdAt: now);
      final b = Bookmark(
          id: 'same', title: 'B', url: 'https://b.com', createdAt: now);
      final c = Bookmark(
          id: 'other', title: 'A', url: 'https://a.com', createdAt: now);

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
      expect(a == a, isTrue);
      expect(a == Object(), isFalse);
    });
  });
}
