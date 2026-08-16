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

    test('reconcileActiveTaskIds replaces the active set exactly', () async {
      await BackgroundService.setDownloadActive(true, 'task-a');
      await BackgroundService.setDownloadActive(true, 'task-b');
      expect(BackgroundService.activeDownloadCountForTesting, equals(2));

      // Reconcile down to a single task; stale ids must be dropped.
      await BackgroundService.reconcileActiveTaskIds({'task-b'});
      expect(BackgroundService.activeDownloadCountForTesting, equals(1));
      expect(BackgroundService.activeTaskIdsForTesting, {'task-b'});

      // Reconcile to empty releases everything.
      await BackgroundService.reconcileActiveTaskIds(const {});
      expect(BackgroundService.activeDownloadCountForTesting, equals(0));
      expect(BackgroundService.activeTaskIdsForTesting, isEmpty);
    });

    test('reconcileActiveTaskIds adds new tasks and keeps shared ids',
        () async {
      await BackgroundService.setDownloadActive(true, 'task-a');
      await BackgroundService.reconcileActiveTaskIds({'task-a', 'task-c'});
      expect(BackgroundService.activeDownloadCountForTesting, equals(2));
      expect(
        BackgroundService.activeTaskIdsForTesting,
        containsAll(['task-a', 'task-c']),
      );
    });

    test('taskId is required and tracked independently', () async {
      // Each taskId is tracked independently so a task-tracked false can
      // always decrement the exact task that incremented the count.
      await BackgroundService.setDownloadActive(true, 'task-x');
      await BackgroundService.setDownloadActive(true, 'task-y');
      expect(BackgroundService.activeDownloadCountForTesting, equals(2));

      await BackgroundService.setDownloadActive(false, 'task-x');
      expect(BackgroundService.activeDownloadCountForTesting, equals(1));

      await BackgroundService.setDownloadActive(false, 'task-y');
      expect(BackgroundService.activeDownloadCountForTesting, equals(0));
    });
  });
}