import 'package:dmx/features/downloads/data/task_repository.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/downloads/provider/download_filter_provider.dart';
import 'package:dmx/features/downloads/provider/download_list_provider.dart';
import 'package:dmx/features/downloads/provider/mixins/download_filter_mixin.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestFilterHost with DownloadFilterMixin {
  final List<DownloadTask> _tasks;
  _TestFilterHost(this._tasks);

  @override
  List<DownloadTask> get providerTasks => _tasks;

  @override
  DownloadTask? findTaskById(String id) {
    final idx = _tasks.indexWhere((t) => t.id == id);
    return idx != -1 ? _tasks[idx] : null;
  }

  @override
  void notifyListeners() {}
}

class _FakeTaskRepo implements TaskRepository {
  final List<DownloadTask> tasks = [];
  @override
  Future<List<DownloadTask>> getAll() async => tasks;
  @override
  Future<DownloadTask?> getById(String id) async {
    final idx = tasks.indexWhere((t) => t.id == id);
    return idx != -1 ? tasks[idx] : null;
  }

  @override
  Future<void> save(DownloadTask task) async {
    final idx = tasks.indexWhere((t) => t.id == task.id);
    if (idx != -1) {
      tasks[idx] = task;
    } else {
      tasks.add(task);
    }
  }

  @override
  Future<void> saveAll(List<DownloadTask> newTasks) async {
    for (final task in newTasks) {
      await save(task);
    }
  }

  @override
  Future<void> delete(String id) async => tasks.removeWhere((t) => t.id == id);
  @override
  Future<void> deleteAll(List<String> ids) async =>
      tasks.removeWhere((t) => ids.contains(t.id));
  @override
  Stream<DownloadTask> watchTask(String id) => const Stream.empty();
}

DownloadTask _buildTask(String id, {int queueOrder = 0, String name = ''}) {
  final now = DateTime.now();
  return DownloadTask(
    id: id,
    url: 'https://example.com/$id',
    fileName: name.isNotEmpty ? name : 'file-$id.bin',
    fileSize: 1000,
    downloadedBytes: 0,
    category: 'Other',
    status: DownloadStatus.queued,
    savePath: '',
    localFilePath: '',
    tempFilePath: '',
    threadCount: 1,
    chunks: const [0.0],
    createdAt: now,
    updatedAt: now,
    queueOrder: queueOrder,
  );
}

void main() {
  group('Download Filter & Cache Tests', () {
    test('DownloadFilterMixin invalidates cache when a task is deleted', () {
      final tasks = [_buildTask('1'), _buildTask('2'), _buildTask('3')];
      final host = _TestFilterHost(tasks);

      // Populate cache
      expect(host.filteredTasks.length, 3);

      // Delete task 2 directly from list without dirtying cache manually
      tasks.removeAt(1);

      // filteredTasks should detect the missing cached task and re-filter cleanly
      final result = host.filteredTasks;
      expect(result.length, 2);
      expect(result.map((t) => t.id).toSet(), {'1', '3'});
    });

    test('DownloadFilterProvider SortMode.manual sorts by queueOrder', () {
      final repo = _FakeTaskRepo();
      final listProvider = DownloadListProvider(repo);
      final filterProvider = DownloadFilterProvider(listProvider);

      final t1 = _buildTask('1', queueOrder: 2);
      final t2 = _buildTask('2', queueOrder: 0);
      final t3 = _buildTask('3', queueOrder: 1);

      listProvider.setTasks([t1, t2, t3]);
      filterProvider.setSort(SortMode.manual, ascending: true);

      final sorted = filterProvider.filteredTasks;
      expect(sorted.map((t) => t.id).toList(), ['2', '3', '1']);
    });

    test('DownloadListProvider setTasks disposes removed notifiers', () {
      final repo = _FakeTaskRepo();
      final listProvider = DownloadListProvider(repo);

      final t1 = _buildTask('1');
      final t2 = _buildTask('2');
      listProvider.setTasks([t1, t2]);

      final notif1 = listProvider.progressRatioFor('1');
      final notif2 = listProvider.progressRatioFor('2');
      expect(notif1.value, 0.0);
      expect(notif2.value, 0.0);

      // Update task list to remove task 1
      listProvider.setTasks([t2]);

      // Notifier for task 1 should be disposed and removed
      expect(listProvider.findTask('1'), isNull);
      expect(listProvider.findTask('2')?.id, '2');
    });
  });
}
