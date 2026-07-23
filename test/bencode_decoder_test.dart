import 'dart:convert';
import 'dart:typed_data';
import 'package:dmx/core/utils/bencode_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BencodeDecoder — decodeInt', () {
    test('positive integer', () {
      expect(BencodeDecoder(utf8.encode('i42e')).decode(), 42);
    });

    test('negative integer', () {
      expect(BencodeDecoder(utf8.encode('i-42e')).decode(), -42);
    });

    test('zero', () {
      expect(BencodeDecoder(utf8.encode('i0e')).decode(), 0);
    });

    test('rejects negative zero', () {
      expect(
        () => BencodeDecoder(utf8.encode('i-0e')).decode(),
        throwsFormatException,
      );
    });

    test('rejects leading zero', () {
      expect(
        () => BencodeDecoder(utf8.encode('i042e')).decode(),
        throwsFormatException,
      );
    });

    test('rejects unterminated integer', () {
      expect(
        () => BencodeDecoder(utf8.encode('i42')).decode(),
        throwsFormatException,
      );
    });

    test('rejects empty integer', () {
      expect(
        () => BencodeDecoder(utf8.encode('ie')).decode(),
        throwsFormatException,
      );
    });
  });

  group('BencodeDecoder — decodeBytes', () {
    test('decodes valid byte string', () {
      final result = BencodeDecoder(utf8.encode('4:spam')).decode();
      expect(result, isA<Uint8List>());
      expect(utf8.decode(result as Uint8List), 'spam');
    });

    test('decodes zero-length string', () {
      final result = BencodeDecoder(utf8.encode('0:')).decode();
      expect(result, isA<Uint8List>());
      expect((result as Uint8List).length, 0);
    });

    test('rejects length exceeding data', () {
      expect(
        () => BencodeDecoder(utf8.encode('10:short')).decode(),
        throwsFormatException,
      );
    });

    test('rejects missing colon', () {
      expect(
        () => BencodeDecoder(utf8.encode('4spam')).decode(),
        throwsFormatException,
      );
    });
  });

  group('BencodeDecoder — decodeList', () {
    test('decodes empty list', () {
      expect(BencodeDecoder(utf8.encode('le')).decode(), []);
    });

    test('decodes list of integers', () {
      expect(BencodeDecoder(utf8.encode('li1ei2ei3ee')).decode(), [1, 2, 3]);
    });

    test('decodes mixed list', () {
      final result = BencodeDecoder(utf8.encode('li1e2:hie')).decode();
      expect(result, isA<List>());
      expect((result as List)[0], 1);
      expect(utf8.decode((result[1] as Uint8List)), 'hi');
    });

    test('rejects unterminated list', () {
      expect(
        () => BencodeDecoder(utf8.encode('li1ei2e')).decode(),
        throwsFormatException,
      );
    });
  });

  group('BencodeDecoder — decodeDict', () {
    test('decodes empty dict', () {
      expect(BencodeDecoder(utf8.encode('de')).decode(), {});
    });

    test('decodes string->int dict', () {
      final result = BencodeDecoder(utf8.encode('d3:keyi42ee')).decode();
      expect(result, isA<Map>());
      expect((result as Map)['key'], 42);
    });

    test('decodes nested dict', () {
      final raw = utf8.encode('d4:infod4:name4:test6:lengthi100eee');
      final result = BencodeDecoder(raw).decode();
      expect(result, isA<Map>());
      final info = (result as Map)['info'];
      expect(info, isA<Map>());
      expect(info['name'], isA<Uint8List>());
      expect(utf8.decode(info['name'] as Uint8List), 'test');
      expect(info['length'], 100);
    });

    test('info dict captures info_bytes', () {
      final raw = utf8.encode('d4:infod4:name4:test6:lengthi100eee');
      final result = BencodeDecoder(raw).decode();
      expect((result as Map)['info_bytes'], isA<Uint8List>());
      expect((result['info_bytes'] as Uint8List).isNotEmpty, isTrue);
    });

    test('rejects unterminated dict', () {
      expect(
        () => BencodeDecoder(utf8.encode('d3:keyi42e')).decode(),
        throwsFormatException,
      );
    });
  });

  group('BencodeDecoder — nesting depth', () {
    test('100 levels deep succeeds', () {
      // Build a list nested 100 deep: lll...le...e
      final raw = StringBuffer();
      for (int i = 0; i < 100; i++) {
        raw.write('l');
      }
      raw.write('e');
      for (int i = 0; i < 100; i++) {
        raw.write('e');
      }
      expect(BencodeDecoder(utf8.encode(raw.toString())).decode(), isA<List>());
    });

    test('102 levels deep throws', () {
      final raw = StringBuffer();
      for (int i = 0; i < 102; i++) {
        raw.write('l');
      }
      raw.write('e');
      for (int i = 0; i < 102; i++) {
        raw.write('e');
      }
      expect(
        () => BencodeDecoder(utf8.encode(raw.toString())).decode(),
        throwsFormatException,
      );
    });
  });

  group('BencodeDecoder — parseTorrentBytes', () {
    test('single-file torrent', () {
      // d8:announce11:http://t.eri<length>4:infod6:lengthi1000e4:name4:test12:piece lengthi32768e6:pieces20:aaaaaaaaaaaaaaaaaaaaee
      final raw = utf8.encode(
        'd8:announce19:http://tracker.test4:infod6:lengthi1000e4:name4:test12:piece lengthi32768e6:pieces20:aaaaaaaaaaaaaaaaaaaaee',
      );
      final result = BencodeDecoder.parseTorrentBytes(raw);
      expect(result, isNotNull);
      expect(result!['name'], 'test');
      expect(result['length'], 1000);
      expect(result['infoHash'], isA<String>());
      expect((result['infoHash'] as String).length, 40);
      expect(result['files'], isA<List>());
      expect((result['files'] as List).length, 1);
      expect((result['files'] as List).first['name'], 'test');
    });

    test('multi-file torrent', () {
      // Build raw bytes directly to avoid encoding errors
      final raw = Uint8List.fromList([
        ...utf8.encode(
          'd8:announce19:http://tracker.test',
        ), // outer dict start + announce
        ...utf8.encode('4:info'), // key "info"
        ...utf8.encode('d'), // info dict start
        ...utf8.encode('5:files'), // key "files"
        ...utf8.encode('l'), // files list start
        // ---- file 1 ----
        ...utf8.encode('d6:lengthi500e4:pathl3:sub5:file1ee'),
        // ---- file 2 ----
        ...utf8.encode('d6:lengthi300e4:pathl3:sub5:file2ee'),
        ...utf8.encode('e'), // files list end
        ...utf8.encode('4:name4:root'), // name = "root"
        ...utf8.encode('12:piece lengthi32768e'), // piece length
        ...utf8.encode('6:pieces20:bbbbbbbbbbbbbbbbbbbb'), // pieces
        ...utf8.encode('ee'), // info end + outer end
      ]);
      final result = BencodeDecoder.parseTorrentBytes(raw);
      expect(result, isNotNull);
      expect(result!['name'], 'root');
      expect(result['length'], 800);
      expect((result['files'] as List).length, 2);
      expect((result['files'] as List)[0]['name'], 'sub/file1');
      expect((result['files'] as List)[1]['name'], 'sub/file2');
    });

    test('corrupt data returns null', () {
      final result = BencodeDecoder.parseTorrentBytes(
        utf8.encode('invalid bencode data'),
      );
      expect(result, isNull);
    });

    test('not a dict returns null', () {
      final result = BencodeDecoder.parseTorrentBytes(utf8.encode('i42e'));
      expect(result, isNull);
    });
  });

  group('BencodeDecoder — toNormalTypes', () {
    test('converts Uint8List to string', () {
      final result = BencodeDecoder.toNormalTypes(utf8.encode('hello'));
      expect(result, 'hello');
    });

    test('preserves binary keys', () {
      final result = BencodeDecoder.toNormalTypes(
        Uint8List.fromList([0, 1, 2, 3]),
        'pieces',
      );
      expect(result, isA<Uint8List>());
    });

    test('converts nested maps recursively', () {
      final input = {
        utf8.encode('key1'): utf8.encode('value1'),
        utf8.encode('key2'): [utf8.encode('item1'), utf8.encode('item2')],
      };
      final result = BencodeDecoder.toNormalTypes(input);
      expect(result, isA<Map>());
      expect((result as Map)['key1'], 'value1');
      expect((result)['key2'], isA<List>());
      expect((result)['key2'][0], 'item1');
    });
  });

  group('BencodeDecoder — integration', () {
    test('real-world torrent-like structure round-trip', () {
      final raw = utf8.encode('d1:ai42e1:b2:hi1:clli1ei2eeli3eee1:di42ee');
      final result = BencodeDecoder(raw).decode();
      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['a'], 42);
      expect(utf8.decode(map['b'] as Uint8List), 'hi');
      expect(map['c'], isA<List>());
      expect((map['c'] as List)[0], [1, 2]);
      expect((map['c'] as List)[1], [3]);
      expect(map['d'], 42);
    });
  });
}
