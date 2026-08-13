import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/ios_background_service.dart';
import 'package:dmx/core/services/ios_background_capability.dart';
import 'package:dmx/core/services/background_service.dart';
import 'package:dmx/core/services/crash_reporting_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
  });
}
