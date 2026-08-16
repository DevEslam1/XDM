import 'package:dmx/core/services/background_timer_manager.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundTimerManager Debounce & Flapping Guard (P0-9)', () {
    test('State changes are debounced by 500ms and flapping count is tracked',
        () async {
      final manager = BackgroundTimerManager.instance;

      int callCount = 0;
      manager.register(
        id: 'test-timer',
        baseInterval: const Duration(seconds: 5),
        callback: () => callCount++,
      );

      // Trigger 6 rapid throttleFactor updates
      for (var i = 0; i < 6; i++) {
        PowerMonitor.throttleFactorNotifier.value = 0.5 + (i * 0.05);
      }

      // Assert debounce timer is active and history records rapid state changes
      expect(manager.debounceTimerForTesting, isNotNull);
      expect(manager.debounceTimerForTesting!.isActive, isTrue);
      expect(manager.stateChangeHistoryCount, greaterThanOrEqualTo(5));

      // Wait for debounce timer (500ms) to fire
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(manager.debounceTimerForTesting?.isActive ?? false, isFalse);

      manager.cancel('test-timer');
      expect(callCount, equals(0));
    });
  });
}
