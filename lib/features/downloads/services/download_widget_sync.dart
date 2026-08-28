import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../../../core/services/power_monitor.dart';
import '../../../core/services/widget_data_bridge.dart';
import '../models/download_task.dart';

class _WidgetBuildArgs {
  final List<DownloadTask> allTasks;
  final Map<String, List<double>> speedHistories;
  final int availableStorageBytes;
  final bool isOnWifi;
  final int completedTodayCount;

  _WidgetBuildArgs({
    required this.allTasks,
    required this.speedHistories,
    required this.availableStorageBytes,
    required this.isOnWifi,
    required this.completedTodayCount,
  });
}

/// Service responsible for bridging download states, speeds, and active tasks
/// to Android AppWidgets and iOS WidgetKit / Live Activities.
class DownloadWidgetSync {
  final WidgetDataBridge _bridge;
  DateTime _lastPushTime = DateTime.fromMillisecondsSinceEpoch(0);

  DownloadWidgetSync({WidgetDataBridge? bridge})
      : _bridge = bridge ?? WidgetDataBridge.instance;

  static WidgetDashboard _buildDashboardIsolate(_WidgetBuildArgs args) {
    final summaries = <WidgetTaskSummary>[];
    for (final task in args.allTasks) {
      var status = task.status.name;
      if (task.isActivelySeeding) {
        status = 'seeding';
      }
      final history = args.speedHistories[task.id] ?? const <double>[];
      final recentSamples =
          history.where((s) => s > 0).map((s) => s.round()).toList();
      final recent5 = recentSamples.length > 5
          ? recentSamples.sublist(recentSamples.length - 5)
          : recentSamples;
      final trend = WidgetDataBridge.calculateSpeedTrend(recent5);

      summaries.add(
        WidgetTaskSummary(
          id: task.id,
          fileName: task.fileName,
          status: status,
          progress: task.progress,
          speedBytesPerSec: task.status == DownloadStatus.downloading
              ? task.speed.round()
              : 0,
          etaSeconds: task.eta,
          fileSizeBytes: task.combinedTotalSize,
          downloadedBytes: task.combinedDownloadedBytes,
          category: task.category,
          thumbnailUrl: task.thumbnailUrl,
          playlistId: task.playlistId,
          playlistTitle: task.playlistTitle,
          errorMessage: task.errorMessage,
          isTorrent: task.isTorrent,
          priority: task.priority,
          isAppUpdate: task.isAppUpdate,
          speedTrend: trend,
        ),
      );
    }

    return WidgetDashboard.fromTasks(
      summaries,
      availableStorageBytes: args.availableStorageBytes,
      isOnWifi: args.isOnWifi,
      completedTodayCount: args.completedTodayCount,
    );
  }

  /// Synchronizes current active downloads and overall metrics to widgets.
  Future<void> syncDashboard({
    required List<DownloadTask> allTasks,
    required Map<String, Queue<double>> speedHistories,
    bool isOnWifi = false,
  }) async {
    try {
      final now = DateTime.now();
      final minInterval = PowerMonitor.screenOff
          ? WidgetDataBridge.screenOffMinPushInterval
          : WidgetDataBridge.minPushInterval;

      final activeTasks = allTasks
          .where((t) => t.status == DownloadStatus.downloading)
          .toList();

      if (activeTasks.isEmpty &&
          now.difference(_lastPushTime) < const Duration(seconds: 15)) {
        return;
      }

      if (activeTasks.isNotEmpty &&
          now.difference(_lastPushTime) < minInterval) {
        return;
      }

      _lastPushTime = now;
      final freeSpace = await _bridge.fetchFreeDiskSpace();

      final todayStart = DateTime(now.year, now.month, now.day);
      final completedToday = allTasks.where((t) {
        if (t.status != DownloadStatus.completed) return false;
        final completedAt = t.completedAt;
        return completedAt != null && completedAt.isAfter(todayStart);
      }).length;

      final historiesMap =
          speedHistories.map((k, v) => MapEntry(k, v.toList()));
      final args = _WidgetBuildArgs(
        allTasks: allTasks,
        speedHistories: historiesMap,
        availableStorageBytes: freeSpace,
        isOnWifi: isOnWifi,
        completedTodayCount: completedToday,
      );

      final dashboard = (!kIsWeb && allTasks.length > 5)
          ? await compute(_buildDashboardIsolate, args)
          : _buildDashboardIsolate(args);

      await _bridge.pushDashboard(dashboard);
    } catch (e) {
      debugPrint('[DownloadWidgetSync] Widget sync failed: $e');
    }
  }
}
