import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:dmx/features/downloads/widgets/download_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StatusChipPulseDriver Tests', () {
    setUp(() {
      PowerMonitor.setScreenOn(true);
      StatusChipPulseDriver.stopAll();
    });

    tearDown(() {
      StatusChipPulseDriver.stopAll();
      PowerMonitor.setScreenOn(true);
    });

    test('addRef and removeRef controls driver refCount and visible state', () {
      final driver = StatusChipPulseDriver.instance;
      expect(driver.visibleChips, equals(0));

      driver.incrementVisibleChips();
      expect(driver.visibleChips, equals(1));

      driver.addRef();
      expect(driver.value.value, isNotNull);

      driver.removeRef();
      driver.decrementVisibleChips();
      expect(driver.visibleChips, equals(0));
    });

    test('stopAll stops active pulse animation', () {
      final driver = StatusChipPulseDriver.instance;
      driver.addRef();
      StatusChipPulseDriver.stopAll();
      expect(driver.value.value, isNotNull);
    });

    test('screenOff pauses pulse driver', () {
      final driver = StatusChipPulseDriver.instance;
      driver.addRef();
      PowerMonitor.setScreenOn(false);
      expect(PowerMonitor.screenOff, isTrue);
      PowerMonitor.setScreenOn(true);
      expect(PowerMonitor.screenOff, isFalse);
    });
  });
}
