import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';

class ChecksumService {
  static final _log = Logger('ChecksumService');

  /// Generic chunked file hasher — used by all specific algorithm methods
  /// to avoid code duplication. Reads the file in 1MB chunks to avoid
  /// high memory usage on large files.
  static Future<String> _hashFile(String path, Hash algorithm) async {
    Digest? digest;
    final innerSink = ChunkedConversionSink<Digest>.withCallback((results) {
      digest = results.single;
    });
    final sink = algorithm.startChunkedConversion(innerSink);
    final file = File(path);
    final raf = await file.open(mode: FileMode.read);
    try {
      const bufferSize = 1024 * 1024; // 1MB buffer for high-throughput hashing
      while (true) {
        final bytes = await raf.read(bufferSize);
        if (bytes.isEmpty) break;
        sink.add(bytes);
      }
    } finally {
      await raf.close();
    }
    sink.close();
    if (digest == null) {
      throw StateError('Failed to compute file hash digest for $path');
    }
    return digest!.toString();
  }

  static Future<String> sha256File(String path) => _hashFile(path, sha256);

  static Future<String> sha1File(String path) => _hashFile(path, sha1);

  static Future<String> md5File(String path) => _hashFile(path, md5);

  static Future<bool> verify(
    String path,
    String expectedHash,
    String algorithm,
  ) async {
    final String actual;
    switch (algorithm.toLowerCase()) {
      case 'sha256':
      case 'sha-256':
        actual = await sha256File(path);
        break;
      case 'sha1':
      case 'sha-1':
        actual = await sha1File(path);
        break;
      case 'md5':
        actual = await md5File(path);
        break;
      default:
        _log.warning('Unknown checksum algorithm: $algorithm');
        return false;
    }
    final match = actual.toLowerCase() == expectedHash.toLowerCase().trim();
    if (!match) {
      _log.warning(
        'Checksum mismatch for $path: '
        'expected=$expectedHash actual=$actual',
      );
    }
    return match;
  }

  static MapEntry<String, String>? parseDigestHeader(String? header) {
    if (header == null || header.trim().isEmpty) return null;

    final parts = header.split(',');
    for (final algo in ['sha-256', 'sha-1', 'md5']) {
      for (final part in parts) {
        final trimmed = part.trim();
        final eqIndex = trimmed.indexOf('=');
        if (eqIndex <= 0) continue;
        final partAlgo = trimmed.substring(0, eqIndex).trim().toLowerCase();
        final partValue = trimmed.substring(eqIndex + 1).trim();
        if (partAlgo == algo || partAlgo == algo.replaceFirst('-', '')) {
          String hexValue = partValue;
          if (!_isHex(partValue)) {
            try {
              final bytes = base64Decode(partValue);
              hexValue =
                  bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
            } catch (e, st) {
              _log.warning('[checksum_service] operation failed', e, st);
            }
          }
          final normalizedAlgo = algo.replaceFirst('-', '');
          return MapEntry(normalizedAlgo, hexValue);
        }
      }
    }
    return null;
  }

  static bool _isHex(String s) {
    if (s.isEmpty) return false;
    return RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);
  }
}
