import 'package:dmx/core/services/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DoubleListConverter Tests', () {
    const converter = DoubleListConverter();

    test('valid json list encodes and decodes properly', () {
      final list = [0.0, 0.5, 1.0];
      final sql = converter.toSql(list);
      expect(converter.fromSql(sql), equals(list));
    });

    test('empty or whitespace string returns empty list without throwing', () {
      expect(converter.fromSql(''), isEmpty);
      expect(converter.fromSql('   '), isEmpty);
    });

    test('corrupt json string returns empty list without throwing', () {
      expect(converter.fromSql('{corrupt json'), isEmpty);
      expect(converter.fromSql('12345'), isEmpty);
      expect(converter.fromSql('null'), isEmpty);
    });
  });

  group('TorrentFilesConverter Tests', () {
    const converter = TorrentFilesConverter();

    test('valid json map list encodes and decodes properly', () {
      final files = [
        {'name': 'file1.mp4', 'length': 1024, 'selected': true}
      ];
      final sql = converter.toSql(files);
      final decoded = converter.fromSql(sql);
      expect(decoded.length, 1);
      expect(decoded.first['name'], 'file1.mp4');
    });

    test('empty string returns empty list', () {
      expect(converter.fromSql(''), isEmpty);
    });

    test('corrupt json string returns empty list without throwing', () {
      expect(converter.fromSql('invalid json'), isEmpty);
      expect(converter.fromSql('{"not_a": "list"}'), isEmpty);
    });
  });
}
