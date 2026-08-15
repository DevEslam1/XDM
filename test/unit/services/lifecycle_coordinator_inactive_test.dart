import 'package:dmx/core/services/app_lifecycle_coordinator.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppLifecycleCoordinator Inactive Delay (NEW-04)', () {
    setUp(() {
      AppLifecycleCoordinator.init();
    });

    tearDown(() {
      AppLifecycleCoordinator.dispose();
    });

    test('inactive state sets 500ms delay timer before ambient suspension', () {
      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(AppLifecycleCoordinator.inactiveTimerForTesting, isNotNull);

      // Resuming before timer expires cancels it
      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(AppLifecycleCoordinator.inactiveTimerForTesting, isNull);
    });
  });
}
