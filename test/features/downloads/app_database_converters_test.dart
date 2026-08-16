import 'package:dmx/core/services/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppDatabase Converters (Sprint 2)', () {
    test('DoubleListConverter recovers from malformed json', () {
      const converter = DoubleListConverter();
      expect(converter.fromSql('[0.25, 0.5, 0.75]'), equals([0.25, 0.5, 0.75]));

      // Malformed array string
      final recovered = converter.fromSql('[0.1, 0.2, corrupt_token, 0.9]');
      expect(recovered, containsAllInOrder([0.1, 0.2, 0.9]));
    });

    test('TorrentFilesConverter recovers from malformed json', () {
      const converter = TorrentFilesConverter();
      expect(converter.fromSql(''), isEmpty);

      const validJson = '[{"name": "file1.mp4", "downloadedBytes": 500}]';
      final files = converter.fromSql(validJson);
      expect(files.length, equals(1));
      expect(files.first['name'], equals('file1.mp4'));
    });

    test('DoubleListConverter caches recovered values for repeat reads', () {
      const converter = DoubleListConverter();
      const corrupt = '[0.1, 0.2, corrupt_token, 0.9]';

      DoubleListConverter.clearRecoveryCache();
      final first = converter.fromSql(corrupt);
      expect(first, containsAllInOrder([0.1, 0.2, 0.9]));
      expect(DoubleListConverter.recoveryCacheLength, equals(1));

      // Second read of the same corrupted cell must hit the cache.
      final second = converter.fromSql(corrupt);
      expect(second, containsAllInOrder([0.1, 0.2, 0.9]));
      expect(DoubleListConverter.recoveryCacheLength, equals(1));
    });

    test('TorrentFilesConverter caches recovered values for repeat reads', () {
      const converter = TorrentFilesConverter();
      const corrupt =
          '[{"name": "f1.mp4", "downloadedBytes": 500}, bad_token]';

      TorrentFilesConverter.clearRecoveryCache();
      final first = converter.fromSql(corrupt);
      expect(first, isNotEmpty);
      expect(TorrentFilesConverter.recoveryCacheLength, equals(1));

      final second = converter.fromSql(corrupt);
      expect(second.length, equals(first.length));
      expect(TorrentFilesConverter.recoveryCacheLength, equals(1));
    });
  });
}
