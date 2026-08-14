import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/download_task.dart';

/// Contract for executing downloads when the queue permits.
abstract class DownloadQueueHost {
  List<DownloadTask> get tasks;
  int get maxConcurrentDownloads;
  int get downloadingTasksCount;
  bool isTaskStarting(String taskId);
  Future<void> executeTask(String taskId);
  Future<void> updateTaskOrder(List<DownloadTask> orderedTasks);
}

/// Service managing download queue ordering, priority adjustment,
/// and concurrency slot allocation.
class DownloadQueueService {
  final DownloadQueueHost _host;
  final Set<String> _pendingStarts = {};

  DownloadQueueService({required DownloadQueueHost host}) : _host = host;

  int get pendingStartCount => _pendingStarts.length;

  bool isTaskPendingStart(String id) => _pendingStarts.contains(id);

  void markPendingStart(String id) => _pendingStarts.add(id);

  void clearPendingStart(String id) => _pendingStarts.remove(id);

  void clearAllPendingStarts() => _pendingStarts.clear();

  /// Pumps the download queue, starting next queued tasks up to [maxConcurrentDownloads].
  Future<void> pumpQueue() async {
    final activeCount = _host.downloadingTasksCount + _pendingStarts.length;
    final availableSlots = _host.maxConcurrentDownloads - activeCount;

    if (availableSlots <= 0) return;

    final queued = _host.tasks
        .where((t) =>
            t.status == DownloadStatus.queued &&
            !_pendingStarts.contains(t.id) &&
            !_host.isTaskStarting(t.id))
        .toList()
      ..sort((a, b) => a.queueOrder.compareTo(b.queueOrder));

    final toStart = queued.take(availableSlots).toList();
    for (final task in toStart) {
      _pendingStarts.add(task.id);
      try {
        unawaited(_host.executeTask(task.id).whenComplete(() {
          _pendingStarts.remove(task.id);
        }));
      } catch (e) {
        _pendingStarts.remove(task.id);
        debugPrint('[DownloadQueueService] Failed to start task ${task.id}: $e');
      }
    }
  }

  /// Reorders tasks in the queue and updates `queueOrder`.
  Future<void> reorderTasks(int oldIndex, int newIndex) async {
    final taskList = List<DownloadTask>.from(_host.tasks);
    if (oldIndex < 0 ||
        oldIndex >= taskList.length ||
        newIndex < 0 ||
        newIndex >= taskList.length) {
      return;
    }

    final task = taskList.removeAt(oldIndex);
    taskList.insert(newIndex, task);

    for (int i = 0; i < taskList.length; i++) {
      taskList[i] = taskList[i].copyWith(queueOrder: i);
    }

    await _host.updateTaskOrder(taskList);
    await pumpQueue();
  }

  /// Moves a task to the front of the queue (priority boost).
  Future<void> boostPriority(String taskId) async {
    final taskList = _host.tasks;
    final index = taskList.indexWhere((t) => t.id == taskId);
    if (index > 0) {
      await reorderTasks(index, 0);
    }
  }
}
