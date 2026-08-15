import 'dart:io';

import 'package:dmx/core/services/update_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File mockApkFile;
  const dummyFingerprint =
      'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('update_test_');
    mockApkFile = File('${tempDir.path}/test_app.apk');
    // Valid ZIP header PK\x03\x04 + dummy content
    await mockApkFile.writeAsBytes([0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 4, 5]);

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

  group('UpdateService APK Verification', () {
    test('Valid APK file passes header and signature check', () async {
      final service = UpdateService();
      final result = await service.verifyApkSignature(mockApkFile);

      expect(result.isValid, isTrue);
      expect(result.certificateFingerprint, isNotNull);
    });

    test('Non-zip invalid file fails verification', () async {
      final badFile = File('${tempDir.path}/corrupt.apk');
      await badFile.writeAsBytes([0x00, 0x00, 0x00, 0x00]);

      final service = UpdateService();
      final result = await service.verifyApkSignature(badFile);

      expect(result.isValid, isFalse);
      expect(result.failureReason, contains('Invalid zip'));
    });

    test('Certificate fingerprint mismatch is detected', () async {
      final service = UpdateService();
      final result = await service.verifyApkSignature(
        mockApkFile,
        expectedFingerprint: 'invalid_fingerprint_hash_123',
      );

      expect(result.isValid, isFalse);
      expect(result.failureReason, contains('fingerprint mismatch'));
    });

    test('Matching certificate fingerprint passes verification', () async {
      final service = UpdateService();
      final result = await service.verifyApkSignature(
        mockApkFile,
        expectedFingerprint: dummyFingerprint,
      );

      expect(result.isValid, isTrue);
      expect(result.certificateFingerprint, equals(dummyFingerprint));
    });

    test('Developer mode bypass allows verification override', () async {
      final service = UpdateService();
      final result = await service.verifyApkSignature(
        mockApkFile,
        expectedFingerprint: 'mismatched_hash',
        developerMode: true,
      );

      expect(result.isValid, isTrue);
      expect(result.isDeveloperOverride, isTrue);
    });
  });
}
