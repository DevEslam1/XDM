import 'dart:io';

import 'package:dmx/core/services/ios_background_capability.dart';
import 'package:dmx/core/services/ios_background_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 7 — Platform Fixes & Configuration Tests', () {
    test('Android: AndroidManifest.xml contains BootReceiver & dataSync FGS', () {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(manifestFile.existsSync(), isTrue);

      final content = manifestFile.readAsStringSync();
      expect(content.contains('android.permission.RECEIVE_BOOT_COMPLETED'), isTrue);
      expect(content.contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'), isTrue);
      expect(content.contains('android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'), isTrue);
      expect(content.contains('.BootReceiver'), isTrue);
      expect(content.contains('android.intent.action.BOOT_COMPLETED'), isTrue);
    });

    test('Android: build.gradle.kts sets compileSdk to 36', () {
      final gradleFile = File('android/app/build.gradle.kts');
      expect(gradleFile.existsSync(), isTrue);

      final content = gradleFile.readAsStringSync();
      expect(content.contains('compileSdk = 36'), isTrue);
    });

    test('iOS: Info.plist ATS contains accurate justification without pinned TLS claim', () {
      final infoPlist = File('ios/Runner/Info.plist');
      expect(infoPlist.existsSync(), isTrue);

      final content = infoPlist.readAsStringSync();
      expect(content.contains('strictly pinned'), isFalse);
      expect(content.contains('NSAllowsArbitraryLoads'), isTrue);
      expect(content.contains('NSExceptionDomains'), isTrue);
      expect(content.contains('BGTaskSchedulerPermittedIdentifiers'), isTrue);
    });

    test('iOS: IosBackgroundTransferEvent parses correctly from Map', () {
      final event = IosBackgroundTransferEvent.fromMap({
        'event': 'progress',
        'taskId': 'test-task-1',
        'downloadedBytes': 1024,
        'totalBytes': 4096,
        'path': '/tmp/file.part',
      });

      expect(event.event, equals('progress'));
      expect(event.taskId, equals('test-task-1'));
      expect(event.downloadedBytes, equals(1024));
      expect(event.totalBytes, equals(4096));
      expect(event.path, equals('/tmp/file.part'));
    });

    test('iOS: IosBackgroundCapability singleton is initialized', () {
      final capability = IosBackgroundCapability.instance;
      expect(capability, isNotNull);
    });
  });
}
