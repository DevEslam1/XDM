import 'package:dmx/core/app_theme.dart';
import 'package:dmx/features/browser/models/bookmark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Bookmark Model Tests', () {
    test('initial returns first uppercase character of title or domain', () {
      final b1 = Bookmark(id: '1', title: 'Google', url: 'https://google.com', createdAt: DateTime.now());
      expect(b1.initial, 'G');

      final b2 = Bookmark(id: '2', title: '', url: 'https://youtube.com', createdAt: DateTime.now());
      expect(b2.initial, 'Y');
    });

    test('accentColor returns consistent color from AppTheme.bookmarkPalette', () {
      final b1 = Bookmark(id: '1', title: 'Example', url: 'https://example.com', createdAt: DateTime.now());
      final b2 = Bookmark(id: '2', title: 'Example', url: 'https://example.com', createdAt: DateTime.now());
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
  });
}
