import '../models/download_task.dart';

/// Pure queue scheduling logic for ordering and queueing DownloadTasks.
class TaskQueue {
  /// Returns only tasks that are queued for download.
  List<DownloadTask> getQueuedTasks(List<DownloadTask> tasks) {
    return tasks.where((t) => t.status == DownloadStatus.queued).toList();
  }

  /// Reorders tasks in the list, updating queue order.
  List<DownloadTask> reorder(
    List<DownloadTask> tasks,
    int oldIndex,
    int newIndex,
  ) {
    if (oldIndex < 0 || oldIndex >= tasks.length) return tasks;
    var targetIndex = newIndex;
    if (targetIndex > oldIndex) targetIndex -= 1;
    targetIndex = targetIndex.clamp(0, tasks.length - 1);

    final list = List<DownloadTask>.from(tasks);
    final moved = list.removeAt(oldIndex);
    list.insert(targetIndex, moved);
    return list;
  }
}
