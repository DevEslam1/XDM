import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dmx/core/services/update_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpdateService streamed APK verification (H22)', () {
    late Directory tempDir;
    late UpdateService service;
    const dummyFingerprint =
        'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('apk_stream_test_');
      service = UpdateService();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.dmx.app/security'),
        (methodCall) async {
          if (methodCall.method == 'verifyApkSignature') {
            return dummyFingerprint;
          }
          return null;
        },
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<File> writeApk(List<int> bytes, {String name = 'update.apk'}) async {
      final file = File('${tempDir.path}/$name');
      await file.writeAsBytes(bytes);
      return file;
    }

    test('header check streams and accepts a valid zip/APK header', () async {
      final apk = await writeApk([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]);
      final result = await service.verifyApkSignature(
        apk,
        expectedFingerprint: dummyFingerprint,
      );
      expect(result.isValid, isTrue);
    });

    test('header check rejects a non-zip file', () async {
      final apk = await writeApk([0x00, 0x01, 0x02, 0x03, 0x04]);
      final result = await service.verifyApkSignature(
        apk,
        expectedFingerprint: dummyFingerprint,
      );
      expect(result.isValid, isFalse);
      expect(result.failureReason, contains('Invalid zip/APK'));
      // Invalid file is not deleted by the header path.
      expect(await apk.exists(), isTrue);
    });

    test('verifyApkIntegrity matches expected size and streaming SHA-256',
        () async {
      final payload = List<int>.generate(64 * 1024, (i) => i % 251);
      final apk = await writeApk(payload, name: 'integrity.apk');
      final digest = sha256.convert(payload).toString();

      final ok = await service.verifyApkIntegrity(
        apk,
        expectedSize: payload.length,
        expectedSha256: digest,
      );
      expect(ok, isTrue);
    });

    test('verifyApkIntegrity fails on size mismatch', () async {
      final apk = await writeApk([0x50, 0x4B, 0x03, 0x04]);
      final ok = await service.verifyApkIntegrity(
        apk,
        expectedSize: 999999,
      );
      expect(ok, isFalse);
    });

    test('verifyApkIntegrity fails on SHA-256 mismatch', () async {
      final apk = await writeApk(
          List<int>.generate(1024, (i) => i % 251),
          name: 'hash.apk');
      final ok = await service.verifyApkIntegrity(
        apk,
        expectedSize: 1024,
        expectedSha256: '0' * 64,
      );
      expect(ok, isFalse);
    });

    test('verifyApkIntegrity returns false for a missing file', () async {
      final missing = File('${tempDir.path}/does-not-exist.apk');
      expect(await service.verifyApkIntegrity(missing, expectedSize: 1), isFalse);
    });

    test('large APK hash is verified without whole-file read', () async {
      // ~5 MB of deterministic data; verifies the streaming path handles
      // multi-chunk reads (chunk sizes are 64KB on most platforms).
      final payload =
          List<int>.generate(5 * 1024 * 1024, (i) => i % 251);
      final apk = await writeApk(payload, name: 'large.apk');
      final digest = sha256.convert(payload).toString();

      final ok = await service.verifyApkIntegrity(
        apk,
        expectedSize: payload.length,
        expectedSha256: digest,
      );
      expect(ok, isTrue);
    });

    test('mismatched fingerprint deletes the APK', () async {
      final apk = await writeApk([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]);
      final result = await service.verifyApkSignature(
        apk,
        expectedFingerprint:
            '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff',
      );
      expect(result.isValid, isFalse);
      expect(result.failureReason, contains('Certificate fingerprint mismatch'));
      expect(await apk.exists(), isFalse);
    });
  });
}
