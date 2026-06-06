import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class BencodeDecoder {
  final Uint8List _data;
  int _offset = 0;

  BencodeDecoder(this._data);

  dynamic decode() {
    if (_offset >= _data.length) return null;
    final char = String.fromCharCode(_data[_offset]);
    if (char == 'i') {
      return _decodeInt();
    } else if (char == 'l') {
      return _decodeList();
    } else if (char == 'd') {
      return _decodeDict();
    } else if (RegExp(r'[0-9]').hasMatch(char)) {
      return _decodeBytes();
    }
    throw FormatException('Invalid bencode character: $char at $_offset');
  }

  int _decodeInt() {
    _offset++; // skip 'i'
    final start = _offset;
    while (_offset < _data.length && _data[_offset] != 101) { // 'e'
      _offset++;
    }
    if (_offset >= _data.length) {
      throw const FormatException('Unterminated bencode integer');
    }
    final numStr = utf8.decode(_data.sublist(start, _offset));
    _offset++; // skip 'e'
    return int.parse(numStr);
  }

  Uint8List _decodeBytes() {
    final start = _offset;
    while (_offset < _data.length && _data[_offset] != 58) { // ':'
      _offset++;
    }
    if (_offset >= _data.length) {
      throw const FormatException('Invalid bencode string length separator');
    }
    final lenStr = utf8.decode(_data.sublist(start, _offset));
    final len = int.parse(lenStr);
    _offset++; // skip ':'
    
    if (_offset + len > _data.length) {
      throw const FormatException('Bencode string length exceeds data size');
    }
    final bytes = _data.sublist(_offset, _offset + len);
    _offset += len;
    return bytes;
  }

  List<dynamic> _decodeList() {
    _offset++; // skip 'l'
    final list = <dynamic>[];
    while (_offset < _data.length && _data[_offset] != 101) { // 'e'
      list.add(decode());
    }
    if (_offset >= _data.length) {
      throw const FormatException('Unterminated bencode list');
    }
    _offset++; // skip 'e'
    return list;
  }

  Map<String, dynamic> _decodeDict() {
    _offset++; // skip 'd'
    final map = <String, dynamic>{};
    while (_offset < _data.length && _data[_offset] != 101) { // 'e'
      final keyBytes = _decodeBytes();
      final key = utf8.decode(keyBytes);
      
      // If the key is 'info', we want to capture the raw bytes of the info dictionary for info hash computation
      if (key == 'info') {
        final infoStart = _offset;
        final infoVal = decode();
        final infoEnd = _offset;
        map['info_bytes'] = _data.sublist(infoStart, infoEnd);
        map['info'] = infoVal;
      } else {
        map[key] = decode();
      }
    }
    if (_offset >= _data.length) {
      throw const FormatException('Unterminated bencode dictionary');
    }
    _offset++; // skip 'e'
    return map;
  }

  /// Helper to convert decoded objects containing Uint8List recursively to Dart standard types where appropriate
  static dynamic toNormalTypes(dynamic obj) {
    if (obj is Uint8List) {
      try {
        return utf8.decode(obj);
      } catch (_) {
        return obj; // keep as bytes if not valid utf8
      }
    } else if (obj is List) {
      return obj.map((e) => toNormalTypes(e)).toList();
    } else if (obj is Map) {
      return obj.map((key, value) => MapEntry(key, toNormalTypes(value)));
    }
    return obj;
  }

  /// Parses torrent file bytes and extracts name, size, files, and info hash
  static Map<String, dynamic>? parseTorrentBytes(Uint8List bytes) {
    try {
      final decoder = BencodeDecoder(bytes);
      final decoded = decoder.decode();
      if (decoded is! Map) return null;

      final info = decoded['info'];
      final infoBytes = decoded['info_bytes'];
      if (info is! Map) return null;

      String name = 'unknown_torrent';
      if (info['name'] is Uint8List) {
        name = utf8.decode(info['name']);
      }

      int totalLength = 0;
      final List<Map<String, dynamic>> filesList = [];

      if (info.containsKey('files')) {
        // Multi-file torrent
        final files = info['files'] as List;
        for (final f in files) {
          if (f is Map) {
            final length = f['length'] as int? ?? 0;
            totalLength += length;
            
            final pathSegments = f['path'] as List? ?? [];
            final pathList = pathSegments.map((s) => s is Uint8List ? utf8.decode(s) : s.toString()).toList();
            filesList.add({
              'name': pathList.join('/'),
              'length': length,
            });
          }
        }
      } else {
        // Single file torrent
        totalLength = info['length'] as int? ?? 0;
        filesList.add({
          'name': name,
          'length': totalLength,
        });
      }

      // Compute info hash
      String infoHash = '';
      if (infoBytes is Uint8List) {
        final digest = sha1.convert(infoBytes);
        infoHash = digest.toString().toUpperCase();
      }

      return {
        'name': name,
        'length': totalLength,
        'infoHash': infoHash,
        'files': filesList,
      };
    } catch (_) {
      return null;
    }
  }
}
