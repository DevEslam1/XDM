import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/ios_background_service.dart';
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
  });

  group('CrashReportingService Enriched API', () {
    test('setContext and addBreadcrumb work without error on default NoOpReporter', () async {
      await CrashReportingService.setContext('task_info', {'id': '123', 'status': 'downloading'});
      await CrashReportingService.addBreadcrumb('Downloading chunk 1', category: 'engine');
      expect(CrashReportingService.reporter, isA<NoOpCrashReporter>());
    });
  });
}
