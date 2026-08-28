import '../models/download_task.dart';
import 'download_orchestrator.dart';

class TaskQueueManager {
  final DownloadOrchestrator _orchestrator;
  final void Function() _pumpQueueCallback;
  final List<DownloadTask> Function() _tasksGetter;

  TaskQueueManager({
    required DownloadOrchestrator orchestrator,
    required void Function() pumpQueueCallback,
    required List<DownloadTask> Function() tasksGetter,
  })  : _orchestrator = orchestrator,
        _pumpQueueCallback = pumpQueueCallback,
        _tasksGetter = tasksGetter;

  int get pendingStartCount => _orchestrator.pendingStartCount;

  bool isTaskPendingStart(String id) => _orchestrator.isTaskPendingStart(id);

  void pumpQueue() {
    _pumpQueueCallback();
  }

  void reorderTasks(int oldIndex, int newIndex) {
    final tasks = _tasksGetter();
    if (oldIndex < 0 ||
        oldIndex >= tasks.length ||
        newIndex < 0 ||
        newIndex >= tasks.length) {
      return;
    }
    if (tasks[oldIndex].status == DownloadStatus.downloading) {
      return;
    }
    final task = tasks.removeAt(oldIndex);
    tasks.insert(newIndex, task);
    for (int i = 0; i < tasks.length; i++) {
      tasks[i] = tasks[i].copyWith(queueOrder: i);
    }
    pumpQueue();
  }

  Future<void> boostPriority(String taskId) async {
    final tasks = _tasksGetter();
    final index = tasks.indexWhere((t) => t.id == taskId);
    if (index > 0) {
      reorderTasks(index, 0);
    }
  }
}
