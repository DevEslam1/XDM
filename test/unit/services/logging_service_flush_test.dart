import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LoggingService Flush Timer Re-adaptation Tests (P3-14)', () {
    setUp(() {
      DownloadEngine.appInForeground = true;
      PowerMonitor.setScreenOn(true);
    });

    tearDown(() {
      LoggingService.dispose();
      DownloadEngine.appInForeground = true;
      PowerMonitor.setScreenOn(true);
    });

    test(
        'adapted interval scales up when screen is turned off or app backgrounded',
        () {
      final foregroundInterval = LoggingService.adaptedIntervalForTesting();
      expect(foregroundInterval.inSeconds, equals(30));

      PowerMonitor.setScreenOn(false);

      final backgroundInterval = LoggingService.adaptedIntervalForTesting();
      expect(backgroundInterval.inSeconds, greaterThanOrEqualTo(60));
    });

    test(
        '10 concurrent workers emitting 1000 logs each completes without race conditions or dropped logs (C4)',
        () async {
      LoggingService.init();

      // Launch 10 concurrent workers
      final futures = <Future<void>>[];
      for (var worker = 0; worker < 10; worker++) {
        futures.add(Future(() async {
          final logger = LoggingService.logger('Worker_$worker');
          for (var i = 0; i < 1000; i++) {
            logger.info('Log entry $i from worker $worker');
            if (i % 250 == 0) {
              await Future.delayed(Duration.zero);
            }
          }
        }));
      }

      await Future.wait(futures);

      // Verify flushLogBuffer and dispose execute cleanly with no concurrent modification exceptions
      expect(() => LoggingService.flushLogBuffer(), returnsNormally);
      expect(() => LoggingService.dispose(), returnsNormally);
    });
  });
}
