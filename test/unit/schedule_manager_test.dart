import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/schedule_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal fake [DatabaseService] that records save calls.
class _FakeDatabaseService extends DatabaseService {
  _FakeDatabaseService() : super.forSubclass();
  final List<DownloadTask> savedTasks = [];

  @override
  Future<void> saveTask(DownloadTask task) async {
    savedTasks.add(task);
  }
}

/// [DatabaseService] whose saves always fail, to exercise the SCHED-FIX-6
/// revert path in [ScheduleManager.checkScheduledDownloads].
class _FailingDatabaseService extends DatabaseService {
  _FailingDatabaseService() : super.forSubclass();

  @override
  Future<void> saveTask(DownloadTask task) async {
    throw Exception('simulated DB write failure');
  }
}

/// [DatabaseService] that only fails saves for the given task ids, to exercise
/// the SCHED-FIX-6 partial-failure path (some promotions persist, some don't).
class _SelectiveFailDatabaseService extends DatabaseService {
  _SelectiveFailDatabaseService(this._failTaskIds) : super.forSubclass();
  final Set<String> _failTaskIds;
  final List<DownloadTask> savedTasks = [];

  @override
  Future<void> saveTask(DownloadTask task) async {
    if (_failTaskIds.contains(task.id)) {
      throw Exception('simulated DB write failure for ${task.id}');
    }
    savedTasks.add(task);
  }
}

/// Helper to build a minimal [DownloadTask].
DownloadTask _task(
  String id,
  DownloadStatus status, {
  bool pausedByUser = false,
  DateTime? scheduledAt,
}) {
  final now = DateTime(2026, 7, 31);
  return DownloadTask(
    id: id,
    fileName: '$id.zip',
    url: 'https://example.com/$id.zip',
    fileSize: 100,
    downloadedBytes: 0,
    category: 'Other',
    status: status,
    savePath: '',
    localFilePath: '',
    tempFilePath: '',
    threadCount: 1,
    chunks: const [0.0],
    createdAt: now,
    updatedAt: now,
    pausedByUser: pausedByUser,
    scheduledAt: scheduledAt,
  );
}

