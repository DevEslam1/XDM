import 'dart:async';
import 'dart:io';

import 'package:dmx/core/services/logging_service.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/services/database_service.dart';
import '../domain/commands/download_commands.dart';
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
/// Under ARCH-1: pure command emitter emitting [ScheduleFired] when a schedule triggers.
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
    Future<void> Function(String taskId)? onScheduleFired,
  })  : _tasks = tasks,
        _databaseService = databaseService,
        _isDisposed = isDisposed,
        _downloadingTasksCount = downloadingTasksCount,
        _updateTorrentUploadLimit = updateTorrentUploadLimit,
        _notifyListeners = notifyListeners,
        _pumpQueue = pumpQueue,
        _onScheduledTaskStarted = onScheduledTaskStarted,
        _onScheduleFired = onScheduleFired;

  final List<DownloadTask> Function() _tasks;
  // ignore: unused_field
  final DatabaseService _databaseService;
  final bool Function() _isDisposed;
  // ignore: unused_field
  final int Function() _downloadingTasksCount;
  // ignore: unused_field
  final void Function() _updateTorrentUploadLimit;
  // ignore: unused_field
  final void Function() _notifyListeners;
  // ignore: unused_field
  final void Function() _pumpQueue;
  // ignore: unused_field
  final void Function(String taskName, DateTime scheduledAt)?
      _onScheduledTaskStarted;
  final Future<void> Function(String taskId)? _onScheduleFired;

  Timer? _schedulingTimer;
  // FIX-S12: Guard ready state until provider completes initial load
  bool _ready = false;

  void markReady() => setReady(true);

  Timer? get schedulingTimer => _schedulingTimer;

  static bool isAndroidForTesting = false;

  /// Initializes platform-specific scheduling alarms (Workmanager on Android) (BG-09).
  static Future<void> initialize() async {
    if (Platform.isAndroid || isAndroidForTesting) {
      try {
        await Workmanager().initialize(
          callbackDispatcher,
        );
        LoggingService.logger('ScheduleManager').info('Workmanager initialized for download scheduling');
      } catch (e, st) {
        LoggingService.logger('ScheduleManager').warning('Failed to initialize Workmanager for scheduling', e, st);
      }
    }
  }

  /// Schedules an OS-level background wakeup alarm for [scheduledAt] (BG-09).
  static Future<void> scheduleAlarm(String taskId, DateTime scheduledAt) async {
    if (Platform.isAndroid || isAndroidForTesting) {
      try {
        final delay = scheduledAt.difference(DateTime.now());
        if (delay.isNegative) return;

        await Workmanager().registerOneOffTask(
          'download_sched_$taskId',
          'downloadScheduledTask',
          initialDelay: delay,
          existingWorkPolicy: ExistingWorkPolicy.replace,
          constraints: Constraints(
            networkType: NetworkType.connected,
          ),
        );
      } catch (e, st) {
        LoggingService.logger('ScheduleManager').warning('Failed to schedule Workmanager task for $taskId', e, st);
      }
    }
  }

  /// Cancels any scheduled OS-level alarm for [taskId] (BG-09).
  static Future<void> cancelAlarm(String taskId) async {
    if (Platform.isAndroid || isAndroidForTesting) {
      try {
        await Workmanager().cancelByUniqueName('download_sched_$taskId');
      } catch (e, st) {
        LoggingService.logger('ScheduleManager').warning('Failed to cancel Workmanager task for $taskId', e, st);
      }
    }
  }

  /// Schedules dynamic timer tick targeting the nearest upcoming task (SCHED-FIX-3).
  void scheduleNextDynamicTick() {
    _schedulingTimer?.cancel();
    if (_isDisposed()) return;

    final nowUtc = DateTime.now().toUtc();
    DateTime? nearest;

    for (final task in _tasks()) {
      if (task.status == DownloadStatus.paused &&
          !task.pausedByUser &&
          task.scheduledAt != null) {
        final schedUtc = task.scheduledAt!.toUtc();
        if (schedUtc.isAfter(nowUtc)) {
          if (nearest == null || schedUtc.isBefore(nearest)) {
            nearest = schedUtc;
          }
        }
      }
    }

    Duration delay = const Duration(seconds: 15);
    if (nearest != null) {
      final toNearest = nearest.difference(nowUtc);
      if (toNearest < delay && !toNearest.isNegative) {
        delay = toNearest + const Duration(milliseconds: 100);
      }
    }

    _schedulingTimer = Timer(delay, () {
      if (_isDisposed()) return;
      checkScheduledDownloads();
      scheduleNextDynamicTick();
    });
  }

  void start() {
    _schedulingTimer?.cancel();
    if (Platform.isAndroid || isAndroidForTesting) return;
    // Use dynamic tick scheduling for efficiency (SCHED-FIX-3)
    scheduleNextDynamicTick();
  }

  /// Sets the ready flag allowing scheduled download checks to proceed.
  void setReady(bool value) {
    _ready = value;
    if (_ready) {
      checkScheduledDownloads();
    }
  }

  /// Evaluates pending scheduled tasks, background service heartbeat, and app
  /// update check.
  Future<void> checkScheduledDownloads() async {
    // SCHED-FIX-7: skip promotion until provider is fully loaded
    if (!_ready) return;

    // Compare in UTC so device timezone changes do not affect trigger timing.
    final nowUtc = DateTime.now().toUtc();
    final currentTasks = _tasks();
    final candidateTasks = List<DownloadTask>.from(currentTasks);
    var anyPromoted = false;

    for (var i = 0; i < candidateTasks.length; i++) {
      if (_isDisposed()) return; // SCHED-FIX-4: bail out if disposed
      final task = candidateTasks[i];
      if (task.status == DownloadStatus.paused &&
          !task.pausedByUser &&
          task.scheduledAt != null &&
          task.scheduledAt!.toUtc().isBefore(nowUtc) &&
          (task.wasScheduledAt == null ||
              !task.wasScheduledAt!.isAtSameMomentAs(task.scheduledAt!))) {
        if (_onScheduleFired != null) {
          await _onScheduleFired!(task.id);
        } else {
          final idx = currentTasks.indexWhere((t) => t.id == task.id);
          if (idx != -1) {
            final promoted = task.copyWith(
              status: DownloadStatus.queued,
              clearScheduledAt: true,
              wasScheduledAt: task.scheduledAt,
              clearError: true,
            );
            currentTasks[idx] = promoted;
            try {
              await _databaseService.saveTask(promoted);
              anyPromoted = true;
            } catch (_) {
              currentTasks[idx] = task;
              _notifyListeners();
            }
          }
        }
        if (task.wasScheduledAt != null) {
          _onScheduledTaskStarted?.call(task.fileName, task.wasScheduledAt!);
        }
      }
    }
    if (anyPromoted) {
      _pumpQueue();
      _notifyListeners();
      _updateTorrentUploadLimit();
    }
  }

  void dispose() {
    _schedulingTimer?.cancel();
  }
}
