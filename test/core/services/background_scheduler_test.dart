import 'package:dmx/core/services/background_scheduler.dart';
import 'package:dmx/core/services/download_engine.dart';
import 'package:dmx/core/services/power_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final scheduler = BackgroundScheduler.instance;

  setUp(() {
    DownloadEngine.markForeground();
    DownloadEngine.setActiveDownloadsCount(0);
    PowerMonitor.setScreenOn(true);
    scheduler.dispose();
  });

  tearDown(() {
    scheduler.dispose();
    DownloadEngine.markForeground();
    DownloadEngine.setActiveDownloadsCount(0);
    PowerMonitor.setScreenOn(true);
  });

  group('BackgroundScheduler', () {
    test('register and unregister track task count and active flag', () {
      expect(scheduler.taskCount, 0);
      expect(scheduler.isActive, isFalse);

      scheduler.registerTask(
        'a',
        const Duration(seconds: 1),
        () {},
        backgroundInterval: const Duration(seconds: 5),
      );
      expect(scheduler.taskCount, 1);
      expect(scheduler.isActive, isTrue);

      scheduler.registerTask('b', const Duration(seconds: 1), () {});
      expect(scheduler.taskCount, 2);

      scheduler.unregisterTask('a');
      expect(scheduler.taskCount, 1);
      scheduler.unregisterTask('b');
      expect(scheduler.taskCount, 0);
      expect(scheduler.isActive, isFalse);
    });

    test('master timer runs registered task callbacks', () async {
      var calls = 0;
      scheduler.registerTask(
        'tick',
        const Duration(milliseconds: 1),
        () => calls++,
      );

      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(calls, greaterThanOrEqualTo(1));
    });

    test('task callback exceptions are swallowed', () async {
      scheduler.registerTask(
        'boom',
        const Duration(milliseconds: 1),
        () => throw StateError('boom'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(scheduler.taskCount, 1);
    });

    test('stopTimer cancels the master timer without clearing tasks', () {
      scheduler.registerTask('s', const Duration(seconds: 1), () {});
      scheduler.stopTimer();
      expect(scheduler.isActive, isFalse);
      expect(scheduler.taskCount, 1);
    });

    test('registering in background still fires the first tick', () async {
      PowerMonitor.setScreenOn(false);
      var calls = 0;
      scheduler.registerTask(
        'bg',
        const Duration(milliseconds: 1),
        () => calls++,
        backgroundInterval: const Duration(milliseconds: 2),
      );
      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(calls, greaterThanOrEqualTo(1));
    });

    test('scheduleBackgroundSync marks the engine background after delay',
        () async {
      DownloadEngine.markForeground();
      scheduler.scheduleBackgroundSync(
        delay: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(DownloadEngine.isInBackground, isTrue);
    });
  });
}
