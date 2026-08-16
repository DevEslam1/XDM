import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';

class BencodeDecoder {
  final Uint8List _data;
  int _offset = 0;

  BencodeDecoder(this._data);

  dynamic decode() {
    return _decodeWithDepth(0);
  }

  dynamic _decodeWithDepth(int depth) {
    if (depth > 100) {
      throw const FormatException('Bencode nesting depth exceeded');
    }
    if (_offset >= _data.length) return null;
    final char = String.fromCharCode(_data[_offset]);
    if (char == 'i') {
      return _decodeInt();
    } else if (char == 'l') {
      return _decodeList(depth + 1);
    } else if (char == 'd') {
      return _decodeDict(depth + 1);
    } else if (RegExp(r'[0-9]').hasMatch(char)) {
      return _decodeBytes();
    }
    throw FormatException('Invalid bencode character: $char at $_offset');
  }

  int _decodeInt() {
    _offset++; // skip 'i'
    final start = _offset;
    while (_offset < _data.length && _data[_offset] != 101) {
      // 'e'
      _offset++;
    }
    if (_offset >= _data.length) {
      throw const FormatException('Unterminated bencode integer');
    }
    final numStr = utf8.decode(_data.sublist(start, _offset));
    _offset++; // skip 'e'

    if (numStr.isEmpty) throw const FormatException('Empty bencode integer');
    if (numStr == '-0') {
      throw const FormatException('Negative zero is invalid bencode');
    }
    if (numStr.length > 1 && numStr.startsWith('0')) {
      throw const FormatException('Leading zero in bencode integer');
    }
    if (numStr.length > 1 && numStr.startsWith('-0')) {
      throw const FormatException(
        'Leading zero after minus in bencode integer',
      );
    }

    final big = BigInt.tryParse(numStr);
    if (big == null) throw FormatException('Invalid bencode integer: $numStr');
    final maxSafeInt = kIsWeb
        ? (BigInt.from(1) << 53) - BigInt.one
        : BigInt.from(0x7FFFFFFFFFFFFFFF);
    if (big.abs() > maxSafeInt) {
      throw FormatException('Bencode integer out of safe range: $numStr');
    }
    return big.toInt();
  }

  Uint8List _decodeBytes() {
    final start = _offset;
    while (_offset < _data.length && _data[_offset] != 58) {
      // ':'
      _offset++;
    }
    if (_offset >= _data.length) {
      throw const FormatException('Invalid bencode string length separator');
    }
    final lenStr = utf8.decode(_data.sublist(start, _offset));
    final len = int.tryParse(lenStr);
    if (len == null) {
      throw FormatException('Invalid bencode string length: $lenStr');
    }
    if (len < 0) {
      throw const FormatException('Negative bencode string length');
    }
    if (len > _data.length - _offset - 1) {
      throw const FormatException(
          'Bencode string length exceeds remaining data');
    }
    _offset++; // skip ':'

    if (_offset + len > _data.length) {
      throw const FormatException('Bencode string length exceeds data size');
    }
    final bytes = _data.sublist(_offset, _offset + len);
    _offset += len;
    return bytes;
  }

  List<dynamic> _decodeList(int depth) {
    _offset++; // skip 'l'
    final list = <dynamic>[];
    while (_offset < _data.length && _data[_offset] != 101) {
      // 'e'
      list.add(_decodeWithDepth(depth));
    }
    if (_offset >= _data.length) {
      throw const FormatException('Unterminated bencode list');
    }
    _offset++; // skip 'e'
    return list;
  }

  Map<String, dynamic> _decodeDict(int depth) {
    _offset++; // skip 'd'
    final map = <String, dynamic>{};
    while (_offset < _data.length && _data[_offset] != 101) {
      // 'e'
      final keyBytes = _decodeBytes();
      final key = utf8.decode(keyBytes, allowMalformed: true);

      // If the key is 'info', we want to capture the raw bytes of the info dictionary for info hash computation
      if (key == 'info') {
        final infoStart = _offset;
        final infoVal = _decodeWithDepth(depth);
        final infoEnd = _offset;
        map['info_bytes'] = Uint8List.sublistView(_data, infoStart, infoEnd);
        map['info'] = infoVal;
      } else {
        map[key] = _decodeWithDepth(depth);
      }
    }
    if (_offset >= _data.length) {
      throw const FormatException('Unterminated bencode dictionary');
    }
    _offset++; // skip 'e'
    return map;
  }

  /// Helper to convert decoded objects containing Uint8List recursively to Dart standard types where appropriate.
  /// Pass key context to avoid converting raw binary fields like pieces and peers to UTF-8.
  static dynamic toNormalTypes(dynamic obj, [String? key]) {
    if (obj is Uint8List) {
      final binaryKeys = {'pieces', 'peers', 'nodes', 'ed2k', 'filehash'};
      if (key != null && binaryKeys.contains(key.toLowerCase())) {
        return obj;
      }
      try {
        return utf8.decode(obj);
      } catch (e) {
        LoggingService.logger('BencodeDecoder').info(
          '[BencodeDecoder] utf8 decode skipped, keeping raw bytes: $e',
        );
        return obj; // keep as bytes if not valid utf8
      }
    } else if (obj is List) {
      return obj.map((e) => toNormalTypes(e, null)).toList();
    } else if (obj is Map) {
      return obj.map((k, v) {
        final keyStr = k is Uint8List
            ? utf8.decode(k, allowMalformed: true)
            : k.toString();
        return MapEntry(keyStr, toNormalTypes(v, keyStr));
      });
    }
    return obj;
  }

