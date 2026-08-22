import 'dart:ffi';
import 'package:flutter_test/flutter_test.dart';
import 'package:libtorrent_flutter/src/ffi_bindings.dart';

void main() {
  group('FFI Struct Contract Tests', () {
    test('LtTorrentStatus ABI contract size verification', () {
      final actualSize = sizeOf<LtTorrentStatus>();
      expect(actualSize, equals(1880),
          reason: 'LtTorrentStatus size must be exactly 1880 bytes matching C++ bridge (actual: $actualSize)');
      expect(
        () => verifyStatusStructContract(),
        returnsNormally,
      );
    });
  });
}
