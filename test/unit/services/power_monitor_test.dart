import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/power_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PowerMonitor Tests', () {
    test('throttleFactor default returns valid range [0.3, 1.0]', () {
      final factor = PowerMonitor.throttleFactor;
      expect(factor, greaterThanOrEqualTo(0.3));
      expect(factor, lessThanOrEqualTo(1.0));
    });

    test('screenOff respects setScreenOn toggle', () {
      PowerMonitor.setScreenOn(false);
      expect(PowerMonitor.screenOff, isTrue);

      PowerMonitor.setScreenOn(true);
      expect(PowerMonitor.screenOff, isFalse);
    });
  });
}
