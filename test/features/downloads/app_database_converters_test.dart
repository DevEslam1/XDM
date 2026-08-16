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
  });
}
