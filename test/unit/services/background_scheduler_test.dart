import 'package:dmx/core/services/background_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundScheduler', () {
    final scheduler = BackgroundScheduler.instance;

    setUp(() {
      scheduler.dispose();
    });

    tearDown(() {
      scheduler.dispose();
    });

    test('registers and unregisters tasks correctly', () {
      expect(scheduler.isActive, isFalse);
      expect(scheduler.taskCount, 0);

      scheduler.registerTask(
        'test_task_1',
        const Duration(seconds: 1),
        () {},
      );

      expect(scheduler.isActive, isTrue);
      expect(scheduler.taskCount, 1);

      scheduler.unregisterTask('test_task_1');
      expect(scheduler.taskCount, 0);
      expect(scheduler.isActive, isFalse);
    });

    test('stopTimer cancels active master timer', () {
      scheduler.registerTask(
        'test_task_2',
        const Duration(seconds: 1),
        () {},
      );
      expect(scheduler.isActive, isTrue);

      scheduler.stopTimer();
      expect(scheduler.isActive, isFalse);
    });

    test('dispose clears all tasks and stops timer', () {
      scheduler.registerTask(
        'test_task_3',
        const Duration(seconds: 1),
        () {},
      );
      scheduler.registerTask(
        'test_task_4',
        const Duration(seconds: 2),
        () {},
      );
      expect(scheduler.taskCount, 2);

      scheduler.dispose();
      expect(scheduler.taskCount, 0);
      expect(scheduler.isActive, isFalse);
    });
  });
}
