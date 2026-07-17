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
  void startTaskFromQueue(DownloadTask task);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  bool _queueProcessing = false;
  bool _batchMode = false;
  bool _needsNotify = false;

  // ---------------------------------------------------------------------------
  // Batch mode
  // ---------------------------------------------------------------------------
  /// Begins a batch — all `notifyListeners()` calls are deferred until
  /// [endBatch] is called.
  void startBatch() {
    _batchMode = true;
    _needsNotify = false;
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
    if (_queueProcessing) return;
    _queueProcessing = true;
    try {
      final availableSlots =
          providerSettingsProvider.maxDownloads - downloadingTasksCount;
      if (availableSlots <= 0) return;

      final queued = providerTasks
          .where((task) => task.status == DownloadStatus.queued)
          .take(availableSlots)
          .toList();
      for (final task in queued) {
        startTaskFromQueue(task);
      }
    } finally {
      _queueProcessing = false;
    }
  }
}
