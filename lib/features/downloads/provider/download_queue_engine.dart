import 'dart:async';
import '../models/download_task.dart';

/// Single canonical queue engine handling admission, concurrency, ordering, and priority.
class DownloadQueueEngine {
  int maxConcurrent;

  DownloadQueueEngine({this.maxConcurrent = 3});

  /// Tracks tasks currently being started (not yet reflected in status).
  final Set<String> _inflightStarts = {};

  /// Current number of tasks in-flight during start.
  int get pendingStartCount => _inflightStarts.length;

  /// Checks if a task is currently in-flight during start.
  bool isTaskPendingStart(String taskId) => _inflightStarts.contains(taskId);

  /// Returns tasks that are currently waiting in the queued state.
  List<DownloadTask> getQueuedTasks(List<DownloadTask> tasks) {
    return tasks.where((t) => t.status == DownloadStatus.queued).toList();
  }

  /// Reorders tasks in the list, returning the modified list with updated [queueOrder].
  List<DownloadTask> reorder(
    List<DownloadTask> tasks,
    int oldIndex,
    int newIndex,
  ) {
    if (oldIndex < 0 || oldIndex >= tasks.length) return tasks;
    final list = List<DownloadTask>.from(tasks);
    final moved = list.removeAt(oldIndex);
    var targetIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
    targetIndex = targetIndex.clamp(0, list.length);
    list.insert(targetIndex, moved);
    for (var i = 0; i < list.length; i++) {
      list[i] = list[i].copyWith(queueOrder: i);
    }
    return list;
  }

  /// Boosts the priority of a task to the head of the queue.
  List<DownloadTask> boostPriority(List<DownloadTask> tasks, String taskId) {
    final index = tasks.indexWhere((t) => t.id == taskId);
    if (index > 0) {
      return reorder(tasks, index, 0);
    }
    return tasks;
  }

  /// Marks a task as no longer in-flight (called after onStart completes or fails).
  void markStartComplete(String taskId) {
    _inflightStarts.remove(taskId);
  }

  /// Evaluates queued tasks against active slots and invokes [onStart] for admitted tasks.
  void pumpQueue(
    List<DownloadTask> tasks,
    Future<void> Function(DownloadTask) onStart, {
    Set<String>? excludedTaskIds,
  }) {
    final activeCount =
        tasks.where((t) => t.status == DownloadStatus.downloading).length;
    final availableSlots =
        maxConcurrent - (activeCount + _inflightStarts.length);
    if (availableSlots <= 0) return;

    final queued = tasks
        .where((t) =>
            t.status == DownloadStatus.queued &&
            !_inflightStarts.contains(t.id) &&
            !(excludedTaskIds?.contains(t.id) ?? false))
        .toList()
      ..sort((a, b) {
        if (a.isAppUpdate != b.isAppUpdate) return b.isAppUpdate ? 1 : -1;
        final prioCmp = b.priority.compareTo(a.priority);
        if (prioCmp != 0) return prioCmp;
        final orderCmp = a.queueOrder.compareTo(b.queueOrder);
        if (orderCmp != 0) return orderCmp;
        return a.createdAt.compareTo(b.createdAt);
      });

    final toStart = queued.take(availableSlots);
    for (final task in toStart) {
      _inflightStarts.add(task.id);
      unawaited(
          onStart(task).whenComplete(() => _inflightStarts.remove(task.id)));
    }
  }
}
