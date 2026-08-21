import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import '../../../../core/services/database_service.dart';
import '../../../../core/services/download_engine.dart';
import '../../../../core/services/power_monitor.dart';
import '../../../../features/settings/provider/settings_provider.dart';
import '../../models/download_task.dart';

// ─────────────────────────────────────────────────────────────────────────────
// QUEUE CONCURRENCY FIXES (applied together)
//   QUEUE-FIX-1: Count pendingStartCount against concurrency cap
//   QUEUE-FIX-2: Unified denominator for slot check and thread budget
//   QUEUE-FIX-3: Skip tasks already pending start
//   QUEUE-FIX-4: Block reorder when filters are active
//   QUEUE-FIX-5: Don't count rejected starts against slot budget
//   QUEUE-FIX-6: Defensive override cleanup on exception
//   QUEUE-FIX-7: Preserve maxConcurrentOverride through coalesced re-pump
// ─────────────────────────────────────────────────────────────────────────────

/// Mixin that encapsulates download queue concurrency management — the pump
/// loop, batch‑mode coalescing, slot calculation, and global connection cap.
///
/// Requires the host class to expose:
///  - `List<DownloadTask> get providerTasks`
///  - `SettingsProvider get providerSettingsProvider`
///  - `int get downloadingTasksCount`
///  - `bool startTaskFromQueue(DownloadTask task)` — kicks off a single task
mixin DownloadQueueMixin {
  // ---------------------------------------------------------------------------
  // Abstract contract — must be provided by the host class
  // ---------------------------------------------------------------------------
  List<DownloadTask> get providerTasks;
  SettingsProvider get providerSettingsProvider;
  int get downloadingTasksCount;
  int get pendingStartCount;
  bool startTaskFromQueue(DownloadTask task);
  bool isTaskPendingStart(String taskId);
  bool isTaskWaitingForRetry(String taskId);
  Future<void> pauseTask(String id,
      {PauseReason reason = PauseReason.userRequested});
  Future<void> resumeTask(String id);
  int get queuedTasksCount;
  DatabaseService get providerDatabaseService; // FIX(13)
  set filteredTasksDirty(bool value); // FIX(13)
  void notifyListeners(); // FIX(13)

  void safeNotify() {
    if (DownloadEngine.isInBackground && PowerMonitor.screenOff) return;
    notifyListeners();
  }

  String get statusFilter;
  String get searchQuery;
  Set<String> get categoryFilters;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  bool _queueProcessing = false;
  bool _batchMode = false;
  bool _needsNotify = false;
  bool _needsRePump = false;
  int? _pendingMaxConcurrentOverride;
  final Lock _pumpLock = Lock();
  Timer? _pumpDebounceTimer;

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

  /// Requests a notifyListeners call that will be deferred if batch mode is
  /// active, or dispatched immediately if not.
  void requestNotify(void Function() superNotify) {
    if (_batchMode) {
      _needsNotify = true;
    } else {
      superNotify();
    }
  }

  // ---------------------------------------------------------------------------
  // Bulk state updates (single DB transaction, single notify)
  // ---------------------------------------------------------------------------
  Future<void> updateTasksBulk(
    List<DownloadTask> updates, {
    required DatabaseService providerDatabaseService,
    required bool Function() getFilteredTasksDirty,
    required void Function(bool) setFilteredTasksDirty,
  }) async {
    if (updates.isEmpty) return;
    for (final t in updates) {
      final idx = providerTasks.indexWhere((x) => x.id == t.id);
      if (idx != -1) providerTasks[idx] = t;
    }
    setFilteredTasksDirty(true);
    await providerDatabaseService.saveTasks(updates);
    safeNotify();
  }

  /// Reorders tasks by their new index positions.
  /// The [newIndex] is expected to already be adjusted for the removed item
  /// (i.e. the semantics of `onReorderItem`, which pre-adjusts `newIndex`
  /// for a removal at [oldIndex]). The old `onReorder` API required a manual
  /// `newIndex -= 1` for downward moves; `onReorderItem` does that internally.
  Future<void> reorderTasks(
      List<DownloadTask> visibleTasks, int oldIndex, int newIndex) async {
    // QUEUE-FIX-4: Guard: only allow reordering when the full unfiltered list is visible
    if (statusFilter != 'All' ||
        searchQuery.isNotEmpty ||
        categoryFilters.isNotEmpty) {
      debugPrint('[Queue] Reorder blocked: filters active');
      return;
    }
    // Remove item at oldIndex, insert at newIndex
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
    // 4. Persist asynchronously and notify
    for (final t in updates) {
      final idx = providerTasks.indexWhere((x) => x.id == t.id);
      if (idx != -1) providerTasks[idx] = t;
    }
    filteredTasksDirty = true;
    safeNotify();
    if (updates.isNotEmpty) {
      unawaited(providerDatabaseService.saveTasks(updates));
    }
  }

  // ---------------------------------------------------------------------------
  // Queue pump
  // ---------------------------------------------------------------------------
  static const int _maxConsecutivePumps = 8;
  bool _pumpScheduled = false;

  void pumpQueue({
    bool skipPump = false,
    int? maxConcurrentOverride,
  }) {
    if (skipPump) return;
    if (maxConcurrentOverride != null) {
      _pendingMaxConcurrentOverride = maxConcurrentOverride;
    }

    if (_pumpScheduled) return;
    _pumpScheduled = true;

    _pumpDebounceTimer?.cancel();
    _pumpDebounceTimer = Timer(const Duration(milliseconds: 50), () {
      _pumpScheduled = false;
      _executePumpLocked();
    });
  }

  void _executePumpLocked() {
    unawaited(_pumpLock.synchronized(() {
      if (_queueProcessing) {
        _needsRePump = true;
        return;
      }
      _queueProcessing = true;
      _needsRePump = false;

      try {
        int iteration = 0;
        while (iteration < _maxConsecutivePumps) {
          iteration++;
          _needsRePump = false;
          final effectiveOverride = _pendingMaxConcurrentOverride;
          _pendingMaxConcurrentOverride = null;

          final settings = providerSettingsProvider;
          final activeCount = providerTasks
              .where((t) => t.status == DownloadStatus.downloading)
              .length;

          final effectiveActive = activeCount + pendingStartCount;
          final maxActive = effectiveOverride ?? settings.maxDownloads;

          if (effectiveActive >= maxActive) break;

          final queued = providerTasks
              .where((task) =>
                  task.status == DownloadStatus.queued &&
                  !isTaskWaitingForRetry(task.id))
              .toList();

          if (queued.isEmpty) break;

          queued.sort((a, b) {
            if (a.isAppUpdate != b.isAppUpdate) return b.isAppUpdate ? 1 : -1;
            final prioCmp = b.priority.compareTo(a.priority);
            if (prioCmp != 0) return prioCmp;
            final orderCmp = a.queueOrder.compareTo(b.queueOrder);
            if (orderCmp != 0) return orderCmp;
            return a.createdAt.compareTo(b.createdAt);
          });

          effectiveThreadOverrides.removeWhere(
            (id, _) => !queued.any((t) => t.id == id),
          );

          var startedThisPass = 0;
          for (final task in queued) {
            if (effectiveActive + startedThisPass >= maxActive) break;

            final isRunning = providerTasks.any(
              (t) => t.id == task.id && t.status == DownloadStatus.downloading,
            );
            final hasPendingOverride =
                effectiveThreadOverrides.containsKey(task.id);
            final isPendingStart = isTaskPendingStart(task.id);
            if (isRunning || hasPendingOverride || isPendingStart) continue;

            final totalConcurrent = max(1, effectiveActive + startedThisPass + 1);
            final baseLimit = min(
              settings.maxTotalConnections ~/ totalConcurrent,
              settings.defaultThreadCount,
            );
            final effectiveThreads = max(1, baseLimit);
            final clampedThreads = min(task.threadCount, effectiveThreads);
            effectiveThreadOverrides[task.id] = clampedThreads;

            try {
              final started = startTaskFromQueue(task);
              if (started) {
                startedThisPass++;
              } else {
                effectiveThreadOverrides.remove(task.id);
              }
            } catch (_) {
              effectiveThreadOverrides.remove(task.id);
            }
          }

          if (startedThisPass == 0 && !_needsRePump) {
            break;
          }
        }
      } catch (e) {
        debugPrint('Queue pump error: $e');
      } finally {
        final shouldRePump = _needsRePump;
        final rePumpOverride = _pendingMaxConcurrentOverride;
        _queueProcessing = false;
        _pendingMaxConcurrentOverride = null;
        _needsRePump = false;
        if (shouldRePump) {
          pumpQueue(maxConcurrentOverride: rePumpOverride);
        }
      }
    }));
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
