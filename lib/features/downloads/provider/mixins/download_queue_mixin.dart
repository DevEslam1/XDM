import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../models/download_task.dart';
import '../../../../core/services/database_service.dart';
import '../../../../features/settings/provider/settings_provider.dart';

/// Mixin that encapsulates download queue concurrency management — the pump
/// loop, batch‑mode coalescing, slot calculation, and global connection cap.
///
/// Requires the host class to expose:
///  - `List<DownloadTask> get providerTasks`
///  - `SettingsProvider get providerSettingsProvider`
///  - `int get downloadingTasksCount`
///  - `void startTaskFromQueue(DownloadTask task)` — kicks off a single task
mixin DownloadQueueMixin {
  // ---------------------------------------------------------------------------
  // Abstract contract — must be provided by the host class
  // ---------------------------------------------------------------------------
  List<DownloadTask> get providerTasks;
  SettingsProvider get providerSettingsProvider;
  int get downloadingTasksCount;
  int get pendingStartCount;
  void startTaskFromQueue(DownloadTask task);
  bool isTaskWaitingForRetry(String taskId);
  Future<void> pauseTask(String id);
  Future<void> resumeTask(String id);
  int get queuedTasksCount;
  DatabaseService get providerDatabaseService; // FIX(13)
  set filteredTasksDirty(bool value); // FIX(13)
  void notifyListeners(); // FIX(13)

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  bool _queueProcessing = false;
  bool _batchMode = false;
  bool _needsNotify = false;
  bool _needsRePump = false;

  /// Per-task effective thread count overrides calculated by [pumpQueue] to
  /// enforce the global connection cap. The host class should check this map
  /// in `_startTaskBody` and use the override value instead of the task's
  /// stored `threadCount`.
  final Map<String, int> effectiveThreadOverrides = {};

  // ---------------------------------------------------------------------------
  // Batch mode
  // ---------------------------------------------------------------------------
  /// Begins a batch — all `notifyListeners()` calls are deferred until
  /// [endBatch] is called.
  void startBatch() {
    if (!_batchMode) {
      _needsNotify = false;
    }
    _batchMode = true;
  }

  /// Ends the batch and fires a single notification if any were deferred.
  void endBatch(void Function() superNotify) {
    _batchMode = false;
    if (_needsNotify) {
      _needsNotify = false;
      superNotify();
    }
  }

  /// Returns `true` when batch mode is active and the notification should be
  /// suppressed (the caller should call [markBatchDirty] instead).
  bool get isBatchMode => _batchMode;

  /// Mark that a notification is pending for the current batch.
  void markBatchDirty() {
    _needsNotify = true;
  }

  /// Reorders tasks by their new index positions.
  /// Called from a ReorderableListView's onReorder callback.
  Future<void> reorderTasks(List<DownloadTask> visibleTasks, int oldIndex, int newIndex) async {
    // 1. Adjust newIndex if moving downward (Flutter quirk)
    if (oldIndex < newIndex) newIndex -= 1;
    // 2. Remove item at oldIndex, insert at newIndex
    final list = List<DownloadTask>.from(visibleTasks);
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    // 3. Reassign queueOrder sequentially
    final updates = <DownloadTask>[];
    for (var i = 0; i < list.length; i++) {
      if (list[i].queueOrder != i) {
        updates.add(list[i].copyWith(queueOrder: i));
      }
    }
    // 4. Persist and notify
    for (final t in updates) {
      final idx = providerTasks.indexWhere((x) => x.id == t.id);
      if (idx != -1) providerTasks[idx] = t;
    }
    filteredTasksDirty = true;
    await providerDatabaseService.saveTasks(updates);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Queue pump
  // ---------------------------------------------------------------------------
  void pumpQueue({
    bool skipPump = false,
    int? maxConcurrentOverride,
  }) {
    if (skipPump || _queueProcessing) {
      if (!skipPump) _needsRePump = true;
      return;
    }
    _queueProcessing = true;
    _needsRePump = false;
    try {
      final settings = providerSettingsProvider;
      final activeCount = providerTasks
          .where((t) => t.status == DownloadStatus.downloading)
          .length;

      // Use override when provided (batch playlist), otherwise normal setting.
      final maxActive = maxConcurrentOverride ?? settings.maxDownloads;

      if (activeCount >= maxActive) return;

      final queued = providerTasks
          .where((task) =>
              task.status == DownloadStatus.queued &&
              !isTaskWaitingForRetry(task.id))
          .toList();

      queued.sort((a, b) {
        if (a.isAppUpdate != b.isAppUpdate) return b.isAppUpdate ? 1 : -1;
        final orderCmp = a.queueOrder.compareTo(b.queueOrder);
        if (orderCmp != 0) return orderCmp;
        final prioCmp = b.priority.compareTo(a.priority);
        if (prioCmp != 0) return prioCmp;
        return a.createdAt.compareTo(b.createdAt);
      });

      // Remove overrides for tasks no longer queued
      effectiveThreadOverrides.removeWhere(
        (id, _) => !queued.any((t) => t.id == id),
      );

      var startedThisPass = 0;
      for (final task in queued) {
        if (activeCount + startedThisPass >= maxActive) break;

        // Skip if this task already has a pending override (already being started)
        if (effectiveThreadOverrides.containsKey(task.id)) continue;

        // Enforce global connection cap: distribute connections evenly across
        // all concurrent downloads (including the ones being started this pass).
        final totalConcurrent =
            max(1, activeCount + pendingStartCount + startedThisPass + 1);
        final baseLimit = min(
          settings.maxTotalConnections ~/ totalConcurrent,
          settings.defaultThreadCount,
        );
        final effectiveThreads = max(1, baseLimit);
        final clampedThreads = min(task.threadCount, effectiveThreads);
        effectiveThreadOverrides[task.id] = clampedThreads;

        startTaskFromQueue(task);
        startedThisPass++;
      }
    } catch (e) {
      debugPrint('Queue pump error: $e');
    } finally {
      _queueProcessing = false;
      if (_needsRePump) {
        _needsRePump = false;
        Future.microtask(() => pumpQueue());
      }
    }
  }

  Future<void> mixinPauseAllTasks(void Function() superNotify) async {
    startBatch();
    try {
      final active = providerTasks
          .where(
            (task) =>
                task.status == DownloadStatus.downloading ||
                task.status == DownloadStatus.queued,
          )
          .toList();
      await Future.wait(active.map((task) async {
        try {
          await pauseTask(task.id);
        } catch (e) {
          debugPrint('Error pausing task: $e');
        }
      }));
      pumpQueue();
    } finally {
      endBatch(superNotify);
    }
  }

  Future<void> mixinResumeAllTasks(void Function() superNotify) async {
    startBatch();
    try {
      final resumable = providerTasks
          .where(
            (task) =>
                task.status == DownloadStatus.paused ||
                task.status == DownloadStatus.failed,
          )
          .toList();
      await Future.wait(resumable.map((task) async {
        try {
          await resumeTask(task.id);
        } catch (e) {
          debugPrint('Error resuming task: $e');
        }
      }));
    } finally {
      endBatch(superNotify);
    }
  }

  Future<void> mixinToggleStartStopAll(
    void Function() superNotify,
  ) async {
    final activeCount = downloadingTasksCount + queuedTasksCount;
    if (activeCount > 0) {
      await mixinPauseAllTasks(superNotify);
    } else {
      await mixinResumeAllTasks(superNotify);
    }
  }

  /// Boosts priority of a task (0 -> 1 -> 2) and re-pumps the queue.
  Future<void> boostTaskPriority(
    String taskId,
    Future<void> Function(DownloadTask task) saveTask,
  ) async {
    final index = providerTasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;
    final task = providerTasks[index];
    final newPriority = (task.priority + 1).clamp(0, 2);
    final updated = task.copyWith(priority: newPriority);
    await saveTask(updated);
    pumpQueue();
  }
}
