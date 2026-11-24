import 'dart:convert';
import 'dart:typed_data';

import 'package:dmx/core/utils/bencode_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal bencode encoders so the extended cases below can be built without
/// hand-counting string lengths (the root-level test already covers the
/// hand-built fixtures).
String _s(String value) => '${value.length}:$value';

String _i(int value) => 'i${value}e';

String _d(Map<String, String> entries) =>
    'd${entries.entries.map((e) => '${_s(e.key)}${e.value}').join()}e';

String _l(List<String> items) => 'l${items.join()}e';

void main() {
  group('BencodeDecoder — additional error paths', () {
    test('rejects an invalid top-level character', () {
      expect(
        () => BencodeDecoder(utf8.encode('x')).decode(),
        throwsFormatException,
      );
      expect(
        () => BencodeDecoder(utf8.encode('e')).decode(),
        throwsFormatException,
      );
    });

    test('rejects a leading zero after the minus sign', () {
      expect(
        () => BencodeDecoder(utf8.encode('i-042e')).decode(),
        throwsFormatException,
      );
    });

    test('rejects a non-numeric integer body', () {
      expect(
        () => BencodeDecoder(utf8.encode('iabc e')).decode(),
        throwsFormatException,
      );
    });
  });

  group('BencodeDecoder — toNormalTypes invalid utf8', () {
    test('keeps raw bytes for non-binary keys that are not valid utf8', () {
      final raw = Uint8List.fromList([0xff, 0xfe, 0xfd]);
      final result = BencodeDecoder.toNormalTypes(raw, 'notbinary');
      expect(result, isA<Uint8List>());
    });

    test('decodes map keys that are Uint8List', () {
      final input = {
        Uint8List.fromList(utf8.encode('key')): 7,
      };
      final result = BencodeDecoder.toNormalTypes(input) as Map;
      expect(result['key'], 7);
    });
  });

  group('BencodeDecoder — parseTorrentBytes extended', () {
    test('returns null when the info value is not a map', () {
      final raw = utf8.encode(_d({'info': _i(42)}));
      expect(BencodeDecoder.parseTorrentBytes(raw), isNull);
    });

    test('reads the name.utf-8 field', () {
      final info = _d({
        'name.utf-8': _s('unicode-name'),
        'length': _i(10),
      });
      final result = BencodeDecoder.parseTorrentBytes(
        utf8.encode(_d({'info': info})),
      );
      expect(result!['name'], 'unicode-name');
      expect(result['length'], 10);
    });

    test('single-file torrent strips traversal from the display name', () {
      final info = _d({
        'name': _s('../../etc/passwd'),
        'length': _i(512),
      });
      final result = BencodeDecoder.parseTorrentBytes(
        utf8.encode(_d({'info': info})),
      );
      final files = result!['files'] as List;
      expect((files.first as Map)['name'], 'etc_passwd');
      expect(result['length'], 512);
    });

    test('pure v2 torrent parses the nested file tree', () {
      final fileTree = _d({
        'dir': _d({
          'sub': _d({
            'file.bin': _d({
              '': _d({'length': _i(50)}),
            }),
          }),
        }),
      });
      final info = _d({
        'meta version': _i(2),
        'file tree': fileTree,
        'name': _s('v2root'),
      });
      final result = BencodeDecoder.parseTorrentBytes(
        utf8.encode(_d({'info': info})),
      );
      expect(result, isNotNull);
      expect(result!['length'], 50);
      final files = result['files'] as List;
      expect((files.first as Map)['name'], 'dir/sub/file.bin');
      expect(result['infoHashV2'], isA<String>());
      expect((result['infoHashV2'] as String).length, 64);
      expect(result['isV2Only'], isTrue);
      expect(result['isHybrid'], isFalse);
    });

    test('v2 file tree with only traversal segments falls back to file_N', () {
      final fileTree = _d({
        '..': _d({
          '': _d({'length': _i(10)}),
        }),
      });
      final info = _d({
        'meta version': _i(2),
        'file tree': fileTree,
      });
      final result = BencodeDecoder.parseTorrentBytes(
        utf8.encode(_d({'info': info})),
      );
      final files = result!['files'] as List;
      final name = (files.first as Map)['name'] as String;
      expect(name, 'file_10');
    });

    test('hybrid torrent captures both v1 and v2 info hashes', () {
      final info = _d({
        'meta version': _i(2),
        'files': _l([
          _d({
            'length': _i(100),
            'path': _l([_s('file')]),
          }),
        ]),
        'file tree': _d({
          'root.txt': _d({
            '': _d({'length': _i(100)}),
          }),
        }),
        'pieces': _s(List.filled(20, 'a').join()),
        'name': _s('hybrid'),
      });
      final result = BencodeDecoder.parseTorrentBytes(
        utf8.encode(_d({'info': info})),
      );
      expect(result, isNotNull);
      expect(result!['isHybrid'], isTrue);
      expect(result['infoHashV1'], isA<String>());
      expect(result['infoHashV2'], isA<String>());
      expect(result['length'], 100);
    });

    test('multi-file torrent honors path.utf-8 and skips non-map entries', () {
      final info = _d({
        'files': _l([
          _d({
            'length': _i(20),
            'path.utf-8': _l([_s('sub'), _s('name.bin')]),
          }),
          _i(999),
        ]),
      });
      final result = BencodeDecoder.parseTorrentBytes(
        utf8.encode(_d({'info': info})),
      );
      expect(result, isNotNull);
      final files = result!['files'] as List;
      expect(files.length, 1);
      expect((files.first as Map)['name'], 'sub/name.bin');
      expect(result['length'], 20);
    });

    test('empty file list yields zero length', () {
      final info = _d({'files': _l([])});
      final result = BencodeDecoder.parseTorrentBytes(
        utf8.encode(_d({'info': info})),
      );
      expect(result!['length'], 0);
      expect((result['files'] as List), isEmpty);
    });

    test('rejects an integer that exceeds the native int64 range', () {
      expect(
        () => BencodeDecoder(utf8.encode('i9223372036854775808e')).decode(),
        throwsFormatException,
      );
    });

    test('rejects a byte string with a non-numeric length', () {
      expect(
        () => BencodeDecoder(utf8.encode('12abc:xx')).decode(),
        throwsFormatException,
      );
    });

    test('toNormalTypes recursively normalizes lists', () {
      final input = [
        utf8.encode('one'),
        [
          utf8.encode('two'),
        ],
      ];
      final result = BencodeDecoder.toNormalTypes(input) as List;
      expect(result[0], 'one');
      expect((result[1] as List)[0], 'two');
    });

    test('toNormalTypes keeps binary keys as raw bytes', () {
      final raw = Uint8List.fromList([1, 2, 3]);
      expect(BencodeDecoder.toNormalTypes(raw, 'pieces'), same(raw));
    });

    test('multi-file torrent with only traversal segments uses a fallback', () {
      final info = _d({
        'files': _l([
          _d({
            'length': _i(100),
            'path': _l([_s('..'), _s('..')]),
          }),
        ]),
      });
      final result = BencodeDecoder.parseTorrentBytes(
        utf8.encode(_d({'info': info})),
      );
      final files = result!['files'] as List;
      expect((files.first as Map)['name'], 'file_100');
    });

    test('corrupt input returns null instead of throwing', () {
      expect(
        BencodeDecoder.parseTorrentBytes(utf8.encode('not bencode at all')),
        isNull,
      );
    });
  });
}
