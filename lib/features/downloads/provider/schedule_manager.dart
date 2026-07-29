import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../../core/services/background_service.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/update_service.dart';
import '../models/download_task.dart';

/// Owns the periodic scheduling timer and schedule evaluation.
///
/// Extracted from [DownloadProvider] (Refactor A). Every 15 seconds it
/// promotes due scheduled tasks to the queue, triggers the periodic app
/// update check, and keeps the background service heartbeat alive while
/// downloads are running. All task/queue mutations go through the
/// constructor callbacks into the provider.
class ScheduleManager {
  ScheduleManager({
    required List<DownloadTask> Function() tasks,
    required DatabaseService databaseService,
    required bool Function() isDisposed,
    required int Function() downloadingTasksCount,
    required void Function() updateTorrentUploadLimit,
    required void Function() notifyListeners,
    required void Function() pumpQueue,
  }) : _tasks = tasks,
       _databaseService = databaseService,
       _isDisposed = isDisposed,
       _downloadingTasksCount = downloadingTasksCount,
       _updateTorrentUploadLimit = updateTorrentUploadLimit,
       _notifyListeners = notifyListeners,
       _pumpQueue = pumpQueue;

  final List<DownloadTask> Function() _tasks;
  final DatabaseService _databaseService;
  final bool Function() _isDisposed;
  final int Function() _downloadingTasksCount;
  final void Function() _updateTorrentUploadLimit;
  final void Function() _notifyListeners;
  final void Function() _pumpQueue;

  Timer? _schedulingTimer;
  DateTime? _lastUpdateCheckTime;

  void start() {
    _schedulingTimer?.cancel();
    _schedulingTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (_isDisposed()) {
        timer.cancel();
        return;
      }
      unawaited(
        checkScheduledDownloads().catchError((e) {
          debugPrint('[ScheduleManager] checkScheduledDownloads error: $e');
        }),
      );
      unawaited(_checkPeriodicAppUpdate());
      if (_downloadingTasksCount() > 0) {
        unawaited(BackgroundService.sendHeartbeat());
      }
    });
  }

  Future<void> _checkPeriodicAppUpdate() async {
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
    // Compare in UTC so device timezone changes do not affect trigger timing.
    final nowUtc = DateTime.now().toUtc();
    var hasChanges = false;
    final saves = <Future<void>>[];
    final tasks = _tasks();
    for (var i = 0; i < tasks.length; i++) {
      final task = tasks[i];
      if (task.status == DownloadStatus.paused &&
          !task.pausedByUser &&
          task.scheduledAt != null &&
          task.scheduledAt!.toUtc().isBefore(nowUtc)) {
        tasks[i] = task.copyWith(
          status: DownloadStatus.queued,
          clearError: true,
          clearCompletedAt: true,
          clearScheduledAt: true,
        );
        saves.add(_databaseService.saveTask(tasks[i]));
        hasChanges = true;
      }
    }
    if (saves.isNotEmpty) {
      // Run all saves concurrently; eagerError: false ensures every save is
      // attempted even if an earlier one fails (unlike the default behaviour
      // which stops at the first error and silently drops remaining saves).
      await Future.wait(
        saves.map(
          (f) => f.catchError((Object e) {
            debugPrint('Failed to save a scheduled task: $e');
          }),
        ),
        eagerError: false,
      );
    }
    if (hasChanges) {
      _updateTorrentUploadLimit();
      _notifyListeners();
      _pumpQueue();
    }
  }

  void dispose() {
    _schedulingTimer?.cancel();
  }
}
