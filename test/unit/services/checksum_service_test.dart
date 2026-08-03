import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/checksum_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChecksumService Unit Tests', () {
    late File testFile;

    setUp(() {
      final tempDir = Directory.systemTemp.createTempSync('checksum_test_');
      testFile = File('${tempDir.path}/sample.txt');
      testFile.writeAsStringSync('Hello DMX Downloader');
    });

    tearDown(() {
      if (testFile.parent.existsSync()) {
        testFile.parent.deleteSync(recursive: true);
      }
    });

    test('sha256File calculates correct SHA-256 hash', () async {
      final hash = await ChecksumService.sha256File(testFile.path);
      final expected = sha256.convert(testFile.readAsBytesSync()).toString();
      expect(hash, equals(expected));
    });

    test('sha1File calculates correct SHA-1 hash', () async {
      final hash = await ChecksumService.sha1File(testFile.path);
      final expected = sha1.convert(testFile.readAsBytesSync()).toString();
      expect(hash, equals(expected));
    });

    test('md5File calculates correct MD5 hash', () async {
      final hash = await ChecksumService.md5File(testFile.path);
      final expected = md5.convert(testFile.readAsBytesSync()).toString();
      expect(hash, equals(expected));
    });

    test('verify returns true for matching hashes and false for mismatch',
        () async {
      final sha256Val = await ChecksumService.sha256File(testFile.path);
      final ok =
          await ChecksumService.verify(testFile.path, sha256Val, 'sha256');
      expect(ok, isTrue);

      final okMd5 = await ChecksumService.verify(
        testFile.path,
        await ChecksumService.md5File(testFile.path),
        'md5',
      );
      expect(okMd5, isTrue);

      final fail =
          await ChecksumService.verify(testFile.path, 'invalid_hash', 'sha256');
      expect(fail, isFalse);

      final unknownAlgo =
          await ChecksumService.verify(testFile.path, sha256Val, 'crc64');
      expect(unknownAlgo, isFalse);
    });

    test('parseDigestHeader parses hex and base64 digest headers', () {
      final nullRes = ChecksumService.parseDigestHeader(null);
      expect(nullRes, isNull);

      final emptyRes = ChecksumService.parseDigestHeader('   ');
      expect(emptyRes, isNull);

      final sha256Header = ChecksumService.parseDigestHeader(
          'SHA-256=9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08');
      expect(sha256Header, isNotNull);
      expect(sha256Header!.key, equals('sha256'));

      final base64Header = ChecksumService.parseDigestHeader('MD5=4g5g2g==');
      expect(base64Header, isNotNull);
    });
  });
}