  /// Helper to recursively traverse BitTorrent v2 (BEP 52) file tree.
  static int _parseFileTree(
    Map tree,
    List<String> currentPath,
    List<Map<String, dynamic>> filesList,
  ) {
    int total = 0;
    for (final entry in tree.entries) {
      final keyStr = entry.key is Uint8List
          ? utf8.decode(entry.key, allowMalformed: true)
          : entry.key.toString();
      final val = entry.value;

      if (keyStr.isEmpty && val is Map) {
        // Leaf file node
        final len = (val['length'] as int?) ?? 0;
        total += len;
        final safeName = currentPath
            .where((seg) =>
                seg.isNotEmpty &&
                seg != '.' &&
                seg != '..' &&
                !seg.contains('/') &&
                !seg.contains('\\') &&
                !seg.contains('\x00') &&
                !seg.startsWith('/') &&
                !seg.startsWith('\\') &&
                !RegExp(r'^[A-Za-z]:').hasMatch(seg))
            .join('/');
        filesList.add({
          'name': safeName.isNotEmpty ? safeName : 'file_$total',
          'length': len,
        });
      } else if (val is Map) {
        // Subtree
        total += _parseFileTree(val, [...currentPath, keyStr], filesList);
      }
    }
    return total;
  }

  /// Parses torrent file bytes and extracts name, size, files, and v1/v2/hybrid info hashes.
  static Map<String, dynamic>? parseTorrentBytes(Uint8List bytes) {
    try {
      final decoder = BencodeDecoder(bytes);
      final decoded = decoder.decode();
      if (decoded is! Map) return null;

      final info = decoded['info'];
      final infoBytes = decoded['info_bytes'];
      if (info is! Map) return null;


      String name = 'unknown_torrent';
      if (info['name.utf-8'] is Uint8List) {
        name = utf8.decode(info['name.utf-8']);
      } else if (info['name'] is Uint8List) {
        name = utf8.decode(info['name']);
      } else if (info['name'] is String) {
        name = info['name'] as String;
      }

      int totalLength = 0;
      final List<Map<String, dynamic>> filesList = [];

      final hasV2FileTree = info.containsKey('file tree') && info['file tree'] is Map;
      final hasV1Pieces = info.containsKey('pieces');
      final hasV1Files = info.containsKey('files');
      final hasV1Length = info.containsKey('length');

      if (hasV2FileTree && (!hasV1Files && !hasV1Length)) {
        // Pure v2 torrent
        totalLength = _parseFileTree(info['file tree'] as Map, [], filesList);
      } else if (info.containsKey('files')) {
        // Multi-file torrent (v1 or hybrid)
        final files = info['files'];
        if (files is List) {
          for (final f in files) {
            if (f is Map) {
              final length = (f['length'] as int?) ?? 0;
              totalLength += length;
              final rawPath = f['path.utf-8'] ?? f['path'];
              final pathSegments = (rawPath is List ? rawPath : <dynamic>[]);
              final pathList = pathSegments
                  .map((s) => s is Uint8List
                      ? utf8.decode(s, allowMalformed: true)
                      : s.toString())
                  .where((seg) =>
                      seg.isNotEmpty &&
                      // Reject traversal segments
                      seg != '.' &&
                      seg != '..' &&
                      // Reject embedded slashes (any direction)
                      !seg.contains('/') &&
                      !seg.contains('\\') &&
                      // Reject null bytes
                      !seg.contains('\x00') &&
                      // Reject absolute Unix paths ('/' or '\' prefix)
                      !seg.startsWith('/') &&
                      !seg.startsWith('\\') &&
                      // Reject Windows drive-letter roots (e.g. 'C:', 'D:')
                      !RegExp(r'^[A-Za-z]:').hasMatch(seg))
                  .toList();
              final safeName = pathList.isNotEmpty
                  ? pathList.join('/')
                  : 'file_$totalLength';
              filesList.add({'name': safeName, 'length': length});
            }
          }
        }
      } else if (info.containsKey('length')) {
        // Single file torrent
        totalLength = info['length'] as int? ?? 0;
        final safeName = name
            .replaceAll('\\', '/')
            .split('/')
            .where((seg) => seg != '.' && seg != '..')
            .join('_');
        filesList.add({
          'name': safeName.isNotEmpty ? safeName : 'file',
          'length': totalLength
        });
      } else if (hasV2FileTree) {
        totalLength = _parseFileTree(info['file tree'] as Map, [], filesList);
      }

      // Compute v1 (SHA-1) and v2 (SHA-256) info hashes
      String? infoHashV1;
      String? infoHashV2;
      String infoHash = '';

      if (infoBytes is Uint8List) {
        final isV2 = (info['meta version'] == 2) || hasV2FileTree;
        final isV1 = hasV1Pieces || hasV1Files || hasV1Length || !isV2;

        if (isV1) {
          infoHashV1 = sha1.convert(infoBytes).toString().toUpperCase();
        }
        if (isV2) {
          infoHashV2 = sha256.convert(infoBytes).toString().toUpperCase();
        }

        infoHash = infoHashV2 ?? infoHashV1 ?? sha1.convert(infoBytes).toString().toUpperCase();
      }

      final isV2Only = infoHashV2 != null && (infoHashV1 == null || !hasV1Pieces);
      final isHybrid = infoHashV1 != null && infoHashV2 != null;

      return {
        'name': name,
        'length': totalLength,
        'infoHash': infoHash,
        'infoHashV1': infoHashV1,
        'infoHashV2': infoHashV2,
        'isV2Only': isV2Only,
        'isHybrid': isHybrid,
        'files': filesList,
      };
    } catch (e) {
      debugPrint('BencodeDecoder.parseTorrentBytes failed: $e');
      return null;
    }
  }
}

