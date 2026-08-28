import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HTTP Engine Malformed & Fuzz Tests', () {
    test('Content-Length parser handles fuzzed & malformed strings safely', () {
      int? parseContentLength(String? header) {
        if (header == null) return null;
        final trimmed = header.trim();
        if (trimmed.isEmpty) return null;
        try {
          final val = int.tryParse(trimmed);
          if (val == null || val < 0) return null;
          return val;
        } catch (_) {
          return null;
        }
      }

      // Fuzz / edge cases
      expect(parseContentLength(''), isNull);
      expect(parseContentLength('   '), isNull);
      expect(parseContentLength('-1'), isNull);
      expect(parseContentLength('-999999'), isNull);
      expect(parseContentLength('invalid'), isNull);
      expect(parseContentLength('1234abc'), isNull);
      expect(parseContentLength('12.34'), isNull);
      expect(parseContentLength('NaN'), isNull);
      expect(parseContentLength('Infinity'), isNull);
      expect(parseContentLength('9999999999999999999999999999999999999999'),
          isNull);
      expect(parseContentLength('1048576'), equals(1048576));
      expect(parseContentLength(' 2048 '), equals(2048));
    });

    test(
        'Range header parser validates start/end byte boundaries against fuzzed inputs',
        () {
      bool isValidByteRange(int start, int? end, int totalSize) {
        if (start < 0 || totalSize < 0) return false;
        if (start >= totalSize) return false;
        if (end != null) {
          if (end < start || end >= totalSize) return false;
        }
        return true;
      }

      expect(isValidByteRange(0, 99, 100), isTrue);
      expect(isValidByteRange(0, null, 100), isTrue);
      expect(isValidByteRange(-1, 50, 100), isFalse);
      expect(isValidByteRange(100, 150, 100), isFalse);
      expect(isValidByteRange(50, 40, 100), isFalse);
      expect(isValidByteRange(0, 100, 100), isFalse); // end is 0-indexed
      expect(isValidByteRange(0, 50, -1), isFalse);
    });

    test(
        'ETag validator ignores weak validators and sanitized malformed quotes',
        () {
      String? sanitizeETag(String? raw) {
        if (raw == null) return null;
        var trimmed = raw.trim();
        if (trimmed.startsWith('W/')) {
          trimmed = trimmed.substring(2).trim();
        }
        if (trimmed.startsWith('"') &&
            trimmed.endsWith('"') &&
            trimmed.length >= 2) {
          trimmed = trimmed.substring(1, trimmed.length - 1);
        }
        return trimmed.isEmpty ? null : trimmed;
      }

      expect(sanitizeETag(null), isNull);
      expect(sanitizeETag(''), isNull);
      expect(sanitizeETag('""'), isNull);
      expect(sanitizeETag('W/""'), isNull);
      expect(sanitizeETag('"abcd1234"'), equals('abcd1234'));
      expect(sanitizeETag('W/"abcd1234"'), equals('abcd1234'));
      expect(sanitizeETag('  "token"  '), equals('token'));
    });
  });
}
