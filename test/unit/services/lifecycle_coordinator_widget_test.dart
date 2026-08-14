import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/app_lifecycle_coordinator.dart';
import 'package:dmx/core/services/widget_data_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppLifecycleCoordinator Widget Updates Pause/Resume (NEW-02)', () {
    setUp(() {
      AppLifecycleCoordinator.init();
    });

    tearDown(() {
      AppLifecycleCoordinator.dispose();
      WidgetDataBridge.instance.resumeWidgetUpdates();
    });

    test('pauses widget updates on background and resumes on foreground', () {
      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(WidgetDataBridge.instance.isPaused, isTrue);

      AppLifecycleCoordinator.instance
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(WidgetDataBridge.instance.isPaused, isFalse);
    });
  });
}
