import 'package:dmx/core/services/live_activity_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LiveActivityService on non-iOS', () {
    test('all methods are safe no-ops', () async {
      await LiveActivityService.start(taskId: 'x', fileName: 'y');
      await LiveActivityService.update(
        taskId: 'x',
        progress: 0.5,
        speedBytesPerSec: 1000,
        etaSeconds: 5,
      );
      await LiveActivityService.end(taskId: 'x');
      await LiveActivityService.endAll();
    });
  });
}
