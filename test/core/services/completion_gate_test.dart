import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dmx/core/services/checksum_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('P0-7: Completion Integrity Gate - Checksum & File Verification', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dmx_completion_gate_test_');
    });

    tearDown(() async {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('ChecksumService verifies matching SHA-256 correctly', () async {
      final file = File(p.join(tempDir.path, 'valid.dat'));
      final content = List<int>.generate(2048, (i) => i % 256);
      await file.writeAsBytes(content);

      final expectedSha = sha256.convert(content).toString();
      final verified = await ChecksumService.verify(file.path, expectedSha, 'sha256');
      expect(verified, isTrue);
    });

    test('ChecksumService fails mismatched SHA-256 correctly', () async {
      final file = File(p.join(tempDir.path, 'tampered.dat'));
      final content = List<int>.generate(2048, (i) => i % 256);
      await file.writeAsBytes(content);

      const wrongSha = '0000000000000000000000000000000000000000000000000000000000000000';
      final verified = await ChecksumService.verify(file.path, wrongSha, 'sha256');
      expect(verified, isFalse);
    });
  });
}
