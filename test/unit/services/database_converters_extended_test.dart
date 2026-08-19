import 'package:dmx/core/services/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Database Converters Hardening', () {
    test('TorrentFilesConverter handles invalid or empty JSON safely', () {
      const converter = TorrentFilesConverter();

      expect(converter.fromSql(''), isEmpty);
      expect(converter.fromSql('   '), isEmpty);
      expect(converter.fromSql('not-a-json'), isEmpty);
      expect(converter.fromSql('{"not":"a list"}'), isEmpty);
    });

    test('TorrentFilesConverter serializes safely even with unusual objects', () {
      const converter = TorrentFilesConverter();

      final list = [
        {'name': 'file1.mp4', 'size': 1024, 'valid': true},
        {'name': 'file2.mkv', 'size': 2048, 'custom': DateTime.now()}
      ];

      final sql = converter.toSql(list);
      expect(sql.isNotEmpty, isTrue);

      final decoded = converter.fromSql(sql);
      expect(decoded.length, 2);
      expect(decoded[0]['name'], 'file1.mp4');
      expect(decoded[0]['size'], 1024);
    });

    test('DoubleListConverter handles valid and invalid lists gracefully', () {
      const converter = DoubleListConverter();

      expect(converter.fromSql(''), isEmpty);
      expect(converter.fromSql('[1, 2.5, 3]'), [1.0, 2.5, 3.0]);
      expect(converter.fromSql('["invalid", 4]'), [0.0, 4.0]);
      expect(converter.fromSql('not-valid-json'), isEmpty);
    });
  });
}
