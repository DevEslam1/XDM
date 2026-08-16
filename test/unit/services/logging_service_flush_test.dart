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
  });
}
