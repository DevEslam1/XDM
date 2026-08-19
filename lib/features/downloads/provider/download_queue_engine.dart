import 'dart:async';
import '../models/download_task.dart';

/// Handles download queue logic, including concurrency and scheduling.
class DownloadQueueEngine {
  int maxConcurrent;

  DownloadQueueEngine({this.maxConcurrent = 3});

  void pumpQueue(
    List<DownloadTask> tasks,
    Future<void> Function(DownloadTask) onStart, {
    Set<String>? excludedTaskIds,
  }) {
    final activeCount =
        tasks.where((t) => t.status == DownloadStatus.downloading).length;
    final availableSlots = maxConcurrent - activeCount;
    if (availableSlots <= 0) return;

    final queued = tasks
        .where((t) =>
            t.status == DownloadStatus.queued &&
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
      unawaited(onStart(task));
    }
  }
}
