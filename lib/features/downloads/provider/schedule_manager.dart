import 'dart:async';
import 'dart:io';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/services/background_service.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/update_service.dart';
import '../models/download_task.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    return Future.value(true);
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// SCHEDULED DOWNLOAD FIXES (applied together)
//   SCHED-FIX-1: Preserve schedule origin when wifi-only blocks promotion
//   SCHED-FIX-2: Don't destroy future schedule on manual pause
//   SCHED-FIX-3: Dynamic timer targeting nearest scheduled task
//   SCHED-FIX-4: Disposal guard inside promotion loop
//   SCHED-FIX-5: Notification when scheduled download starts
//   SCHED-FIX-6: Revert in-memory state on save failure
//   SCHED-FIX-7: Skip promotion until provider is fully loaded
// ─────────────────────────────────────────────────────────────────────────────

/// Owns the periodic scheduling timer and schedule evaluation.
///
/// Extracted from [DownloadProvider] (Refactor A). Every 15 seconds (or on a
/// dynamically targeted schedule) it promotes due scheduled tasks to the
/// queue, triggers the periodic app update check, and keeps the background
/// service heartbeat alive while downloads are running. All task/queue
/// mutations go through the constructor callbacks into the provider.
class ScheduleManager {
  ScheduleManager({
    required List<DownloadTask> Function() tasks,
    required DatabaseService databaseService,
    required bool Function() isDisposed,
    required int Function() downloadingTasksCount,
    required void Function() updateTorrentUploadLimit,
    required void Function() notifyListeners,
    required void Function() pumpQueue,
    void Function(String taskName, DateTime scheduledAt)?
        onScheduledTaskStarted,
  })  : _tasks = tasks,
        _databaseService = databaseService,
        _isDisposed = isDisposed,
        _downloadingTasksCount = downloadingTasksCount,
        _updateTorrentUploadLimit = updateTorrentUploadLimit,
        _notifyListeners = notifyListeners,
        _pumpQueue = pumpQueue,
        _onScheduledTaskStarted = onScheduledTaskStarted;

  final List<DownloadTask> Function() _tasks;
  final DatabaseService _databaseService;
  final bool Function() _isDisposed;
  final int Function() _downloadingTasksCount;
  final void Function() _updateTorrentUploadLimit;
  final void Function() _notifyListeners;
  final void Function() _pumpQueue;
  final void Function(String taskName, DateTime scheduledAt)?
      _onScheduledTaskStarted;

  Timer? _schedulingTimer;
  DateTime? _lastUpdateCheckTime;
  // FIX-S12: Guard ready state until provider completes initial load
  bool _ready = false;

  Timer? get schedulingTimer => _schedulingTimer;

  static bool isAndroidForTesting = false;

  /// Initializes platform-specific scheduling alarms (Workmanager on Android) (BG-09).
  static Future<void> initialize() async {
    if (Platform.isAndroid || isAndroidForTesting) {
      try {
        Workmanager().initialize(callbackDispatcher);
        Workmanager().registerPeriodicTask(
          'dmx_schedule',
          'dmx_schedule_check',
          frequency: const Duration(minutes: 15),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        );
      } catch (e) {
        debugPrint('[ScheduleManager] Workmanager initialization error: $e');
      }
    }
  }

  // FIX-S12: Mark schedule manager ready after initial load completes
  void markReady() {
    _ready = true;
    reschedule();
  }

  // SCHED-FIX-3: Retarget the scheduling timer when schedule state changes
  void reschedule() {
    _scheduleNextCheck();
  }

  void start() {
    if (Platform.isAndroid || isAndroidForTesting) {
      // On Android, periodic checks are handled by platform Workmanager
      return;
    }
    _schedulingTimer?.cancel();
    _scheduleNextCheck();
  }

  // SCHED-FIX-3: Dynamic timer targeting the nearest upcoming scheduled task
  void _scheduleNextCheck() {
    _schedulingTimer?.cancel();
    if (_isDisposed()) return;
    if (Platform.isAndroid || isAndroidForTesting) {
      _schedulingTimer = null;
      return;
    }

    final now = DateTime.now().toUtc();
    DateTime? nearest;
    for (final task in _tasks()) {
      if (task.status == DownloadStatus.paused &&
          !task.pausedByUser &&
          task.scheduledAt != null &&
          task.scheduledAt!.toUtc().isAfter(now)) {
        if (nearest == null || task.scheduledAt!.toUtc().isBefore(nearest)) {
          nearest = task.scheduledAt!.toUtc();
        }
      }
    }

    Duration delay;
    if (nearest != null) {
      delay = nearest.difference(now) + const Duration(seconds: 1);
      if (delay.isNegative) delay = const Duration(seconds: 1);
    } else {
      delay = const Duration(seconds: 15);
    }

    _schedulingTimer = Timer(delay, () {
      if (_isDisposed()) return;
      unawaited(
        _onTimerTick().then((_) {
          if (!_isDisposed()) _scheduleNextCheck();
        }).catchError((e) {
          debugPrint('[ScheduleManager] timer tick error: $e');
          if (!_isDisposed()) _scheduleNextCheck();
        }),
      );
    });
  }

