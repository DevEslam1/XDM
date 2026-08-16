import 'package:dmx/core/services/frame_watchdog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FrameWatchdog Jank Detection Under Heavy Downloads (P0-8)', () {
    setUp(() {
      FrameWatchdog.onJankDetected = null;
      FrameWatchdog.setDownloadingTasksCount(0);
    });

    tearDown(() {
      FrameWatchdog.onJankDetected = null;
      FrameWatchdog.setDownloadingTasksCount(0);
    });

    test('Normal state detects jank when dropped frame ratio exceeds 5%', () {
      double? reportedJank;
      FrameWatchdog.onJankDetected = (rate) {
        reportedJank = rate;
      };

      // 6 dropped out of 100 = 6% (>5%) -> triggers alert
      FrameWatchdog.simulateWindowForTesting(6, 100, isHeavy: false);
      expect(reportedJank, isNotNull);
      expect(reportedJank, closeTo(0.06, 0.001));

      reportedJank = null;
      // 4 dropped out of 100 = 4% (<=5%) -> does not trigger alert
      FrameWatchdog.simulateWindowForTesting(4, 100, isHeavy: false);
      expect(reportedJank, isNull);
    });

    test(
        'Heavy download state detects jank when dropped frame ratio exceeds 15%',
        () {
      double? reportedJank;
      FrameWatchdog.onJankDetected = (rate) {
        reportedJank = rate;
      };

      FrameWatchdog.setDownloadingTasksCount(3); // >2 tasks = heavy download

      // 10 dropped out of 100 = 10% (<=15% threshold for heavy) -> no alert
      FrameWatchdog.simulateWindowForTesting(10, 100, isHeavy: true);
      expect(reportedJank, isNull);

      // 18 dropped out of 100 = 18% (>15% threshold for heavy) -> alert fires
      FrameWatchdog.simulateWindowForTesting(18, 100, isHeavy: true);
      expect(reportedJank, isNotNull);
      expect(reportedJank, closeTo(0.18, 0.001));
    });
  });
}
