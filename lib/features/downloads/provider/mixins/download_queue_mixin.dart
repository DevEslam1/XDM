import 'package:flutter/foundation.dart';
import '../../models/download_task.dart';
import '../../../../features/settings/provider/settings_provider.dart';

/// Mixin that encapsulates download queue concurrency management — the pump
/// loop, batch‑mode coalescing, and slot calculation.
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

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  bool _queueProcessing = false;
  bool _batchMode = false;
  bool _needsNotify = false;
  bool _needsRePump = false;

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

  // ---------------------------------------------------------------------------
  // Queue pump
  // ---------------------------------------------------------------------------
  void pumpQueue() {
    if (_queueProcessing) {
      _needsRePump = true;
      return;
    }
    _queueProcessing = true;
    _needsRePump = false;
    try {
      final maxSlots = providerSettingsProvider.maxDownloads;
      final queued = providerTasks
          .where((task) =>
              task.status == DownloadStatus.queued &&
              !isTaskWaitingForRetry(task.id))
          .toList();
      var startedThisPass = 0;
      for (final task in queued) {
        final availableSlots = maxSlots - downloadingTasksCount - pendingStartCount - startedThisPass;
        if (availableSlots <= 0) break;
        startTaskFromQueue(task);
        startedThisPass++;
      }
    } catch (e) {
      debugPrint('Queue pump error: $e');
    } finally {
      _queueProcessing = false;
      if (_needsRePump) {
        _needsRePump = false;
        pumpQueue();
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
}
