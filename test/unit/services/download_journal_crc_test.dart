import 'package:dmx/core/services/download_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadJournal CRC32', () {
    test('crc32 produces consistent checksums', () {
      final data = [72, 101, 108, 108, 111]; // "Hello"
      final crc1 = DownloadJournal.crc32(data);
      final crc2 = DownloadJournal.crc32(data);
      expect(crc1, equals(crc2));
      expect(crc1, isNot(equals(0)));
    });

    test('different payloads produce different checksums', () {
      final crc1 = DownloadJournal.crc32([1, 2, 3]);
      final crc2 = DownloadJournal.crc32([1, 2, 4]);
      expect(crc1, isNot(equals(crc2)));
    });

    test('empty byte array produces valid non-zero CRC', () {
      final crc = DownloadJournal.crc32([]);
      expect(crc, equals(0x00000000));
    });
  });
}
