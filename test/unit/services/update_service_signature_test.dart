import 'dart:io';

import 'package:dmx/core/services/update_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpdateService APK Signature Verification (SEC-06)', () {
    late Directory tempDir;
    late File apkFile;
    const dummyFingerprint =
        'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('apk_sig_test_');
      apkFile = File('${tempDir.path}/update.apk');
      await apkFile.writeAsBytes([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]);

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

    test('matching certificate fingerprint passes verification', () async {
      final result = await UpdateService().verifyApkSignature(
        apkFile,
        expectedFingerprint: dummyFingerprint,
      );

      expect(result.isValid, isTrue);
      expect(result.certificateFingerprint, equals(dummyFingerprint));
      expect(await apkFile.exists(), isTrue);
    });

    test('mismatched certificate fingerprint fails and deletes the APK file',
        () async {
      final result = await UpdateService().verifyApkSignature(
        apkFile,
        expectedFingerprint:
            '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff',
      );

      expect(result.isValid, isFalse);
      expect(
          result.failureReason, contains('Certificate fingerprint mismatch'));
      expect(await apkFile.exists(), isFalse);
    });
  });
}
