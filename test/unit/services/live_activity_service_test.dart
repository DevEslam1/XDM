import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmx/core/services/live_activity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.dmx.app/live_activity');
  final List<MethodCall> log = [];

  setUp(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      switch (call.method) {
        case 'isSupported':
          return {'areActivitiesEnabled': true, 'frequentPushBudget': 100};
        default:
          return true;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('LiveActivityService', () {
    test('init detects support structure', () async {
      await LiveActivityService.init();
      // On non-iOS platform in flutter test, LiveActivityService gracefully sets isSupported = false
      expect(LiveActivityService.isSupported, isFalse);
    });

    test('start and update methods execute safely', () async {
      await LiveActivityService.start(
        taskId: 'task-1',
        fileName: 'ubuntu.iso',
      );
      await LiveActivityService.update(
        taskId: 'task-1',
        progress: 0.5,
        speedBytesPerSec: 5000000,
        etaSeconds: 10,
      );
      await LiveActivityService.end(taskId: 'task-1');
      await LiveActivityService.endAll();
    });
  });
}
