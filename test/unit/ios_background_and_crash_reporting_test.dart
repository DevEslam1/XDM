import 'dart:io';

import 'package:dmx/core/services/background_service.dart';
import 'package:dmx/core/services/crash_reporting_service.dart';
import 'package:dmx/core/services/ios_background_capability.dart';
import 'package:dmx/core/services/ios_background_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('IosBackgroundService', () {
    test('scheduleBackgroundDownload returns false when not on iOS', () async {
      final result = await IosBackgroundService.scheduleBackgroundDownload();
      expect(result, isFalse);
    });

    test('cancelBackgroundDownload returns false when not on iOS', () async {
      final result = await IosBackgroundService.cancelBackgroundDownload();
      expect(result, isFalse);
    });

    test('startNativeDownload returns false when not on iOS', () async {
      final result = await IosBackgroundService.startNativeDownload(
        taskId: 't1',
        url: 'https://example.com/f.mp4',
        destinationPath: '/path/f.mp4',
      );
      expect(result, isFalse);
    });

    test(
        'pauseNativeDownload and cancelNativeDownload return false when not on iOS',
        () async {
      expect(await IosBackgroundService.pauseNativeDownload('t1'), isFalse);
      expect(await IosBackgroundService.cancelNativeDownload('t1'), isFalse);
    });
  });

  group('IosBackgroundCapability & BackgroundService Integration', () {
    test('IosBackgroundCapability isSupported returns false on non-iOS',
        () async {
      final supported = await IosBackgroundCapability.instance.isSupported();
      expect(supported, isFalse);
    });

    test('BackgroundService start and stop run safely', () async {
      await BackgroundService.start();
      await BackgroundService.stop();
      expect(
        BackgroundService.isSupported,
        !kIsWeb && (Platform.isAndroid || Platform.isIOS),
      );
    });

    test(
        'onIosBackground returns false when channel call fails or returns false',
        () async {
      const channel = MethodChannel('com.dmx.app/background_download');

      // 1. When channel returns false
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
        return false;
      });
      final resFalse = await BackgroundService.onIosBackgroundForTesting(
        _DummyServiceInstance(),
      );
      expect(resFalse, isFalse);

      // 2. When channel throws error
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
        throw PlatformException(code: 'ERROR', message: 'Failed');
      });
      final resError = await BackgroundService.onIosBackgroundForTesting(
        _DummyServiceInstance(),
      );
      expect(resError, isFalse);

      // 3. When channel returns true
      BackgroundService.resetIosCooldownForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
        return true;
      });
      final resTrue = await BackgroundService.onIosBackgroundForTesting(
        _DummyServiceInstance(),
      );
      expect(resTrue, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('lastScheduleAttemptAt'), isNotNull);
      expect(prefs.getInt('lastScheduleAttemptAt'), isPositive);
    });
  });

  group('CrashReportingService Enriched API', () {
    test(
        'setContext and addBreadcrumb work without error on default NoOpReporter',
        () async {
      await CrashReportingService.setContext(
          'task_info', {'id': '123', 'status': 'downloading'});
      await CrashReportingService.addBreadcrumb('Downloading chunk 1',
          category: 'engine');
      expect(CrashReportingService.reporter, isA<NoOpCrashReporter>());
    });

    test('reporter getter returns the same cached no-op instance', () {
      final first = CrashReportingService.reporter;
      final second = CrashReportingService.reporter;
      expect(identical(first, second), isTrue);
      expect(first, isA<NoOpCrashReporter>());
    });

    test('redactSensitive redacts api_key, access_token, password, and Bearer',
        () {
      expect(
        CrashReportingService.redactSensitive(
            'https://example.com/api?api_key=secret123&user=john'),
        equals('https://example.com/api?api_key=***&user=john'),
      );
      expect(
        CrashReportingService.redactSensitive(
            'https://example.com/download?access_token=token456&file=movie.mp4'),
        equals('https://example.com/download?access_token=***&file=movie.mp4'),
      );
      expect(
        CrashReportingService.redactSensitive(
            'https://example.com/login?password=myPassword99&user=admin'),
        equals('https://example.com/login?password=***&user=admin'),
      );
      expect(
        CrashReportingService.redactSensitive(
            'Authorization: Bearer mySecretJwtToken12345'),
        equals('Authorization: Bearer ***'),
      );
    });
  });
}

class _DummyServiceInstance extends Fake implements ServiceInstance {}
