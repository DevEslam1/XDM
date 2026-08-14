import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/performance_monitor.dart';
import 'package:dmx/core/services/power_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FrameWatchdog / PerformanceMonitor Guard (NEW-03)', () {
    test(
        'PerformanceMonitor.isActive reflects both isListening and screenOn state',
        () {
      PerformanceMonitor.instance.start();
      PowerMonitor.setScreenOn(true);
      expect(PerformanceMonitor.instance.isActive, isTrue);

      PowerMonitor.setScreenOn(false);
      expect(PerformanceMonitor.instance.isActive, isFalse);

      PowerMonitor.setScreenOn(true);
      PerformanceMonitor.instance.stop();
      expect(PerformanceMonitor.instance.isActive, isFalse);
    });
  });
}
