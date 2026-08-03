import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// Data model for a single download task consumed by the launcher widgets.
///
/// Serialised to JSON and pushed to the native layer (Android widget
/// SharedPreferences, iOS App Group container) by [WidgetDataBridge].
class WidgetTaskSummary {
  final String id;
  final String fileName;
  final String status; // queued | downloading | paused | completed | failed | seeding
  final double progress; // 0.0 - 1.0
  final int speedBytesPerSec;
  final int? etaSeconds;
  final int fileSizeBytes;
  final int downloadedBytes;
  final String category;
  final String? thumbnailUrl;
  final String? playlistId;
  final String? playlistTitle;
  final int? playlistIndex;
  final String? errorMessage;
  final bool isTorrent;
  final double? seedingRatio;
  final int priority;
  final bool isAppUpdate;
  final String speedTrend; // up | down | stable

  const WidgetTaskSummary({
    required this.id,
    required this.fileName,
    required this.status,
    required this.progress,
    required this.speedBytesPerSec,
    this.etaSeconds,
    required this.fileSizeBytes,
    required this.downloadedBytes,
    required this.category,
    this.thumbnailUrl,
    this.playlistId,
    this.playlistTitle,
    this.playlistIndex,
    this.errorMessage,
    required this.isTorrent,
    this.seedingRatio,
    required this.priority,
    required this.isAppUpdate,
    required this.speedTrend,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'status': status,
        'progress': progress,
        'speedBytesPerSec': speedBytesPerSec,
        'etaSeconds': etaSeconds,
        'fileSizeBytes': fileSizeBytes,
        'downloadedBytes': downloadedBytes,
        'category': category,
        'thumbnailUrl': thumbnailUrl,
        'playlistId': playlistId,
        'playlistTitle': playlistTitle,
        'playlistIndex': playlistIndex,
        'errorMessage': errorMessage,
        'isTorrent': isTorrent,
        'seedingRatio': seedingRatio,
        'priority': priority,
        'isAppUpdate': isAppUpdate,
        'speedTrend': speedTrend,
      };
}

/// Aggregated download state snapshot for the launcher widgets.
class WidgetDashboard {
  final List<WidgetTaskSummary> tasks;
  final int totalActiveCount;
  final int totalSpeedBytesPerSec;
  final int totalDownloadedBytes;
  final int totalFileSizeBytes;
  final int completedTodayCount;
  final int failedCount;
  final int availableStorageBytes; // -1 = unknown
  final bool isOnWifi;
  final DateTime lastUpdated;

  const WidgetDashboard({
    required this.tasks,
    required this.totalActiveCount,
    required this.totalSpeedBytesPerSec,
    required this.totalDownloadedBytes,
    required this.totalFileSizeBytes,
    required this.completedTodayCount,
    required this.failedCount,
    required this.availableStorageBytes,
    required this.isOnWifi,
    required this.lastUpdated,
  });

  bool get hasActiveDownloads => totalActiveCount > 0;
  bool get hasFailures => failedCount > 0;
  bool get isStorageLow => availableStorageBytes >= 0 && availableStorageBytes < 500 * 1024 * 1024;
  bool get isStorageCritical => availableStorageBytes >= 0 && availableStorageBytes < 100 * 1024 * 1024;

  Map<String, dynamic> toJson() => {
        'tasks': tasks.map((t) => t.toJson()).toList(),
        'totalActiveCount': totalActiveCount,
        'totalSpeedBytesPerSec': totalSpeedBytesPerSec,
        'totalDownloadedBytes': totalDownloadedBytes,
        'totalFileSizeBytes': totalFileSizeBytes,
        'completedTodayCount': completedTodayCount,
        'failedCount': failedCount,
        'availableStorageBytes': availableStorageBytes,
        'isOnWifi': isOnWifi,
        'lastUpdated': lastUpdated.toIso8601String(),
      };

  /// Builds a dashboard from an arbitrary list of [tasks] descriptions.
  ///
  /// Sorting (per the smart-launcher spec):
  /// failed first → app updates → active (by priority, high first) →
  /// queued → paused → completed.
  factory WidgetDashboard.fromTasks(
    List<WidgetTaskSummary> tasks, {
    required int availableStorageBytes,
    required bool isOnWifi,
    int completedTodayCount = 0,
  }) {
    var totalSpeed = 0;
    var activeCount = 0;
    var downloadedBytes = 0;
    var fileSizeBytes = 0;
    var failed = 0;

    for (final t in tasks) {
      if (t.status == 'downloading' || t.status == 'seeding') {
        activeCount++;
        if (t.status == 'downloading') totalSpeed += t.speedBytesPerSec;
      }
      downloadedBytes += t.downloadedBytes;
      fileSizeBytes += t.fileSizeBytes;
      if (t.status == 'failed') failed++;
    }

    final sorted = List<WidgetTaskSummary>.of(tasks)
      ..sort((a, b) {
        int rank(WidgetTaskSummary t) {
          switch (t.status) {
            case 'failed':
              return 0;
            case 'seeding':
            case 'downloading':
              return 1;
            case 'queued':
              return 2;
            case 'paused':
              return 3;
            case 'completed':
              return 4;
            default:
              return 5;
          }
        }

        final ra = rank(a);
        final rb = rank(b);
        if (ra != rb) return ra.compareTo(rb);
        if (a.isAppUpdate != b.isAppUpdate) return a.isAppUpdate ? -1 : 1;
        if (ra == 1) return b.priority.compareTo(a.priority);
        return a.fileName.compareTo(b.fileName);
      });

    return WidgetDashboard(
      tasks: sorted,
      totalActiveCount: activeCount,
      totalSpeedBytesPerSec: totalSpeed,
      totalDownloadedBytes: downloadedBytes,
      totalFileSizeBytes: fileSizeBytes,
      completedTodayCount: completedTodayCount,
      failedCount: failed,
      availableStorageBytes: availableStorageBytes,
      isOnWifi: isOnWifi,
      lastUpdated: DateTime.now(),
    );
  }
}

/// Serialises download state into a JSON dashboard and pushes it to the
/// native widget layer over `MethodChannel('com.dmx.app/widget_bridge')`.
///
/// Native counterparts:
///  - Android: `MainActivity` handler → SharedPreferences + widget broadcast
///  - iOS:     `AppDelegate` handler → App Group container + WidgetKit reload
class WidgetDataBridge {
  static final _log = Logger('WidgetDataBridge');