void main() {
  group('ScheduleManager', () {
    late List<DownloadTask> tasks;
    late _FakeDatabaseService db;
    late bool disposed;
    late int downloadingCount;
    late int torrentUploadLimitCalls;
    late int notifyCalls;
    late int pumpQueueCalls;
    late ScheduleManager manager;

    setUp(() {
      tasks = [];
      db = _FakeDatabaseService();
      disposed = false;
      downloadingCount = 0;
      torrentUploadLimitCalls = 0;
      notifyCalls = 0;
      pumpQueueCalls = 0;

      manager = ScheduleManager(
        tasks: () => tasks,
        databaseService: db,
        isDisposed: () => disposed,
        downloadingTasksCount: () => downloadingCount,
        updateTorrentUploadLimit: () => torrentUploadLimitCalls++,
        notifyListeners: () => notifyCalls++,
        pumpQueue: () => pumpQueueCalls++,
      );
      manager.markReady();
    });

    tearDown(() {
      manager.dispose();
    });

    group('checkScheduledDownloads', () {
      test('promotes past-due scheduled task to queued', () async {
        final pastTime = DateTime.now().toUtc().subtract(
              const Duration(minutes: 5),
            );
        tasks.add(_task('s1', DownloadStatus.paused, scheduledAt: pastTime));

        await manager.checkScheduledDownloads();

        expect(tasks.first.status, DownloadStatus.queued);
        expect(tasks.first.scheduledAt, isNull);
        expect(db.savedTasks, hasLength(1));
        expect(pumpQueueCalls, 1);
        expect(notifyCalls, 1);
        expect(torrentUploadLimitCalls, 1);
      });

      test('does not promote future-scheduled task', () async {
        final futureTime = DateTime.now().toUtc().add(const Duration(hours: 1));
        tasks.add(_task('s2', DownloadStatus.paused, scheduledAt: futureTime));

        await manager.checkScheduledDownloads();

        expect(tasks.first.status, DownloadStatus.paused);
        expect(tasks.first.scheduledAt, futureTime);
        expect(db.savedTasks, isEmpty);
        expect(pumpQueueCalls, 0);
      });

      test('does not promote user-paused scheduled task', () async {
        final pastTime = DateTime.now().toUtc().subtract(
              const Duration(minutes: 5),
            );
        tasks.add(
          _task(
            's3',
            DownloadStatus.paused,
            pausedByUser: true,
            scheduledAt: pastTime,
          ),
        );

        await manager.checkScheduledDownloads();

        expect(tasks.first.status, DownloadStatus.paused);
        expect(db.savedTasks, isEmpty);
        expect(pumpQueueCalls, 0);
      });

      test('does not promote non-paused task', () async {
        final pastTime = DateTime.now().toUtc().subtract(
              const Duration(minutes: 5),
            );
        tasks.add(_task('s4', DownloadStatus.queued, scheduledAt: pastTime));

        await manager.checkScheduledDownloads();

        // Task should remain unchanged.
        expect(tasks.first.status, DownloadStatus.queued);
        expect(db.savedTasks, isEmpty);
        expect(pumpQueueCalls, 0);
      });

      test('promotes multiple past-due tasks concurrently', () async {
        final past1 = DateTime.now().toUtc().subtract(
              const Duration(minutes: 10),
            );
        final past2 = DateTime.now().toUtc().subtract(
              const Duration(minutes: 5),
            );
        tasks.add(_task('s5', DownloadStatus.paused, scheduledAt: past1));
        tasks.add(_task('s6', DownloadStatus.paused, scheduledAt: past2));

        await manager.checkScheduledDownloads();

        expect(tasks[0].status, DownloadStatus.queued);
        expect(tasks[1].status, DownloadStatus.queued);
        expect(db.savedTasks, hasLength(2));
        expect(pumpQueueCalls, 1);
      });

      test(
        'uses UTC comparison so timezone changes do not affect timing',
        () async {
          // Schedule 1 minute in the past UTC.
          final pastUtc = DateTime.now().toUtc().subtract(
                const Duration(minutes: 1),
              );
          tasks.add(_task('s7', DownloadStatus.paused, scheduledAt: pastUtc));

          await manager.checkScheduledDownloads();

          expect(tasks.first.status, DownloadStatus.queued);
        },
      );

      test('does nothing when no tasks exist', () async {
        await manager.checkScheduledDownloads();

        expect(pumpQueueCalls, 0);
        expect(notifyCalls, 0);
        expect(db.savedTasks, isEmpty);
      });

      test('clears error and scheduledAt on promoted task', () async {
        final pastTime = DateTime.now().toUtc().subtract(
              const Duration(minutes: 5),
            );
        final task = _task(
          's8',
          DownloadStatus.paused,
          scheduledAt: pastTime,
        ).copyWith(errorMessage: 'Some old error');
        tasks.add(task);

        await manager.checkScheduledDownloads();

        expect(tasks.first.status, DownloadStatus.queued);
        expect(tasks.first.errorMessage, isNull);
        expect(tasks.first.scheduledAt, isNull);
        expect(tasks.first.wasScheduledAt, pastTime); // SCHED-FIX-1
      });

      test('SCHED-FIX-7: skips promotion until markReady is called', () async {
        final unreadyManager = ScheduleManager(
          tasks: () => tasks,
          databaseService: db,
          isDisposed: () => disposed,
          downloadingTasksCount: () => downloadingCount,
          updateTorrentUploadLimit: () => torrentUploadLimitCalls++,
          notifyListeners: () => notifyCalls++,
          pumpQueue: () => pumpQueueCalls++,
        );
        final pastTime =
            DateTime.now().toUtc().subtract(const Duration(minutes: 5));
        tasks.add(_task('s9', DownloadStatus.paused, scheduledAt: pastTime));

        await unreadyManager.checkScheduledDownloads();
        expect(tasks.first.status,
            DownloadStatus.paused); // Not promoted because unready

        unreadyManager.markReady();
        await unreadyManager.checkScheduledDownloads();
        expect(
            tasks.first.status, DownloadStatus.queued); // Promoted after ready
        unreadyManager.dispose();
      });

      test('SCHED-FIX-4: bails out early if disposed during loop', () async {
        final pastTime =
            DateTime.now().toUtc().subtract(const Duration(minutes: 5));
        tasks.add(_task('s10', DownloadStatus.paused, scheduledAt: pastTime));
        disposed = true;

        await manager.checkScheduledDownloads();
        expect(tasks.first.status, DownloadStatus.paused);
      });

      test(
          'SCHED-FIX-6: reverts in-memory state AND notifies listeners when '
          'persisting the promotion fails', () async {
        final failingDb = _FailingDatabaseService();
        final failingManager = ScheduleManager(
          tasks: () => tasks,
          databaseService: failingDb,
          isDisposed: () => disposed,
          downloadingTasksCount: () => downloadingCount,
          updateTorrentUploadLimit: () => torrentUploadLimitCalls++,
          notifyListeners: () => notifyCalls++,
          pumpQueue: () => pumpQueueCalls++,
        );
        failingManager.markReady();

        final pastTime = DateTime.now().toUtc().subtract(
              const Duration(minutes: 5),
            );
        final task = _task(
          's11',
          DownloadStatus.paused,
          scheduledAt: pastTime,
        );
        tasks.add(task);

        await failingManager.checkScheduledDownloads();

        // Reverted: back to paused with the original schedule restored.
        expect(tasks.first.status, DownloadStatus.paused);
        expect(tasks.first.scheduledAt, pastTime);
        expect(tasks.first.wasScheduledAt, isNull);
        // BUG 3: listeners must be notified so the UI reflects the revert.
        expect(notifyCalls, greaterThanOrEqualTo(1));
        // No inconsistent queue pump.
        expect(pumpQueueCalls, 0);
        failingManager.dispose();
      });

      test(
          'SCHED-FIX-6: partial save failure only reverts the failed task, '
          'keeping successfully persisted promotions queued', () async {
        final selectiveDb =
            _SelectiveFailDatabaseService({'s11'}); // only 's11' fails
        final selectiveManager = ScheduleManager(
          tasks: () => tasks,
          databaseService: selectiveDb,
          isDisposed: () => disposed,
          downloadingTasksCount: () => downloadingCount,
          updateTorrentUploadLimit: () => torrentUploadLimitCalls++,
          notifyListeners: () => notifyCalls++,
          pumpQueue: () => pumpQueueCalls++,
        );
        selectiveManager.markReady();

        final pastTime = DateTime.now().toUtc().subtract(
              const Duration(minutes: 5),
            );
        tasks.add(_task('s12', DownloadStatus.paused, scheduledAt: pastTime));
        tasks.add(_task('s11', DownloadStatus.paused, scheduledAt: pastTime));
        tasks.add(_task('s13', DownloadStatus.paused, scheduledAt: pastTime));

        await selectiveManager.checkScheduledDownloads();

        // Only the task whose save failed is reverted to paused + scheduled.
        expect(tasks[0].status, DownloadStatus.queued); // s12: save succeeded
        expect(
          tasks[1].status,
          DownloadStatus.paused,
        ); // s11: save failed -> reverted
        expect(tasks[1].scheduledAt, pastTime);
        expect(tasks[1].wasScheduledAt, isNull);
        expect(tasks[2].status, DownloadStatus.queued); // s13: save succeeded
        // The successful saves were persisted.
        expect(selectiveDb.savedTasks.map((t) => t.id),
            containsAll(['s12', 's13']));
        // Listeners told about the partial revert.
        expect(notifyCalls, greaterThanOrEqualTo(1));
        selectiveManager.dispose();
      });
    });

    group('dispose', () {
      test('cancels the scheduling timer', () {
        manager.start();
        manager.dispose();
        // After dispose, the timer should be cancelled.
        // This is a smoke test — no exception means success.
      });
    });
  });
}
