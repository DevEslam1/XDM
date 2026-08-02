import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/frame_watchdog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FrameWatchdog Unit Tests', () {
    test('FrameWatchdog start and stop execute safely', () {
      expect(() => FrameWatchdog.start(), returnsNormally);
      expect(() => FrameWatchdog.start(), returnsNormally); // Idempotent start
      expect(() => FrameWatchdog.stop(), returnsNormally);
      expect(() => FrameWatchdog.stop(), returnsNormally); // Idempotent stop
    });
  });
}