  /// Process-wide singleton.
  static final WidgetDataBridge instance = WidgetDataBridge();

  static const MethodChannel channel = MethodChannel('com.dmx.app/widget_bridge');

  static const Duration minPushInterval = Duration(seconds: 5);

  /// Injectable sink used by unit tests to capture pushes without a platform.
  @visibleForTesting
  static Future<void> Function(WidgetDashboard dashboard)? testSink;

  DateTime? _lastPush;
  Timer? _pendingTimer;

  /// Pushes [dashboard] to the native widgets.
  ///
  /// Regular pushes are throttled to one per [minPushInterval]. Pass
  /// [force] = `true` for state transitions (pause, resume, complete, fail)
  /// that must appear on the widget immediately.
  Future<void> pushDashboard(WidgetDashboard dashboard, {bool force = false}) async {
    if (kIsWeb) return;
    _pendingTimer?.cancel();
    _pendingTimer = null;

    final now = DateTime.now();
    if (!force &&
        _lastPush != null &&
        now.difference(_lastPush!) < minPushInterval) {
      final wait = minPushInterval - now.difference(_lastPush!);
      _pendingTimer = Timer(wait, () {
        _pendingTimer = null;
        unawaited(_doPush(dashboard));
      });
      return;
    }

    await _doPush(dashboard);
  }

  Future<void> _doPush(WidgetDashboard dashboard) async {
    _lastPush = DateTime.now();
    try {
      final payload = jsonEncode(dashboard.toJson());
      final test = testSink;
      if (test != null) {
        await test(dashboard);
        return;
      }
      await channel.invokeMethod<void>('pushDashboard', payload);
    } catch (e) {
      // Widget pushes are non-critical — never surface to the user.
      _log.fine('Widget dashboard push failed: $e');
    }
  }

  /// Free disk space in bytes, or `-1` when the platform can't report it.
  Future<int> fetchFreeDiskSpace() async {
    if (kIsWeb) return -1;
    try {
      final test = testSink;
      if (test != null) return -1;
      final value = await channel.invokeMethod<int>('getFreeDiskSpace');
      return value ?? -1;
    } catch (e) {
      return -1;
    }
  }

  /// Speed trend from the last speed samples: 'up', 'down' or 'stable'.
  static String calculateSpeedTrend(List<int> recentSpeeds) {
    if (recentSpeeds.length < 2) return 'stable';
    final current = recentSpeeds.last.toDouble();
    final previous = recentSpeeds[recentSpeeds.length - 2].toDouble();
    if (previous <= 0) return 'stable';
    if (current > previous * 1.1) return 'up';
    if (current < previous * 0.9) return 'down';
    return 'stable';
  }

  /// ETA in seconds from remaining bytes and current speed; `null` when
  /// stalled or unknown.
  static int? calculateEta(int remainingBytes, int speedBytesPerSec) {
    if (speedBytesPerSec <= 0 || remainingBytes <= 0) return null;
    return (remainingBytes / speedBytesPerSec).ceil();
  }

  /// Formats an ETA for widget display.
  static String formatEta(int? etaSeconds) {
    if (etaSeconds == null || etaSeconds <= 0) return '--';
    if (etaSeconds < 60) return 'Almost done';
    if (etaSeconds < 300) return '~${etaSeconds ~/ 60} min';
    if (etaSeconds < 3600) {
      final minutes = etaSeconds ~/ 60;
      final seconds = etaSeconds % 60;
      return '~${minutes}m ${seconds}s';
    }
    final hours = etaSeconds ~/ 3600;
    final minutes = (etaSeconds % 3600) ~/ 60;
    if (minutes == 0) return '~${hours}h';
    return '~${hours}h ${minutes}m';
  }

  /// Storage threshold checks shared with the native widgets.
  static bool isStorageLow(int availableBytes) =>
      availableBytes >= 0 && availableBytes < 500 * 1024 * 1024;

  static bool isStorageCritical(int availableBytes) =>
      availableBytes >= 0 && availableBytes < 100 * 1024 * 1024;
}