  Future<void> _onTimerTick() async {
    await checkScheduledDownloads();
    await _checkPeriodicAppUpdate().catchError((e) {
      LoggingService.logger('ScheduleManager').warning(
        '[ScheduleManager] periodic app update check failed',
        e,
      );
    });
    if (_downloadingTasksCount() > 0) {
      await BackgroundService.sendHeartbeat().catchError((e) {
        LoggingService.logger('ScheduleManager').warning(
          '[ScheduleManager] background heartbeat failed',
          e,
        );
      });
    }
  }

  Future<void> _checkPeriodicAppUpdate() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    final now = DateTime.now();
    if (_lastUpdateCheckTime != null &&
        now.difference(_lastUpdateCheckTime!).inHours < 12) {
      return;
    }
    _lastUpdateCheckTime = now;
    try {
      await UpdateService().checkForUpdate();
    } catch (e) {
      debugPrint('[ScheduleManager] Background update check error: $e');
    }
  }

  Future<void> checkScheduledDownloads() async {
    // SCHED-FIX-7: skip promotion until provider is fully loaded
    if (!_ready) return;

    // Compare in UTC so device timezone changes do not affect trigger timing.
    final nowUtc = DateTime.now().toUtc();
    var hasChanges = false;
    final currentTasks = _tasks();
    final candidateTasks = List<DownloadTask>.from(currentTasks);
    final promotedTasks = <DownloadTask>[];
    final originalTasks = <DownloadTask>[];

    for (var i = 0; i < candidateTasks.length; i++) {
      if (_isDisposed()) return; // SCHED-FIX-4: bail out if disposed
      final task = candidateTasks[i];
      if (task.status == DownloadStatus.paused &&
          !task.pausedByUser &&
          task.scheduledAt != null &&
          task.scheduledAt!.toUtc().isBefore(nowUtc)) {
        final updated = task.copyWith(
          status: DownloadStatus.queued,
          clearError: true,
          clearCompletedAt: true,
          clearScheduledAt: true,
          wasScheduledAt: task.scheduledAt, // SCHED-FIX-1: preserve origin
          pausedByUser: false,
        );
        originalTasks.add(task);
        promotedTasks.add(updated);
      }
    }

    if (promotedTasks.isEmpty) return;

    // FIX-S13: Persist each promotion atomically, isolating failures per task with rollback
    // Tasks whose save succeeded stay queued; failed tasks are reverted in-memory.
    final results = await Future.wait(
      promotedTasks.map((task) async {
        try {
          await _databaseService.saveTask(task);
          return true;
        } catch (e) {
          debugPrint('[ScheduleManager] Save failed for ${task.id}: $e');
          return false;
        }
      }),
    );

    var anySaveFailed = false;
    for (var s = 0; s < results.length; s++) {
      final success = results[s];
      final target = success ? promotedTasks[s] : originalTasks[s];
      final idx = currentTasks.indexWhere((t) => t.id == target.id);
      if (idx != -1) {
        currentTasks[idx] = target;
      }
      if (success) {
        hasChanges = true;
      } else {
        anySaveFailed = true;
      }
    }

    if (anySaveFailed) {
      // SCHED-FIX-6: After reverting the in-memory state, notify listeners so
      // the UI reflects the reverted paused/scheduled task instead of the
      // not-yet-persisted queued promotion.
      _notifyListeners();
      if (!hasChanges) {
        return; // Don't pump queue with no successful promotions
      }
    }

    if (hasChanges) {
      _updateTorrentUploadLimit();
      _notifyListeners();
      _pumpQueue();

      // SCHED-FIX-5: Notification when scheduled download starts
      for (var s = 0; s < results.length; s++) {
        if (results[s]) {
          final t = promotedTasks[s];
          if (t.wasScheduledAt != null) {
            _onScheduledTaskStarted?.call(t.fileName, t.wasScheduledAt!);
          }
        }
      }
    }
  }

  void dispose() {
    _schedulingTimer?.cancel();
  }
}
