import 'package:dmx/core/services/background_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    BackgroundService.testMode = true;
    BackgroundService.resetActiveDownloadCountForTesting();
    await BackgroundService.resetWakeLockState();
  });

  tearDown(() async {
    BackgroundService.resetActiveDownloadCountForTesting();
    await BackgroundService.resetWakeLockState();
    BackgroundService.testMode = false;
  });

  group('BackgroundService Active Download & Task Tracking (FIX-01)', () {
    test('setDownloadActive is idempotent per taskId', () async {
      expect(BackgroundService.activeDownloadCountForTesting, equals(0));
      expect(BackgroundService.activeTaskIdsForTesting, isEmpty);

      // Add task 1
      await BackgroundService.setDownloadActive(true, 'task-1');
      expect(BackgroundService.activeDownloadCountForTesting, equals(1));
      expect(BackgroundService.activeTaskIdsForTesting, contains('task-1'));

      // Add task 1 again (idempotent)
      await BackgroundService.setDownloadActive(true, 'task-1');
      expect(BackgroundService.activeDownloadCountForTesting, equals(1));
      expect(BackgroundService.activeTaskIdsForTesting.length, equals(1));

      // Add task 2
      await BackgroundService.setDownloadActive(true, 'task-2');
      expect(BackgroundService.activeDownloadCountForTesting, equals(2));
      expect(BackgroundService.activeTaskIdsForTesting, containsAll(['task-1', 'task-2']));

      // Remove task 1
      await BackgroundService.setDownloadActive(false, 'task-1');
      expect(BackgroundService.activeDownloadCountForTesting, equals(1));
      expect(BackgroundService.activeTaskIdsForTesting, contains('task-2'));
      expect(BackgroundService.activeTaskIdsForTesting, isNot(contains('task-1')));

      // Remove task 1 again (idempotent)
      await BackgroundService.setDownloadActive(false, 'task-1');
      expect(BackgroundService.activeDownloadCountForTesting, equals(1));

      // Remove task 2
      await BackgroundService.setDownloadActive(false, 'task-2');
      expect(BackgroundService.activeDownloadCountForTesting, equals(0));
      expect(BackgroundService.activeTaskIdsForTesting, isEmpty);
    });

    test('setDownloadActive without taskId updates count atomically', () async {
      await BackgroundService.setDownloadActive(true);
      await BackgroundService.setDownloadActive(true);
      expect(BackgroundService.activeDownloadCountForTesting, equals(2));

      await BackgroundService.setDownloadActive(false);
      expect(BackgroundService.activeDownloadCountForTesting, equals(1));

      await BackgroundService.setDownloadActive(false);
      expect(BackgroundService.activeDownloadCountForTesting, equals(0));
    });
  });
}
