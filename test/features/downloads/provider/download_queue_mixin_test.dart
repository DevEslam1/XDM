import 'package:dmx/core/services/database_service.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/mixins/download_queue_mixin.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockSettingsProvider extends Mock implements SettingsProvider {}

class _MockDatabaseService extends Mock implements DatabaseService {}

class _FakeDownloadTask extends Fake implements DownloadTask {}

class _QueueHost with DownloadQueueMixin {
  _QueueHost(this.settings, this.db);

  final List<DownloadTask> tasks = [];
  final _MockSettingsProvider settings;
  final _MockDatabaseService db;
  int notifyCount = 0;
  int downloadingCount = 0;
  int pendingStart = 0;
  int queuedCount = 0;
  bool _filteredDirty = false;
  final Set<String> pendingStartIds = {};
  final Set<String> waitingRetryIds = {};
  final List<String> startedIds = [];
  final List<String> pausedIds = [];
  final List<String> resumedIds = [];
  bool startResult = true;
  Object? startError;
  bool Function(DownloadTask)? startPredicate;

  @override
  String statusFilter = 'All';
  @override
  String searchQuery = '';
  @override
  Set<String> categoryFilters = const {};

  @override
  List<DownloadTask> get providerTasks => tasks;

  @override
  SettingsProvider get providerSettingsProvider => settings;

  @override
  int get downloadingTasksCount => downloadingCount;

  @override
  int get pendingStartCount => pendingStart;

  @override
  int get queuedTasksCount => queuedCount;

  @override
  DatabaseService get providerDatabaseService => db;

  @override
  set filteredTasksDirty(bool value) => _filteredDirty = value;

  bool get filteredTasksDirty => _filteredDirty;

  @override
  void notifyListeners() => notifyCount++;

  @override
  bool startTaskFromQueue(DownloadTask task) {
    startedIds.add(task.id);
    if (startPredicate != null) {
      final ok = startPredicate!(task);
      if (ok) _markDownloading(task.id);
      return ok;
    }
    if (startError != null) throw startError!;
    if (startResult) _markDownloading(task.id);
    return startResult;
  }

  void _markDownloading(String id) {
    final i = tasks.indexWhere((t) => t.id == id);
    if (i != -1) {
      tasks[i] = tasks[i].copyWith(status: DownloadStatus.downloading);
    }
  }

  @override
  bool isTaskPendingStart(String taskId) => pendingStartIds.contains(taskId);

  @override
  bool isTaskWaitingForRetry(String taskId) => waitingRetryIds.contains(taskId);

  @override
  Future<void> pauseTask(String id,
      {PauseReason reason = PauseReason.userRequested}) async {
    pausedIds.add(id);
  }

  @override
  Future<void> resumeTask(String id) async {
    resumedIds.add(id);
  }
}

