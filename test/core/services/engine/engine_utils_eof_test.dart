import 'package:dio/dio.dart';
import 'package:dmx/core/services/engine/engine_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Headers h(Map<String, List<String>> m) => Headers.fromMap(m);

  group('unknownLengthEofIsTrustworthy (M-3)', () {
    test('a zero-byte result is never a completed file, whatever the framing',
        () {
      expect(
          unknownLengthEofIsTrustworthy(
              h({
                'transfer-encoding': ['chunked']
              }),
              0),
          isFalse);
      expect(unknownLengthEofIsTrustworthy(h({}), 0), isFalse);
    });

    test('chunked framing is a trustworthy terminator', () {
      expect(
          unknownLengthEofIsTrustworthy(
              h({
                'transfer-encoding': ['chunked']
              }),
              1024),
          isTrue);
      // dio lowercases header names, but assert case-insensitivity explicitly.
      expect(
          unknownLengthEofIsTrustworthy(
              h({
                'Transfer-Encoding': ['Chunked']
              }),
              1024),
          isTrue);
    });

    test('an explicit Connection: close is a trustworthy graceful close', () {
      expect(
          unknownLengthEofIsTrustworthy(
              h({
                'connection': ['close']
              }),
              1024),
          isTrue);
    });

    test('a present Content-Length header is a trustworthy delimiter', () {
      expect(
          unknownLengthEofIsTrustworthy(
              h({
                'content-length': ['1024']
              }),
              1024),
          isTrue);
    });

    test('keep-alive with no length and no chunked cannot be trusted', () {
      expect(unknownLengthEofIsTrustworthy(h({}), 1024), isFalse);
      expect(
          unknownLengthEofIsTrustworthy(
              h({
                'connection': ['keep-alive']
              }),
              1024),
          isFalse,
          reason: 'no completion signal → possible truncation → reject');
    });
  });
}