DownloadTask _task(
  String id, {
  DownloadStatus status = DownloadStatus.queued,
  int priority = 0,
  int queueOrder = 0,
  int threadCount = 4,
  bool isAppUpdate = false,
  DateTime? createdAt,
}) {
  final now = createdAt ?? DateTime(2026, 1, 1);
  return DownloadTask(
    id: id,
    fileName: '$id.zip',
    url: 'https://example.com/$id.zip',
    fileSize: 100,
    downloadedBytes: 0,
    category: 'Other',
    status: status,
    savePath: '/d',
    localFilePath: '/d/$id.zip',
    tempFilePath: '/d/$id.dmxpart',
    threadCount: threadCount,
    chunks: const [0.0],
    createdAt: now,
    updatedAt: now,
    priority: priority,
    queueOrder: queueOrder,
    isAppUpdate: isAppUpdate,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockSettingsProvider settings;
  late _MockDatabaseService db;
  late _QueueHost host;

  setUpAll(() {
    registerFallbackValue(_FakeDownloadTask());
    registerFallbackValue(<DownloadTask>[]);
  });

  setUp(() {
    settings = _MockSettingsProvider();
    db = _MockDatabaseService();
    when(() => settings.maxDownloads).thenReturn(3);
    when(() => settings.maxTotalConnections).thenReturn(16);
    when(() => settings.defaultThreadCount).thenReturn(8);
    when(() => db.saveTasks(any())).thenAnswer((_) async {});
    when(() => db.saveTask(any())).thenAnswer((_) async {});
    host = _QueueHost(settings, db);
  });

  group('batch mode', () {
    test('startBatch defers notifications and endBatch flushes once', () {
      var superNotify = 0;
      host.startBatch();
      expect(host.isBatchMode, isTrue);
      host.requestNotify(() => superNotify++);
      host.markBatchDirty();
      expect(superNotify, 0);
      host.endBatch(() => superNotify++);
      expect(superNotify, 1);
      expect(host.isBatchMode, isFalse);
    });

    test('requestNotify fires immediately outside batch', () {
      var superNotify = 0;
      host.requestNotify(() => superNotify++);
      expect(superNotify, 1);
    });
  });

  group('updateTasksBulk', () {
    test('empty list is a no-op', () async {
      await host.updateTasksBulk(
        [],
        providerDatabaseService: db,
        getFilteredTasksDirty: () => false,
        setFilteredTasksDirty: (_) {},
      );
      verifyNever(() => db.saveTasks(any()));
    });

    test('updates in-memory tasks, persists and notifies', () async {
      host.tasks.add(_task('a'));
      final updated = host.tasks.first.copyWith(downloadedBytes: 50);
      await host.updateTasksBulk(
        [updated],
        providerDatabaseService: db,
        getFilteredTasksDirty: () => false,
        setFilteredTasksDirty: (v) => host.filteredTasksDirty = v,
      );
      expect(host.tasks.first.downloadedBytes, 50);
      verify(() => db.saveTasks([updated])).called(1);
      expect(host.notifyCount, 1);
    });
  });

  group('reorderTasks', () {
    test('blocked when a filter is active', () async {
      host.statusFilter = 'Downloading';
      final tasks = [_task('a'), _task('b')];
      await host.reorderTasks(tasks, 0, 1);
      expect(host.filteredTasksDirty, isFalse);
      verifyNever(() => db.saveTasks(any()));
    });

    test('reassigns queueOrder and persists changes', () async {
      final a = _task('a', queueOrder: 0);
      final b = _task('b', queueOrder: 1);
      host.tasks.addAll([a, b]);
      await host.reorderTasks([a, b], 0, 1);
      final byId = {for (final t in host.tasks) t.id: t};
      expect(byId['b']!.queueOrder, 0);
      expect(byId['a']!.queueOrder, 1);
      verify(() => db.saveTasks(any())).called(1);
    });
  });

  group('pumpQueue', () {
    test('skipPump does nothing', () {
      host.tasks.add(_task('a'));
      host.pumpQueue(skipPump: true);
      expect(host.startedIds, isEmpty);
    });

    test('starts queued tasks up to the concurrency cap', () async {
      host.tasks.add(_task('a'));
      host.tasks.add(_task('b'));
      host.pumpQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.startedIds, ['a', 'b']);
    });

    test('respects maxDownloads cap', () async {
      when(() => settings.maxDownloads).thenReturn(1);
      host.tasks.add(_task('a'));
      host.tasks.add(_task('b'));
      host.pumpQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.startedIds, ['a']);
    });

    test('maxConcurrentOverride raises the cap for the first pass', () async {
      when(() => settings.maxDownloads).thenReturn(1);
      host.tasks.add(_task('a'));
      host.tasks.add(_task('b'));
      host.pumpQueue(maxConcurrentOverride: 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.startedIds, ['a', 'b']);
    });

    test('priority and app updates are ordered first', () async {
      host.tasks.add(_task('low', priority: 0));
      host.tasks.add(_task('high', priority: 2));
      host.tasks.add(_task('update', isAppUpdate: true));
      host.pumpQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.startedIds.first, 'update');
      expect(host.startedIds[1], 'high');
    });

    test('skips tasks waiting for retry', () async {
      host.tasks.add(_task('a'));
      host.waitingRetryIds.add('a');
      host.pumpQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.startedIds, isEmpty);
    });

    test('skips tasks already pending start', () async {
      host.tasks.add(_task('a'));
      host.pendingStartIds.add('a');
      host.pumpQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.startedIds, isEmpty);
    });

    test('removes override when start is rejected', () async {
      host.startResult = false;
      host.tasks.add(_task('a'));
      host.pumpQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.effectiveThreadOverrides.containsKey('a'), isFalse);
    });

    test('removes override when start throws', () async {
      host.startError = StateError('boom');
      host.tasks.add(_task('a'));
      host.pumpQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.effectiveThreadOverrides.containsKey('a'), isFalse);
    });

    test('coalesces rapid pump requests', () async {
      host.tasks.add(_task('a'));
      host.pumpQueue();
      host.pumpQueue();
      host.pumpQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.startedIds, ['a']);
    });
  });

  group('bulk pause/resume', () {
    test('mixinPauseAllTasks pauses active tasks and pumps', () async {
      host.tasks.add(_task('d', status: DownloadStatus.downloading));
      host.tasks.add(_task('q', status: DownloadStatus.queued));
      host.tasks.add(_task('c', status: DownloadStatus.completed));
      var superNotify = 0;
      await host.mixinPauseAllTasks(() => superNotify++);
      expect(host.pausedIds, containsAll(['d', 'q']));
      expect(host.pausedIds, isNot(contains('c')));
      expect(superNotify, 0);
    });

    test('mixinResumeAllTasks resumes paused and failed tasks', () async {
      host.tasks.add(_task('p', status: DownloadStatus.paused));
      host.tasks.add(_task('f', status: DownloadStatus.failed));
      host.tasks.add(_task('c', status: DownloadStatus.completed));
      var superNotify = 0;
      await host.mixinResumeAllTasks(() => superNotify++);
      expect(host.resumedIds, containsAll(['p', 'f']));
      expect(host.resumedIds, isNot(contains('c')));
      expect(superNotify, 0);
    });

    test('mixinToggleStartStopAll pauses when active', () async {
      host.downloadingCount = 1;
      host.tasks.add(_task('d', status: DownloadStatus.downloading));
      await host.mixinToggleStartStopAll(() {});
      expect(host.pausedIds, contains('d'));
    });

    test('mixinToggleStartStopAll resumes when idle', () async {
      host.tasks.add(_task('p', status: DownloadStatus.paused));
      await host.mixinToggleStartStopAll(() {});
      expect(host.resumedIds, contains('p'));
    });
  });

  group('boostTaskPriority', () {
    test('increments priority and pumps', () async {
      host.tasks.add(_task('a', priority: 0));
      DownloadTask? saved;
      await host.boostTaskPriority('a', (t) async {
        saved = t;
      });
      expect(saved, isNotNull);
      expect(saved!.priority, 1);
    });

    test('clamps priority at max', () async {
      host.tasks.add(_task('a', priority: 2));
      DownloadTask? saved;
      await host.boostTaskPriority('a', (t) async {
        saved = t;
      });
      expect(saved!.priority, 2);
    });

    test('missing task is a no-op', () async {
      var called = false;
      await host.boostTaskPriority('missing', (t) async {
        called = true;
      });
      expect(called, isFalse);
    });
  });

  group('safeNotify', () {
    test('notifies in the foreground', () {
      host.safeNotify();
      expect(host.notifyCount, 1);
    });
  });
}
