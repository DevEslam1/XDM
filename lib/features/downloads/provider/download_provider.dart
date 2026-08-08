import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../core/services/torrent_resume_store.dart';
import '../../../core/services/torrent_service.dart';

import '../../../core/services/update_service.dart';
import '../../../core/services/youtube_service.dart';

// ignore_for_file: prefer_initializing_formals
import '../../../core/services/background_service.dart';
import '../../../core/services/database/app_database.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/download_engine.dart';
import '../../../core/services/download_journal.dart';
import '../../../core/services/error_taxonomy.dart';
import '../../../core/services/download_metrics.dart';
import '../../../core/services/logging_service.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/widget_data_bridge.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/url_utils.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';
import 'download_orchestrator.dart';
import 'network_monitor.dart';
import 'notification_coordinator.dart';
import '../../../core/services/site_intelligence/site_intelligence_service.dart';
import 'schedule_manager.dart';
import 'mixins/download_filter_mixin.dart';
import 'mixins/download_queue_mixin.dart';
import 'mixins/download_torrent_mixin.dart';
import 'mixins/download_backup_mixin.dart';

/// A compact description for a single download item that can be added in bulk.
class DownloadAddSpec {
  final String name;
  final String url;
  final int size;
  final String category;
  final String savePath;
  final int? threadCount;
  final DateTime? scheduledAt;
  final List<Map<String, dynamic>>? torrentFiles;
  final String? downloadPageUrl;
  final String? mergedAudioUrl;
  final int audioSize;
  final String? youtubeQualityPreset;
  final int? torrentId;
  final bool isAppUpdate;
  final String? playlistId;
  final String? playlistTitle;
  final String? thumbnailUrl;

  const DownloadAddSpec({
    required this.name,
    required this.url,
    required this.size,
    required this.category,
    required this.savePath,
    this.threadCount,
    this.scheduledAt,
    this.torrentFiles,
    this.downloadPageUrl,
    this.mergedAudioUrl,
    this.audioSize = 0,
    this.youtubeQualityPreset,
    this.torrentId,
    this.isAppUpdate = false,
    this.playlistId,
    this.playlistTitle,
    this.thumbnailUrl,
  });
}

/// Result of offloaded file-stat for partial progress reconciliation.
class _PartialFileState {
  final bool exists;
  final int targetSize;
  final String? stateContent;

  const _PartialFileState({
    this.exists = false,
    this.targetSize = 0,
    this.stateContent,
  });
}

/// The central [ChangeNotifier] that owns the download task list and
/// orchestrates all state mutations.
class DownloadProvider extends ChangeNotifier
    with
        DownloadFilterMixin,
        DownloadQueueMixin,
        DownloadTorrentMixin,
        DownloadBackupMixin
    implements DownloadOrchestratorHost {
  DownloadProvider({
    required DatabaseService databaseService,
    required SettingsProvider settingsProvider,
    DownloadEngine? downloadEngine,
    PermissionService? permissionService,
    NotificationService? notificationService,
    bool enableBackgroundTimers = true,
  })  : _databaseService = databaseService,
        _settingsProvider = settingsProvider,
        _downloadEngine = downloadEngine ?? DownloadEngine(),
        _permissionService = permissionService ?? PermissionService(),
        _notificationService = notificationService ?? NotificationService(),
        enableBackgroundTimers = enableBackgroundTimers &&
            !Platform.environment.containsKey('FLUTTER_TEST') {
    _settingsProvider.addListener(_onSettingsChanged);

    _networkMonitor = NetworkMonitor(
      tasks: () => _tasks,
      torrentIds: () => _torrentIds,
      cancelTokens: () => _cancelTokens,
      wifiOnly: () => _settingsProvider.wifiOnly,
      setTask: _setTask,
      pumpQueue: pumpQueue,
    );
    _networkMonitor.init();

    _notifications = NotificationCoordinator(
      notificationService: _notificationService,
      settingsProvider: _settingsProvider,
      downloadingTasksCount: () => downloadingTasksCount,
      currentDownloadSpeed: () => currentDownloadSpeed,
      findTask: _findTask,
      onPauseTask: pauseTask,
      onResumeTask: resumeTask,
      onCancelTask: cancelTask,
      onPauseAll: pauseAllTasks,
      onResumeAll: resumeAllTasks,
    );
    _notifications.init();

    _scheduleManager = ScheduleManager(
      tasks: () => _tasks,
      databaseService: _databaseService,
      isDisposed: () => _disposed,
      downloadingTasksCount: () => downloadingTasksCount,
      updateTorrentUploadLimit: updateActualTorrentUploadLimit,
      notifyListeners: notifyListeners,
      pumpQueue: pumpQueue,
      onScheduledTaskStarted: (taskName, scheduledAt) {
        _notifications.showScheduledStarted(taskName, scheduledAt);
      },
    );
    if (enableBackgroundTimers) {
      _scheduleManager.start();
    }

    _orchestrator = DownloadOrchestrator(this);

    // Subscribe lazily — torrent engine may not be initialized yet.
    if (enableBackgroundTimers) {
      _initTorrentSubscription();
    }
  }

  Timer? _torrentInitTimer;

  bool _isLoadingTasks = true;
  bool get isLoadingTasks => _isLoadingTasks;

  int _torrentInitRetries = 0;
  static const int _maxTorrentInitRetries = 15;

  void _initTorrentSubscription() {
    if (_torrentUpdatesSubscription != null) return;
    if (!TorrentService.isInitialized) {
      _torrentInitRetries++;
      if (_torrentInitRetries >= _maxTorrentInitRetries) {
        _log.warning(
          'TorrentService.init never completed after $_maxTorrentInitRetries retries. Giving up.',
        );
        return;
      }
      _torrentInitTimer?.cancel();
      _torrentInitTimer = Timer(const Duration(seconds: 2), () {
        if (_disposed) return;
        _initTorrentSubscription();
      });
      return;
    }
    _torrentInitRetries = 0;
    _torrentUpdatesSubscription = TorrentService.torrentUpdates.listen(
      (torrents) {
        _latestTorrentStats = torrents;
        // Prune stats for torrents that were removed
        if (_latestTorrentStats.length > torrents.length + 50) {
          _latestTorrentStats.removeWhere(
            (id, _) => !torrents.containsKey(id),
          );
        }
        checkTorrentRatioLimits();
        enforceTorrentQueue();

        // Transition torrents in native error state to DownloadStatus.failed
        for (final entry in torrents.entries) {
          final tid = entry.key;
          final info = entry.value;

          // FIX T-5: Sync uploadedBytes in real-time during seeding
          if (info.totalPayloadUpload > 0) {
            final taskIdx = _tasks.indexWhere((t) {
              final id = _torrentIds[t.id];
              return id == tid;
            });
            if (taskIdx != -1 &&
                _tasks[taskIdx].uploadedBytes != info.totalPayloadUpload) {
              _tasks[taskIdx] = _tasks[taskIdx].copyWith(
                uploadedBytes: info.totalPayloadUpload,
              );
            }
          }

          final stateLabel = info.stateLabel.toLowerCase();
          if (stateLabel.contains('error')) {
            // Find the task for this torrent id
            final taskId = _torrentIds.entries
                .where((e) => e.value == tid)
                .map((e) => e.key)
                .firstOrNull;
            if (taskId != null) {
              final task = _findTask(taskId);
              if (task != null && task.status == DownloadStatus.downloading) {
                unawaited(_setTask(task.copyWith(
                  status: DownloadStatus.failed,
                  errorMessage: 'Torrent engine error: ${info.stateLabel}',
                  speed: 0,
                  clearEta: true,
                )));
              }
            }
          }
        }
      },
    );
  }

  StreamSubscription? _torrentUpdatesSubscription;

  final DatabaseService _databaseService;
  final SettingsProvider _settingsProvider;
  final DownloadEngine _downloadEngine;
  final PermissionService _permissionService;
  final NotificationService _notificationService;

  static final _log = LoggingService.logger('DownloadProvider');

  final List<DownloadTask> _tasks = [];
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, bool> _resumeRejectionRestarts = {};
  final Map<String, Queue<double>> _speedHistories = {};
  final Map<String, Future<void>> _dbSaveQueues = {};

  /// Per-task progress and speed ValueNotifiers for isolated repainting.
  final Map<String, ValueNotifier<double>> _progressNotifiers = {};
  final Map<String, ValueNotifier<double>> _speedNotifiers = {};

  ValueNotifier<double> progressNotifier(String taskId) {
    return _progressNotifiers.putIfAbsent(taskId, () {
      final idx = _tasks.indexWhere((t) => t.id == taskId);
      final initialProgress = idx != -1 ? _tasks[idx].progress : 0.0;
      return ValueNotifier(initialProgress);
    });
  }

  ValueNotifier<double> speedNotifier(String taskId) =>
      _speedNotifiers.putIfAbsent(taskId, () => ValueNotifier(0.0));

  void _pushTick(String taskId, double progress, double speed) {
    final progressNotif = progressNotifier(taskId);
    final speedNotif = speedNotifier(taskId);
    // FIX-AUDIT-E1: Only update if change is visually / numerically significant
    if ((progressNotif.value - progress).abs() > 0.005 ||
        progress >= 1.0 ||
        progress <= 0.0) {
      progressNotif.value = progress;
    }
    if ((speedNotif.value - speed).abs() > 1024 || speed == 0.0) {
      speedNotif.value = speed;
    }
  }

  /// FIX(R2): Surfaces the most recent DB-save failure without crashing the zone.
  /// Callers (e.g. UI snackbars) can listen to this to warn the user.
  final ValueNotifier<String?> lastSaveError = ValueNotifier<String?>(null);

  void clearLastSaveError() {
    lastSaveError.value = null;
  }

  final Map<String, int> _ytLowSpeedCounts = {};
  final Map<String, bool> _ytThrottlingRefreshing = {};

  final Map<String, int> _lastProgressUpdateTimes = {};
  final Map<String, int> _lastDbSaveTimes = {};
  final Map<String, int> _lastDbSaveBytes = {};
  final Map<String, int> _lastTorrentFileDiskSync = {};

  final Set<String> _pendingProgressUpdates = {};
  final Map<String, int> _torrentIds = {};

  late final NotificationCoordinator _notifications;
  late final DownloadOrchestrator _orchestrator;

  int _generation = 0;
  bool _disposed = false;

  @override
  final bool enableBackgroundTimers;

  final Map<String, int> _retryCounts = {};
  final Map<String, int> _dbRetryCounts = {};
  Map<int, TorrentUpdateInfo> _latestTorrentStats = {};

  List<double> getSpeedHistory(String id) =>
      _speedHistories[id]?.toList() ?? const [];

  late final NetworkMonitor _networkMonitor;
  late final ScheduleManager _scheduleManager;

  Timer? _widgetTimer;
  bool _notifyPending = false;
  final Map<String, Timer> _retryTimers = {};
  final Map<String, Timer> _dbRetryTimers = {};
  final Map<String, DownloadMetrics> _downloadMetrics = {};
  final Map<String, Future<void>> _activeFutures = {};

  final Set<String> _flushingIds = {};

  String? _lastError;
  String? get lastError => _lastError;

  static String _dbCorruptionMessage(String? doubleErr, String? torrentErr) {
    final parts = <String>[];
    if (doubleErr != null) parts.add('chunks: $doubleErr');
    if (torrentErr != null) parts.add('torrent files: $torrentErr');
    return parts.isEmpty ? 'unknown' : parts.join('; ');
  }

  // ---------------------------------------------------------------------------
  // Mixin contract implementations
  // ---------------------------------------------------------------------------

  @override
  List<DownloadTask> get providerTasks => _tasks;

  @override
  DatabaseService get providerDatabaseService => _databaseService;

  @override
  SettingsProvider get providerSettingsProvider => _settingsProvider;

  @override
  Map<String, int> get providerTorrentIds => _torrentIds;

  @override
  Map<int, TorrentUpdateInfo> get providerLatestTorrentStats =>
      _latestTorrentStats;

  @override
  DownloadTask? findTaskById(String id) => _findTask(id);

  @override
  bool startTaskFromQueue(DownloadTask task) => _orchestrator.startTask(task);

  @override
  bool isTaskPendingStart(String taskId) =>
      _orchestrator.isTaskPendingStart(taskId);

  @override
  void updateTelemetryWidget({bool force = false}) =>
      _updateTelemetryWidget(force: force);

  @override
  bool isTaskWaitingForRetry(String taskId) => _retryTimers.containsKey(taskId);

  @override
  void providerNotifyListeners() => notifyListeners();

  @override
  void pushProgressTick(String taskId, double progress, double speed) =>
      _pushTick(taskId, progress, speed);

  @override
  void providerStartWidgetTimer() => _startWidgetTimer();

  // ---------------------------------------------------------------------------
  // DownloadOrchestratorHost contract implementations
  // ---------------------------------------------------------------------------

  @override
  Map<String, CancelToken> get cancelTokens => _cancelTokens;

  @override
  Map<String, bool> get resumeRejectionRestarts => _resumeRejectionRestarts;

  @override
  Map<String, Future<void>> get activeFutures => _activeFutures;

  @override
  Map<String, Timer> get retryTimers => _retryTimers;

  @override
  Map<String, int> get retryCounts => _retryCounts;

  @override
  Map<String, Queue<double>> get speedHistories => _speedHistories;

  @override
  Map<String, int> get lastProgressUpdateTimes => _lastProgressUpdateTimes;

  @override
  Map<String, int> get lastDbSaveTimes => _lastDbSaveTimes;

  @override
  Map<String, int> get lastTorrentFileDiskSync => _lastTorrentFileDiskSync;

  @override
  Set<String> get pendingProgressUpdates => _pendingProgressUpdates;

  @override
  Map<String, int> get ytLowSpeedCounts => _ytLowSpeedCounts;

  @override
  Map<String, bool> get ytThrottlingRefreshing => _ytThrottlingRefreshing;

  @override
  bool get providerDisposed => _disposed;

  @override
  Map<String, DownloadMetrics> get downloadMetrics => _downloadMetrics;

  @override
  DownloadEngine get downloadEngine => _downloadEngine;

  @override
  NotificationCoordinator get notifications => _notifications;

  @override
  NetworkMonitor get networkMonitor => _networkMonitor;

  @override
  Future<void> setTaskState(DownloadTask task) => _setTask(task);

  @override
  Future<void> flushPendingProgress(String id) => _flushPendingProgress(id);

  @override
  int effectiveSpeedLimit() => _effectiveSpeedLimit();

  @override
  List<double> buildChunks(
    int threadCount,
    int fileSize,
    int downloadedBytes,
  ) =>
      _buildChunks(threadCount, fileSize, downloadedBytes);

  @override
  ({int total, List<Map<String, dynamic>>? files}) scanExistingTorrentData(
    String rootPath,
    List<Map<String, dynamic>>? fileList,
  ) =>
      _scanExistingTorrentData(rootPath, fileList);

  @override
  void providerStopWidgetTimer() => _stopWidgetTimer();

  // ---------------------------------------------------------------------------
  // Public getters (delegated to [DownloadFilterMixin])
  // ---------------------------------------------------------------------------

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  DownloadMetrics? getMetrics(String taskId) => _downloadMetrics[taskId];

  @override
  void notifyListeners() {
    if (isBatchMode) {
      markBatchDirty();
    } else {
      super.notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Tab switching (wires ad-blocker callback from the mixin)
  // ---------------------------------------------------------------------------

  void setActiveTabIndex(int index) {
    setMixinActiveTabIndex(index);
  }

  // ---------------------------------------------------------------------------
  // Load / initialization
  // ---------------------------------------------------------------------------

  /// Offloaded file-stat — runs in a background isolate so the UI isolate is
  /// never blocked by filesystem I/O during reconciliation.
  static Future<_PartialFileState> _statPartialFileIsolate(
    String tempFilePath,
  ) async {
    return Isolate.run(() async {
      final targetFile = File(tempFilePath);
      if (!await targetFile.exists()) return const _PartialFileState();

      final targetSize = await targetFile.length();

      String? stateContent;
      final stateFile = File('$tempFilePath.dmxstate');
      if (await stateFile.exists()) {
        try {
          stateContent = await stateFile.readAsString();
        } catch (e, st) {
          _log.warning('[download_provider] operation failed', e, st);
        }
      }

      return _PartialFileState(
        exists: true,
        targetSize: targetSize,
        stateContent: stateContent,
      );
    });
  }

  static int torrentBytesFromFiles(List<Map<String, dynamic>>? files) {
    if (files == null || files.isEmpty) return 0;
    return files.fold<int>(0, (sum, f) {
      if (isTorrentFileSelected(f)) {
        final bytes = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        return sum + (bytes > 0 ? bytes : 0);
      }
      return sum;
    });
  }

  static int torrentSelectedFilesTotalSize(List<Map<String, dynamic>>? files) {
    if (files == null || files.isEmpty) return 0;
    return files.fold<int>(0, (sum, f) {
      if (isTorrentFileSelected(f)) {
        return sum + ((f['length'] as num?)?.toInt() ?? 0);
      }
      return sum;
    });
  }

  static List<double> reconcileChunks({
    required List<double>? stateChunks,
    required int actualBytesOnDisk,
    required int fileSize,
    required int threadCount,
  }) {
    final n = threadCount > 0 ? threadCount : 1;
    if (fileSize <= 0 || actualBytesOnDisk <= 0) {
      return List.filled(n, 0.0);
    }
    final overall = (actualBytesOnDisk / fileSize).clamp(0.0, 1.0);
    if (stateChunks == null || stateChunks.isEmpty) {
      return List.filled(n, overall);
    }
    if (stateChunks.length != n) {
      return List.filled(n, overall);
    }
    final chunkAvg = stateChunks.fold<double>(0.0, (s, c) => s + c) / n;
    if (chunkAvg <= 0) return List.filled(n, overall);
    final scale = overall / chunkAvg;
    return stateChunks.map((c) => (c * scale).clamp(0.0, 1.0)).toList();
  }

  static Future<DownloadTask> validateAudioProgress(DownloadTask task) async {
    if (task.mergedAudioUrl == null || task.mergedAudioUrl!.isEmpty) {
      return task;
    }
    final audioPath = '${task.tempFilePath}.audio';
    final audioStateFile = File('$audioPath.dmxstate');
    final audioFile = File(audioPath);

    // FIX-S5: Detect audio format change on URL refresh via itag sidecar
    final oldItag = Uri.tryParse(task.mergedAudioUrl!)?.queryParameters['itag'];
    final itagFile = File('$audioPath.itag');
    if (await itagFile.exists()) {
      final savedItag = (await itagFile.readAsString()).trim();
      if (oldItag != null && savedItag != oldItag) {
        debugPrint(
            '[DMX] S5: Audio itag changed ($savedItag → $oldItag), resetting audio state');
        for (final p in [
          audioPath,
          '$audioPath.dmxstate',
          '$audioPath.dmxstate.tmp',
          '$audioPath.journal',
          '$audioPath.itag',
        ]) {
          try {
            final f = File(p);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
        return task.copyWith(audioProgress: 0.0, audioDownloadedBytes: 0);
      }
    }
    if (oldItag != null) {
      try {
        await itagFile.writeAsString(oldItag);
      } catch (_) {}
    }

    if (await audioStateFile.exists()) {
      try {
        final content = await audioStateFile.readAsString();
        jsonDecode(content);
      } catch (e) {
        debugPrint('[DMX] Corrupt .audio.dmxstate detected, deleting.');
        try {
          await audioStateFile.delete();
        } catch (_) {}
      }
    }

    if (!await audioFile.exists()) {
      if (await audioStateFile.exists()) {
        try {
          await audioStateFile.delete();
        } catch (_) {}
      }
      return task.copyWith(audioProgress: 0.0, audioDownloadedBytes: 0);
    }

    final audioBytes = await actualDownloadedBytes(
      audioFile.path,
      threadCount: task.audioThreadCount > 0 ? task.audioThreadCount : 1,
    );

    // FIX-C3: Guard against pre-allocated empty audio file
    if (task.audioSize > 0 && audioBytes >= task.audioSize) {
      try {
        final raf = await audioFile.open(mode: FileMode.read);
        final readLen = min(1024, task.audioSize);
        final probe = await raf.read(readLen);
        await raf.close();
        final hasContent = probe.any((b) => b != 0);
        if (!hasContent) {
          debugPrint(
              '[DMX] FIX-C3: Audio file is pre-allocated but empty, resetting');
          return task.copyWith(audioProgress: 0.0, audioDownloadedBytes: 0);
        }
      } catch (e) {
        debugPrint('[DMX] FIX-C3: Probe empty check error: $e');
      }
    }

    if (task.audioSize > 0 && audioBytes > 0) {
      final recovered = (audioBytes / task.audioSize).clamp(0.0, 1.0);
      return task.copyWith(
          audioProgress: recovered, audioDownloadedBytes: audioBytes);
    } else if (audioBytes > 0 && task.audioSize <= 0) {
      // FIX-01: Size unknown — trust existing progress, do NOT reset to 0
      return task.copyWith(
        audioProgress: task.audioProgress > 0 ? task.audioProgress : 0.5,
        audioDownloadedBytes: audioBytes,
      );
    }
    return task.copyWith(audioProgress: 0.0, audioDownloadedBytes: 0);
  }

  Future<int?> _actualPartialBytes(DownloadTask task) async {
    if (task.tempFilePath.trim().isEmpty) return null;

    final fileState = await _statPartialFileIsolate(task.tempFilePath);
    if (!fileState.exists) {
      return task.downloadedBytes;
    }

    final targetSize = fileState.targetSize;
    int videoBytes = 0;

    if (task.threadCount > 1) {
      if (fileState.stateContent != null) {
        try {
          final decoded = jsonDecode(fileState.stateContent!);

          List? progressList;

          if (decoded is Map) {
            final dynamic rawProgress = decoded['progress'];
            if (rawProgress is List) {
              progressList = rawProgress;
            }
          } else if (decoded is List) {
            // Legacy compatibility: older builds stored a bare list.
            progressList = decoded;
          }

          if (progressList != null) {
            BigInt total = BigInt.zero;

            for (final chunk in progressList) {
              total += BigInt.from((chunk as num).toInt());
            }

            final totalInt = total.toInt();
            videoBytes = totalInt > targetSize ? targetSize : totalInt;
          } else {
            videoBytes = task.downloadedBytes > 0
                ? task.downloadedBytes.clamp(0, targetSize)
                : 0;
          }
        } catch (e) {
          // State file corrupted — fall back to actual file size on disk
          debugPrint('[DMX] .dmxstate corrupted for ${task.id}, '
              'falling back to file size: $e');
          try {
            final partFile = File(task.tempFilePath);
            if (await partFile.exists()) {
              videoBytes = await partFile.length();
            }
          } catch (_) {}
        }
      } else {
        // Multi-threaded: partial file may be pre-allocated to full size.
        // Without .dmxstate, the file size is meaningless as progress.
        videoBytes = task.downloadedBytes > 0
            ? task.downloadedBytes.clamp(0, targetSize)
            : 0;
      }
    } else {
      if (task.downloadedBytes > 0 && task.downloadedBytes <= targetSize) {
        videoBytes = task.downloadedBytes;
      } else {
        videoBytes = targetSize;
      }
    }

    int audioBytes = 0;
    if (task.mergedAudioUrl != null && task.mergedAudioUrl!.isNotEmpty) {
      final audioPath = '${task.tempFilePath}.audio';
      audioBytes = await actualDownloadedBytes(
        audioPath,
        threadCount: task.audioThreadCount > 0 ? task.audioThreadCount : 1,
      );
    }

    return videoBytes + audioBytes;
  }

  Future<DownloadTask> _reconcilePartialProgress(DownloadTask task) async {
    if (task.status == DownloadStatus.completed) return task;

    // Do not reconcile progress for active downloads (their memory state is accurate)
    if (_cancelTokens.containsKey(task.id) ||
        task.status == DownloadStatus.downloading) {
      return task;
    }

    // Fix P5: Crash window auto-recovery — if temp file is missing or task is incomplete,
    // but the final localFilePath exists and matches/exceeds fileSize, mark task completed.
    if (task.localFilePath.trim().isNotEmpty) {
      final localFile = File(task.localFilePath);
      if (localFile.existsSync()) {
        final localLen = localFile.lengthSync();
        if (localLen > 0 && (task.fileSize <= 0 || localLen >= task.fileSize)) {
          return task.copyWith(
            status: DownloadStatus.completed,
            downloadedBytes: task.fileSize > 0 ? task.fileSize : localLen,
            completedAt: DateTime.now(),
            clearError: true,
          );
        }
      }
    }

    // Torrents manage their own fastresume data and piece maps.
    // Reading temporary HTTP chunk files would break torrent progress.
    if (task.isTorrent) return task;

    final actualBytes = await _actualPartialBytes(task);
    if (actualBytes == null || actualBytes == task.downloadedBytes) return task;

    final bytes =
        task.fileSize > 0 ? actualBytes.clamp(0, task.fileSize) : actualBytes;

    return task.copyWith(
      downloadedBytes: bytes,
      chunks: _buildChunks(task.threadCount, task.fileSize, bytes),
    );
  }

  /// B2: Called by main.dart after a permanent TorrentService init failure.
  /// Marks all isTorrent tasks that are stuck in a non-terminal state
  /// (e.g. waiting for metadata) with a visible error message so the UI
  /// reflects the unavailable engine rather than showing a hung progress bar.
  void markTorrentTasksFailed(String reason) {
    bool changed = false;
    for (var i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      if (!task.isTorrent) continue;
      if (task.status == DownloadStatus.completed ||
          task.status == DownloadStatus.failed) {
        continue;
      }
      _tasks[i] = task.copyWith(
        status: DownloadStatus.failed,
        errorMessage: reason,
        speed: 0,
      );
      unawaited(_databaseService.saveTask(_tasks[i]));
      changed = true;
    }
    if (changed) {
      filteredTasksDirty = true;
      notifyListeners();
    }
  }

  /// [pauseOrphanDownloads] should be true only on initial app startup, when
  /// in-flight downloads (from a previous run) cannot be resumed safely.
  /// On user-triggered reload, we must preserve currently active downloads.
  Future<void> load({bool pauseOrphanDownloads = true}) async {
    _generation++;
    _isLoadingTasks = true;

    // Cancel stale notifications from previous sessions
    await _notifications.cancelAll();

    final cleanupDays = _settingsProvider.cleanupDays;
    final now = DateTime.now();
    final toDelete = <DownloadTask>[];

    final dbTasks = await _databaseService.loadTasks();

    // Check for DB converter corruption signals
    final doubleCorruption = DoubleListConverter.lastConversionError.value;
    final torrentCorruption = TorrentFilesConverter.lastConversionError.value;
    if (doubleCorruption != null || torrentCorruption != null) {
      _log.severe(
        'DB corruption detected: $_dbCorruptionMessage(doubleCorruption, torrentCorruption)',
      );
      lastSaveError.value =
          'Data corruption detected. Some downloads may need re-downloading.';
      // Reset notifiers to avoid repeated warnings
      DoubleListConverter.lastConversionError.value = null;
      TorrentFilesConverter.lastConversionError.value = null;
    }

    final loaded = dbTasks.map((t) {
      // FIX-AUDIT-4: Clamp downloadedBytes to fileSize and chunks to [0.0, 1.0] to prevent >100% display.
      int clampedBytes = t.downloadedBytes;
      if (t.fileSize > 0 && clampedBytes > t.fileSize) {
        clampedBytes = t.fileSize;
      }
      final clampedChunks = t.chunks.map((c) => c.clamp(0.0, 1.0)).toList();
      final task = t.copyWith(
        downloadedBytes: clampedBytes,
        chunks: clampedChunks,
      );

      // Only mark in-flight downloads as paused on initial load.
      // If a CancelToken exists in the in-memory map, an active download
      // stream is still running and must not be flipped to paused.
      final hasActiveStream = _cancelTokens.containsKey(task.id);

      if (pauseOrphanDownloads &&
          (task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.merging) &&
          !hasActiveStream) {
        return task.copyWith(
          status: DownloadStatus.paused,
          speed: 0,
          clearEta: true,
          errorMessage: task.status == DownloadStatus.merging
              ? 'Merge was interrupted. Tap Resume/Retry to continue.'
              : DownloadStatusMessages.pausedOrphaned,
        );
      }

      return task.copyWith(
        speed: 0,
        clearEta: task.status != DownloadStatus.downloading,
      );
    }).where((task) {
      if (cleanupDays > 0 &&
          (task.status == DownloadStatus.completed ||
              task.status == DownloadStatus.failed)) {
        final difference =
            now.difference(task.completedAt ?? task.createdAt).inDays;

        if (difference >= cleanupDays) {
          toDelete.add(task);
          return false;
        }
      }
      return true;
    }).toList();

    // Phase 1 — load tasks into memory immediately so the UI can render.
    // File-reconciliation I/O is deferred to phase 2 (post-first-frame) below.
    _tasks
      ..clear()
      ..addAll(loaded);

    _isLoadingTasks = false;
    filteredTasksDirty = true;

    for (final task in toDelete) {
      await _databaseService.deleteTask(task.id);
      await cleanupPartFiles(task);
    }

    await _databaseService.saveTasks(_tasks);

    // In load(), after loading tasks:
    if (Platform.isIOS && !kIsWeb) {
      final activeDownloads = _tasks
          .where(
            (t) => t.status == DownloadStatus.downloading,
          )
          .length;
      if (activeDownloads > 0) {
        _log.warning(
          'iOS: $activeDownloads download(s) were active but iOS does not '
          'support background execution. They will pause.',
        );
        // Mark them as paused so the UI reflects reality
        for (var i = 0; i < _tasks.length; i++) {
          if (_tasks[i].status == DownloadStatus.downloading) {
            _tasks[i] = _tasks[i].copyWith(
              status: DownloadStatus.paused,
              speed: 0,
              clearEta: true,
              errorMessage: 'Paused: iOS does not support background downloads',
            );
          }
        }
      }
    }

    // Automatically restart seeding for completed torrents with seeding enabled
    for (final task in _tasks) {
      if (task.isTorrent &&
          task.status == DownloadStatus.completed &&
          task.seedingEnabled) {
        startSeedingTorrent(task);
      }
    }

    // FIX R-3: Recover torrent IDs for paused/in-progress torrents from TorrentService
    for (final task in _tasks) {
      if (task.isTorrent &&
          task.status != DownloadStatus.completed &&
          task.status != DownloadStatus.failed &&
          !_torrentIds.containsKey(task.id)) {
        for (final tid in TorrentService.activeTorrentIds) {
          try {
            final liveFiles = TorrentService.getFiles(tid);
            if (liveFiles.isNotEmpty &&
                task.torrentFiles != null &&
                liveFiles.length == task.torrentFiles!.length) {
              final liveNames = liveFiles.map((f) => f.name).toSet();
              final storedNames = task.torrentFiles!
                  .map((f) => (f['name'] as String? ?? ''))
                  .toSet();
              if (liveNames.length == storedNames.length &&
                  liveNames.containsAll(storedNames)) {
                _torrentIds[task.id] = tid;
                debugPrint(
                  '[DMX] load(): recovered torrent ID $tid for task ${task.id} (name-matched)',
                );
                break;
              }
            }
          } catch (_) {}
        }
      }
    }

    updateActualTorrentUploadLimit();

    _startWidgetTimer();
    notifyListeners();

    // Resolve connectivity BEFORE any scheduled downloads or pumpQueue to
    // prevent downloads starting on mobile data when wifiOnly is enabled.
    await _networkMonitor.ensureInitialConnectivity();
    await _networkMonitor.checkNetworkConnectivity(skipPump: true);

    // SCHED-FIX-7: Mark schedule manager ready after initial load completes
    _scheduleManager.markReady();
    _scheduleManager.checkScheduledDownloads();

    await _cleanupOrphanedFiles();

    if (_settingsProvider.autoStart) {
      await _autoResumeIncomplete();
    }

    // Always pump the queue so queued-downloads (including newly
    // auto-resumed ones) start without requiring user interaction.
    Future<void> safePumpQueue() async {
      if (TorrentService.isSupported && !TorrentService.isInitialized) {
        // Wait up to 10s for torrent init
        final stopwatch = Stopwatch()..start();
        while (!TorrentService.isInitialized &&
            stopwatch.elapsed < const Duration(seconds: 10)) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
      pumpQueue();
    }

    unawaited(safePumpQueue());

    _updateTelemetryWidget(force: true);

    // Phase 2 — deferred per-task file reconciliation (I/O heavy).
    // Runs after the first frame so the UI renders immediately with stale
    // progress, then updates in place once files are stat'ed.
    final loadGen = _generation;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_disposed || _generation != loadGen) return;

      final reconciled = <DownloadTask>[];

      // Run all per-task file-stat calls in parallel. Each call already
      // offloads to a background isolate via _statPartialFileIsolate, so
      // awaiting them sequentially wastes the parallelism opportunity.
      // FIX(C3): Batch reconciliation to avoid spawning N isolates
      // simultaneously. Process in batches of 4 to limit memory usage.
      const batchSize = 4;
      final pendingTasks = <DownloadTask>[];
      for (final task in _tasks) {
        final hasActiveStream = _cancelTokens.containsKey(task.id);

        if (hasActiveStream) {
          final memoryTask = _findTask(task.id);
          if (memoryTask != null) {
            reconciled.add(memoryTask);
            continue;
          }
        }

        pendingTasks.add(task);
      }

      for (var i = 0; i < pendingTasks.length; i += batchSize) {
        if (_disposed || _generation != loadGen) break;
        final batch = pendingTasks.skip(i).take(batchSize);
        final batchResults = await Future.wait(
          batch.map((task) async {
            try {
              return await _reconcilePartialProgress(task);
            } catch (e) {
              debugPrint('Failed to reconcile partial file for ${task.id}: $e');
              return task;
            }
          }),
        );
        reconciled.addAll(batchResults);
      }

      for (final task in reconciled) {
        final idx = _tasks.indexWhere((t) => t.id == task.id);
        if (idx != -1) {
          // If the task status in memory has transitioned during the async gap
          // (e.g. user resumed/paused/deleted it), do NOT overwrite live state!
          if (_tasks[idx].status != task.status &&
              _tasks[idx].status != DownloadStatus.paused) {
            continue;
          }
          if (_tasks[idx].status != task.status ||
              _tasks[idx].downloadedBytes != task.downloadedBytes) {
            _tasks[idx] = task;
            await _databaseService.saveTask(task);
          } else {
            _tasks[idx] = task;
          }
        }
      }

      notifyListeners();
    });
  }

  // ---------------------------------------------------------------------------
  // Download task lifecycle
  // ---------------------------------------------------------------------------

  Future<List<String>> addDownloadsBatch(List<DownloadAddSpec> specs) async {
    if (specs.isEmpty) return const <String>[];

    startBatch();
    try {
      final ids = <String>[];
      for (final spec in specs) {
        try {
          final id = await _addSingleDownload(
            name: spec.name,
            url: spec.url,
            size: spec.size,
            category: spec.category,
            savePath: spec.savePath,
            threadCount: spec.threadCount,
            scheduledAt: spec.scheduledAt,
            torrentFiles: spec.torrentFiles,
            downloadPageUrl: spec.downloadPageUrl,
            mergedAudioUrl: spec.mergedAudioUrl,
            audioSize: spec.audioSize,
            youtubeQualityPreset: spec.youtubeQualityPreset,
            torrentId: spec.torrentId,
            isAppUpdate: spec.isAppUpdate,
            playlistId: spec.playlistId,
            playlistTitle: spec.playlistTitle,
            thumbnailUrl: spec.thumbnailUrl,
            shouldPumpQueue: false,
          );
          ids.add(id);
        } catch (e) {
          debugPrint('[DMX] Failed to enqueue batch item ${spec.name}: $e');
        }
      }
      if (ids.isNotEmpty) {
        pumpQueue();
      }
      return ids;
    } finally {
      endBatch(notifyListeners);
    }
  }

  /// Adds multiple tasks in one shot, saves them in a single DB batch,
  /// then pumps the queue once with an elevated concurrency ceiling
  /// so an entire playlist starts downloading in parallel.
  Future<void> addBatchDownloads({
    required List<DownloadTask> tasks,
    required String savePath,
  }) async {
    if (tasks.isEmpty) return;

    // Defense-in-depth: validate that every task's file paths stay inside
    // the declared savePath. Because this method accepts pre-built
    // DownloadTask objects that bypass _addSingleDownload's sanitization,
    // it is the last line of defense before a path reaches the filesystem.
    // p.canonicalize is used (not resolveSymbolicLinksSync) so this works
    // even when the target directory does not yet exist.
    final canonicalSave = p.canonicalize(savePath);
    final safeTasks = tasks.where((task) {
      bool pathOk(String filePath) {
        if (filePath.isEmpty) return true;
        final canonical = p.canonicalize(filePath);
        return p.isWithin(canonicalSave, canonical) ||
            canonical == canonicalSave;
      }

      final ok = pathOk(task.localFilePath) && pathOk(task.tempFilePath);
      if (!ok) {
        _log.warning(
          '[Security] addBatchDownloads: rejecting task "${task.fileName}" '
          '— path escapes savePath.\n'
          '  localFilePath : ${task.localFilePath}\n'
          '  tempFilePath  : ${task.tempFilePath}\n'
          '  savePath      : $canonicalSave',
        );
      }
      return ok;
    }).toList();

    if (safeTasks.isEmpty) return;

    // 1. Add validated tasks to the in-memory list first (no pump yet).
    _tasks.addAll(safeTasks);
    filteredTasksDirty = true;

    // 2. Persist in a single batch write.
    try {
      await _databaseService.saveTasks(safeTasks);
    } catch (e) {
      debugPrint('[DMX] batch save failed: $e');
    }

    // 3. Notify UI immediately so all cards appear at once.
    notifyListeners();

    // 4. Pump once with the full batch size as the concurrency ceiling.
    pumpQueue(maxConcurrentOverride: safeTasks.length);
  }

  Future<void> addDownload({
    required String name,
    required String url,
    required int size,
    required String category,
    required String savePath,
    int? threadCount,
    DateTime? scheduledAt,
    List<Map<String, dynamic>>? torrentFiles,
    String? downloadPageUrl,
    String? mergedAudioUrl,
    int audioSize = 0,
    String? youtubeQualityPreset,
    int? torrentId,
    bool isAppUpdate = false,
    String? playlistId,
    String? playlistTitle,
    String? thumbnailUrl,
  }) async {
    _lastError = null;

    final urls = url
        .split(RegExp(r'[\r\n]+'))
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toList();

    if (urls.isEmpty) {
      _lastError = 'URL signal required.';
      notifyListeners();
      return;
    }

    final hasStorageAccess = await _permissionService.ensureStorageAccess();
    if (!hasStorageAccess) {
      _lastError = 'Storage permission was denied.';
      notifyListeners();
      throw Exception('Storage permission was denied.');
    }

    final resolvedThreadCount =
        (threadCount ?? _settingsProvider.defaultThreadCount).clamp(1, 32);

    try {
      if (urls.length > 1) {
        var addedCount = 0;

        for (var i = 0; i < urls.length; i++) {
          final singleUrl = urls[i];
          if (!isValidTransmissionUrl(singleUrl)) continue;

          final suffix = i + 1;
          final singleName =
              name.trim().isNotEmpty ? '${name.trim()}_$suffix' : '';

          await _addSingleDownload(
            name: singleName,
            url: singleUrl,
            size: size,
            category: category,
            savePath: savePath,
            threadCount: resolvedThreadCount,
            scheduledAt: scheduledAt,
            downloadPageUrl: downloadPageUrl,
            mergedAudioUrl: mergedAudioUrl,
            audioSize: audioSize,
            youtubeQualityPreset: youtubeQualityPreset,
            torrentId: torrentId,
            isAppUpdate: isAppUpdate,
            playlistId: playlistId,
            playlistTitle: playlistTitle,
            thumbnailUrl: thumbnailUrl,
          );

          addedCount++;
        }

        if (addedCount == 0) {
          _lastError = 'No valid URLs found in the list.';
          notifyListeners();
        }
      } else {
        final singleUrl = urls.first;

        if (!isValidTransmissionUrl(singleUrl)) {
          _lastError = 'Invalid target transmission URL/magnet.';
          notifyListeners();
          return;
        }

        await _addSingleDownload(
          name: name,
          url: singleUrl,
          size: size,
          category: category,
          savePath: savePath,
          threadCount: resolvedThreadCount,
          scheduledAt: scheduledAt,
          torrentFiles: torrentFiles,
          downloadPageUrl: downloadPageUrl,
          mergedAudioUrl: mergedAudioUrl,
          audioSize: audioSize,
          youtubeQualityPreset: youtubeQualityPreset,
          torrentId: torrentId,
          isAppUpdate: isAppUpdate,
          playlistId: playlistId,
          playlistTitle: playlistTitle,
          thumbnailUrl: thumbnailUrl,
        );
      }
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<String> _addSingleDownload({
    required String name,
    required String url,
    required int size,
    required String category,
    required String savePath,
    int? threadCount,
    DateTime? scheduledAt,
    List<Map<String, dynamic>>? torrentFiles,
    String? downloadPageUrl,
    String? mergedAudioUrl,
    int audioSize = 0,
    String? youtubeQualityPreset,
    int? torrentId,
    bool isAppUpdate = false,
    String? playlistId,
    String? playlistTitle,
    String? thumbnailUrl,
    bool shouldPumpQueue = true,
  }) async {
    final exists = _tasks.any((t) {
      if (t.status == DownloadStatus.failed ||
          t.status == DownloadStatus.completed ||
          t.status == DownloadStatus.paused) {
        return false;
      }

      if (downloadPageUrl != null &&
          downloadPageUrl.isNotEmpty &&
          youtubeQualityPreset != null &&
          t.downloadPageUrl == downloadPageUrl &&
          t.youtubeQualityPreset == youtubeQualityPreset) {
        return true;
      }

      return t.url == url;
    });

    if (exists && !isAppUpdate) {
      throw Exception('This download is already active in the queue.');
    }

    final targetSaveDir = savePath.isNotEmpty
        ? savePath
        : (_settingsProvider.customDownloadPath?.isNotEmpty == true
            ? _settingsProvider.customDownloadPath!
            : await _permissionService.defaultDownloadDirectory());

    if (size > 0 &&
        !await _downloadEngine.hasEnoughDiskSpace(targetSaveDir, size)) {
      throw const InsufficientStorageException();
    }

    // FIX-INTEL: Analyze URL for site intelligence and smart category resolution
    final analysis = SiteIntelligenceService().analyzeUrl(url);

    final defaultDirectory = targetSaveDir;

    final bool isMagnet = url.trim().toLowerCase().startsWith('magnet:');
    final bool isTorrent = isTorrentUrl(url, fileName: name);

    String resolvedCategory;
    String fileName;
    int fileSize;
    bool supportsResume;

    final int torrentFilesTotalSize =
        (torrentFiles != null && torrentFiles.isNotEmpty)
            ? torrentSelectedFilesTotalSize(torrentFiles)
            : 0;

    if (isMagnet) {
      final parsed = parseMagnetUrl(url.trim());
      final rawMagnetName = parsed['name'] ?? 'Torrent Download';
      final magnetName = safeFileName(rawMagnetName.replaceAll('+', ' '));

      fileName = name.trim().isNotEmpty
          ? safeFileName(name.trim().replaceAll('+', ' '))
          : magnetName;

      fileSize = size > 0
          ? size
          : (torrentFilesTotalSize > 0 ? torrentFilesTotalSize : 0);

      String catCandidate = categoryFromFileName(fileName);

      if ((catCandidate == 'Other' || catCandidate.isEmpty) &&
          torrentFiles != null &&
          torrentFiles.isNotEmpty) {
        final firstFile = torrentFiles.firstWhere(
          (f) => isTorrentFileSelected(f),
          orElse: () => torrentFiles.first,
        );

        final firstFileName = (firstFile['name'] as String? ?? '').replaceAll(
          '+',
          ' ',
        );

        if (firstFileName.isNotEmpty) {
          catCandidate = categoryFromFileName(firstFileName);
        }
      }

      resolvedCategory = (category.trim().isNotEmpty && category != 'Auto')
          ? category
          : resolveCategorySmart(
              url: url,
              fileName: fileName,
              siteType: analysis.siteType,
              contentHint: analysis.contentHint,
            );

      supportsResume = true;
    } else {
      fileName = name.trim().isNotEmpty
          ? safeFileName(name.trim().replaceAll('+', ' '))
          : fileNameFromUrl(url.trim());

      fileSize = size > 0
          ? size
          : (torrentFilesTotalSize > 0 ? torrentFilesTotalSize : 0);

      resolvedCategory = (category.trim().isNotEmpty && category != 'Auto')
          ? category
          : resolveCategorySmart(
              url: url,
              fileName: fileName,
              siteType: analysis.siteType,
              contentHint: analysis.contentHint,
            );

      supportsResume = true;
    }

    var directory =
        savePath.trim().isNotEmpty ? savePath.trim() : defaultDirectory;

    if (_settingsProvider.categoryFolders) {
      String subFolder = resolvedCategory;

      if (_settingsProvider.languageCode == 'ar') {
        subFolder = switch (resolvedCategory) {
          'Video' => 'فيديوهات',
          'Audio' => 'صوتيات',
          'Document' => 'مستندات',
          'Archive' => 'أرشيف',
          'APK' => 'تطبيقات',
          'Other' || 'General' => 'أخرى',
          _ => resolvedCategory,
        };
      }

      directory = p.join(directory, subFolder);
    }

    // Torrents/magnets must target their ORIGINAL folder (never renamed) so an
    // existing folder with partial data is found and the download resumes.
    // Everything else keeps the unique-name behaviour to avoid overwrites.
    String localFilePath;
    String tempFilePath;

    int existingBytes = 0;
    List<Map<String, dynamic>>? finalTorrentFiles = torrentFiles;

    if (isTorrent) {
      localFilePath = torrentSavePath(directory, fileName);
      tempFilePath = localFilePath;

      final scan = _scanExistingTorrentData(localFilePath, torrentFiles);
      existingBytes = scan.total;

      if (scan.files != null) {
        finalTorrentFiles = scan.files;
      }

      if (existingBytes > 0) {
        debugPrint(
          '[DMX] Found existing torrent data on disk: '
          '${formatBytes(existingBytes)} in $localFilePath — will resume.',
        );
      }
    } else {
      localFilePath = await getUniqueFilePath(directory, fileName);

      // Use the engine's temp naming so partial HTTP downloads are separated
      // from final files. This prevents accidental opening of incomplete files
      // and makes cleanup/rename behavior safer.
      tempFilePath = _downloadEngine.buildTempFilePath(
        p.dirname(localFilePath),
        p.basename(localFilePath),
      );
    }

    final now = DateTime.now();
    final isScheduled = scheduledAt != null && scheduledAt.isAfter(now);

    final effectiveThreadCount =
        (threadCount ?? _settingsProvider.defaultThreadCount).clamp(1, 32);

    // FIX(13): Calculate max existing queue order
    final maxOrder =
        _tasks.isEmpty ? -1 : _tasks.map((t) => t.queueOrder).reduce(max);

    final task = DownloadTask(
      id: '${now.microsecondsSinceEpoch}_${Random.secure().nextInt(1000000000)}',
      fileName: fileName,
      url: url.trim(),
      fileSize: fileSize,
      downloadedBytes: existingBytes,
      category: resolvedCategory,
      status: isScheduled ? DownloadStatus.paused : DownloadStatus.queued,
      savePath: directory,
      localFilePath: localFilePath,
      tempFilePath: tempFilePath,
      threadCount: effectiveThreadCount,
      chunks: List<double>.filled(effectiveThreadCount, 0.0),
      createdAt: now,
      updatedAt: now,
      scheduledAt: scheduledAt,
      supportsResume: supportsResume,
      queueOrder: maxOrder + 1, // FIX(13)
      seedingEnabled: _settingsProvider.globalTorrentSeeding,
      seedingLimited: _settingsProvider.globalTorrentSeedingLimited,
      seedingLimitKbps: _settingsProvider.globalTorrentSeedingLimitKbps,
      torrentFiles: finalTorrentFiles,
      downloadPageUrl: downloadPageUrl,
      mergedAudioUrl: mergedAudioUrl,
      audioSize: audioSize,
      youtubeQualityPreset: youtubeQualityPreset,
      isAppUpdate: isAppUpdate,
      playlistId: playlistId,
      playlistTitle: playlistTitle,
      thumbnailUrl: thumbnailUrl,
      // FIX-INTEL: Store site intelligence results on the task
      siteType: analysis.siteType.name,
      siteDisplayName: analysis.profile?.displayName,
      contentHint: analysis.contentHint.name,
    );

    _tasks.insert(0, task);

    if (torrentId != null) {
      _torrentIds[task.id] = torrentId;
    }

    filteredTasksDirty = true;

    await _databaseService.saveTask(task);

    notifyListeners();
    _updateTelemetryWidget(force: true);

    if (isScheduled) {
      _scheduleManager.reschedule();

      // FIX-T-04: Validate torrent handle before resume
      if (task.isTorrent && _torrentIds.containsKey(task.id)) {
        final tid = _torrentIds[task.id]!;
        if (!TorrentService.isTorrentAlive(tid)) {
          debugPrint('[DMX] T-04: Stale torrent handle $tid removed');
          _torrentIds.remove(task.id);
        }
      }
    } else if (shouldPumpQueue) {
      pumpQueue();
    }

    return task.id;
  }

  /// Marks a completed task as failed when its output file is missing on disk.
  Future<void> markCompletedFileMissing(String taskId) async {
    final task = _findTask(taskId);
    if (task == null) return;
    final updated = task.copyWith(
      status: DownloadStatus.failed,
      errorMessage: 'Downloaded file missing or inaccessible',
      clearEta: true,
      speed: 0,
    );
    await _setTask(updated);
  }

  /// Scans the torrent's target folder for data that's already on disk so a
  /// torrent can resume from it instead of starting over.
  ///
  /// Handles both layouts libtorrent produces:
  ///  - single-file torrent → the target path IS the file.
  ///  - multi-file torrent  → the target path is a folder; each file in
  ///    [fileList] is checked at its relative path inside it.
  /// When no file list is available yet (magnets before metadata) the whole
  /// folder is counted recursively as a best-effort estimate.
  ({int total, List<Map<String, dynamic>>? files}) _scanExistingTorrentData(
    String rootPath,
    List<Map<String, dynamic>>? fileList,
  ) {
    try {
      final type = FileSystemEntity.typeSync(rootPath);

      if (type == FileSystemEntityType.file) {
        final len = File(rootPath).lengthSync();
        final expected = (fileList?.isNotEmpty == true)
            ? ((fileList!.first['length'] as num?)?.toInt() ?? 0)
            : 0;
        // FIX(5): Pre-allocation guard: a full-size file is not proof of completion.
        final trusted = (expected > 0 && len >= expected) ? 0 : len;
        List<Map<String, dynamic>>? files = fileList;
        if (fileList != null && fileList.length == 1) {
          files = [
            Map<String, dynamic>.from(fileList.first)
              ..['downloadedBytes'] = trusted,
          ];
        }
        return (total: trusted, files: files);
      }

      if (type == FileSystemEntityType.directory) {
        if (fileList != null && fileList.isNotEmpty) {
          final scan = scanTorrentFilesOnDisk(rootPath, fileList);
          return (total: scan.total, files: scan.files);
        }

        return (total: scanFolderBytesSync(rootPath), files: null);
      }

      return (total: 0, files: fileList);
    } catch (e) {
      debugPrint('[DMX] Torrent pre-scan failed for $rootPath: $e');
      return (total: 0, files: fileList);
    }
  }

  @override
  Future<void> pauseTask(String id) async {
    _orchestrator.clearStartingFlag(id);
    final initialTask = _findTask(id);
    if (initialTask == null) return;
    DownloadTask task = initialTask;

    _retryCounts.remove(id);
    _speedHistories.remove(id);
    _lastProgressUpdateTimes.remove(id);
    _lastDbSaveTimes.remove(id);
    _lastDbSaveBytes.remove(id);
    _pendingProgressUpdates.remove(id);

    // FIX-R-04: Clear effectiveThreadOverrides entry on resume
    effectiveThreadOverrides.remove(id);

    _retryTimers[id]?.cancel();
    _retryTimers.remove(id);

    // FIX(C1): Handle seeding torrents — they have status=completed but
    // an active native handle that must be paused.
    final isSeedingTorrent = task.status == DownloadStatus.completed &&
        task.isTorrent &&
        task.seedingEnabled;

    if (task.status == DownloadStatus.downloading || isSeedingTorrent) {
      final torrentId = _torrentIds[id];

      // BUG 4 FIX: Cancel token and await engine future FIRST if downloading
      if (task.status == DownloadStatus.downloading) {
        // FIX-P-03: Flush writer before reading state
        await Future.delayed(const Duration(milliseconds: 300));

        // FIX-P3: Ensure disk writes are committed before progress flush
        try {
          if (torrentId == null) {
            debugPrint('[FIX-P3] Relying on engine cancel to flush writer');
          }
        } catch (e) {
          debugPrint('[FIX-P3] Pre-flush error: $e');
        }

        // FIX-11: Flush pending progress BEFORE cancelling token
        await _flushPendingProgress(id);

        // FIX-H-02: Ensure engine state file is flushed before cancel
        try {
          final latest = _findTask(id) ?? task;
          final stateFile = File('${latest.tempFilePath}.dmxstate');
          if (await stateFile.exists()) {
            final content = await stateFile.readAsString();
            jsonDecode(content); // throws on corrupt
          }
        } catch (_) {
          try {
            final latest = _findTask(id) ?? task;
            await File('${latest.tempFilePath}.dmxstate').delete();
          } catch (_) {}
        }

        // FIX(H-2): cancel token first so the future can actually complete
        if (_cancelTokens.containsKey(id)) {
          try {
            _cancelTokens[id]?.cancel('paused');
          } catch (e) {
            // ignore
          }
          final fut = _activeFutures[id];
          if (fut != null) {
            try {
              final pauseTimeoutSecs =
                  (task.fileSize) > 500 * 1024 * 1024 ? 20 : 8;
              await fut.timeout(Duration(seconds: pauseTimeoutSecs),
                  onTimeout: () {
                debugPrint(
                    '[FIX-P1] Engine future timed out on pause (${pauseTimeoutSecs}s)');
              });
            } catch (_) {}
          }

          _cancelTokens.remove(id);
          _activeFutures.remove(id);
        }
      }

      // BUG 4 FIX: THEN handle torrent pause & snapshot AFTER engine has stopped
      if (torrentId != null) {
        if (TorrentService.isTorrentAlive(torrentId)) {
          await TorrentService.pauseTorrent(torrentId);

          // B4 FIX: Poll until the torrent reports paused (max 2s timeout)
          final pauseDeadline = DateTime.now().add(const Duration(seconds: 2));
          bool isPaused = false;
          while (!isPaused && DateTime.now().isBefore(pauseDeadline)) {
            await Future.delayed(const Duration(milliseconds: 100));
            try {
              final latestStats = _latestTorrentStats[torrentId];
              final stateLabel = latestStats?.stateLabel.toLowerCase() ?? '';
              isPaused = stateLabel.contains('paused') ||
                  stateLabel.contains('stopped') ||
                  !TorrentService.isTorrentAlive(torrentId);
            } catch (_) {
              isPaused = true;
            }
          }
          if (!isPaused) {
            debugPrint(
              '[DMX] B4 FIX: Torrent $torrentId did not confirm pause within 2s, proceeding anyway',
            );
          }

          // Snapshot per-file bytes AFTER engine has stopped
          try {
            final liveFiles = TorrentService.getFiles(torrentId);
            if (liveFiles.isNotEmpty && task.torrentFiles != null) {
              final liveByName = {for (final lf in liveFiles) lf.name: lf};
              final updatedFiles = task.torrentFiles!.map((stored) {
                final live = liveByName[stored['name'] as String? ?? ''];
                if (live == null) return stored;
                final prevBytes =
                    (stored['downloadedBytes'] as num?)?.toInt() ?? 0;
                final liveBytes = live.downloadedBytes;
                final resolvedBytes = liveBytes >= 0 ? liveBytes : prevBytes;
                return {
                  ...stored,
                  'downloadedBytes': resolvedBytes,
                  'progressEstimated': liveBytes < 0,
                };
              }).toList();
              task = task.copyWith(torrentFiles: updatedFiles);
            }

            if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
              final recomputedTotal = task.torrentFiles!.fold<int>(0, (sum, f) {
                if (isTorrentFileSelected(f)) {
                  final bytes = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
                  return sum + (bytes > 0 ? bytes : 0);
                }
                return sum;
              });
              if (recomputedTotal > 0) {
                task = task.copyWith(downloadedBytes: recomputedTotal);
                debugPrint(
                  '[DMX] B7 FIX: Recomputed torrent aggregate: $recomputedTotal bytes',
                );
              }
            }
          } catch (e) {
            debugPrint('[DMX] B5 FIX: Failed to snapshot per-file bytes: $e');
          }

          // FIX-06: Save fast-resume data BEFORE pausing so a crash
          // between pause and app-exit doesn't lose resume state.
          try {
            await TorrentResumeStore.saveAll(
              {torrentId},
              (tid) => TorrentService.resumeBlobFor(tid),
            );
          } catch (e) {
            debugPrint('[DMX] FIX-06: Failed to save resume data on pause: $e');
          }
        } else {
          debugPrint(
              '[DMX] BUG-P1 FIX: Torrent handle $torrentId is stale/dead on pause.');
          _torrentIds.remove(id);
          task = task.copyWith(
            status: DownloadStatus.paused,
            speed: 0,
            clearEta: true,
            statusMessage:
                'Torrent session lost — will restart from last saved progress',
          );
          await _setTask(task);
          pumpQueue();
          return;
        }
      }

      _orchestrator.clearPushScheduled(id);
    }

    // FIX(S1): Clear stale thread override on pause
    effectiveThreadOverrides.remove(id);

    // Cancel any lingering progress notification (M2).
    _notifications.cancelForTask(id);

    // For seeding torrents, also disable seeding flag so it doesn't
    // auto-restart on next pump.
    if (isSeedingTorrent) {
      await _setTask(
        task.copyWith(
          seedingEnabled: false,
          speed: 0,
          clearEta: true,
          clearError: true,
          clearStatusMessage: true,
        ),
      );
      updateActualTorrentUploadLimit();
      _downloadEngine.updateSpeedLimit(
        _effectiveSpeedLimit(),
        activeOrSeedingCount,
      );
      pumpQueue();
      if (activeOrSeedingCount == 0) {
        _stopWidgetTimer();
      }
      _updateTelemetryWidget(force: true);
      return;
    }

    // Re-check live task after engine shutdown / completion
    var latest = _findTask(id);
    if (latest == null) return;
    // FIX(P8): Don't overwrite a genuine failed/completed state
    if (latest.status == DownloadStatus.completed ||
        latest.status == DownloadStatus.failed) {
      _cancelTokens.remove(id);
      return;
    }

    // SCHED-FIX-2: Only clear schedule if it's already past or null.
    final scheduleStillPending = latest.scheduledAt != null &&
        latest.scheduledAt!.toUtc().isAfter(DateTime.now().toUtc());

    // FIX(D1): Skip disk-byte reconciliation for torrents — libtorrent pre-allocates files
    if (latest.isTorrent) {
      final snapshotFiles = latest.torrentFiles ?? task.torrentFiles;
      // FIX-06: Recalculate aggregate downloadedBytes for torrents on pause
      int torrentTotalDownloaded = 0;
      if (snapshotFiles != null) {
        torrentTotalDownloaded = torrentBytesFromFiles(snapshotFiles);
      }
      if ((snapshotFiles == null || snapshotFiles.isEmpty) &&
          task.torrentFiles != null &&
          task.torrentFiles!.isNotEmpty) {
        debugPrint(
          '[DMX] FIX-T4: getFiles returned empty, keeping existing torrentFiles',
        );
      }
      await _setTask(
        latest.copyWith(
          status: DownloadStatus.paused,
          downloadedBytes: torrentTotalDownloaded > 0
              ? torrentTotalDownloaded
              : latest.downloadedBytes,
          speed: 0,
          clearEta: true,
          clearError: true,
          clearStatusMessage: true,
          clearScheduledAt: !scheduleStillPending,
          pausedByUser: true,
          torrentFiles: snapshotFiles,
        ),
      );
      if (scheduleStillPending) _scheduleManager.reschedule();
      return;
    }

    // FIX-P-03: Flush writer before reading state
    // For multi-thread downloads, ensure engine has committed writes.
    await Future.delayed(const Duration(milliseconds: 300));

    // FIX P-1 / FIX(H-7): Validate state file integrity before reading progress
    final stateFile = File('${latest.tempFilePath}.dmxstate');
    if (await stateFile.exists()) {
      try {
        final content = await stateFile.readAsString();
        jsonDecode(content); // throws on corrupt JSON
      } catch (e) {
        debugPrint(
            '[DMX] pauseTask: .dmxstate corrupt, attempting journal fallback');
        // Try journal recovery BEFORE deleting
        final journalFile = File('${latest.tempFilePath}.journal');
        bool recoveredFromJournal = false;
        try {
          final recovered = await DownloadJournal.recover(journalFile.path);
          if (recovered != null && recovered.isNotEmpty) {
            recoveredFromJournal = true;
            debugPrint(
                '[DMX] pauseTask: journal has data, preserving .dmxstate');
          }
        } catch (_) {}

        if (!recoveredFromJournal) {
          try {
            await stateFile.delete();
          } catch (_) {}
          debugPrint(
              '[DMX] pauseTask: deleted corrupt .dmxstate (no journal fallback)');
        }
      }
    }

    // Sync DB bytes with the authoritative state file
    // FIX-AUDIT-A3: Retry state read if it returns 0 but we know progress existed
    // FIX-AUDIT-A3: Retry state read if it returns 0 but we know progress existed
    var stateBytes = await _readDmxStateBytes(
      latest.tempFilePath,
      threadCount: latest.threadCount,
    );
    if (stateBytes == 0 && latest.downloadedBytes > 0) {
      await Future.delayed(const Duration(milliseconds: 500));
      stateBytes = await _readDmxStateBytes(
        latest.tempFilePath,
        threadCount: latest.threadCount,
      );
      if (stateBytes == 0) stateBytes = latest.downloadedBytes;
    }

    // FIX-9: Re-read the audio sidecar so the persisted audioProgress
    // matches what is actually on disk (the last engine tick may have
    // been swallowed by the cancel).
    if (latest.hasMergedAudio) {
      final audioPath = '${latest.tempFilePath}.audio';
      final audioStateFile = File('$audioPath.dmxstate');
      int audioThreads =
          latest.audioThreadCount > 0 ? latest.audioThreadCount : 1;
      if (await audioStateFile.exists()) {
        try {
          final content = await audioStateFile.readAsString();
          final decoded = jsonDecode(content);
          if (decoded is Map && decoded['threadCount'] is int) {
            audioThreads = decoded['threadCount'] as int;
          }
        } catch (_) {}
      }
      final audioDiskBytes = await actualDownloadedBytes(
        audioPath,
        threadCount: audioThreads,
      );
      if (audioDiskBytes > latest.audioDownloadedBytes) {
        latest = latest.copyWith(
          audioDownloadedBytes: audioDiskBytes,
          audioProgress: latest.audioSize > 0
              ? (audioDiskBytes / latest.audioSize).clamp(0.0, 1.0)
              : latest.audioProgress,
        );
      }
    }

    // FIX 6: Re-read actual byte count from disk after timeout/cancel
    final diskBytes = await actualDownloadedBytes(
      latest.tempFilePath,
      threadCount: latest.threadCount,
    );
    final safeBytes = diskBytes > 0 ? diskBytes : latest.downloadedBytes;

    // Track audio bytes on disk separately; NOT folded into downloadedBytes (see FIX-P-01 below).
    int audioBytesOnDisk = 0;
    if (latest.mergedAudioUrl != null && latest.mergedAudioUrl!.isNotEmpty) {
      final audioStatePath = '${latest.tempFilePath}.audio';
      final audioStateFile = File('$audioStatePath.dmxstate');
      int actualAudioThreads =
          latest.audioThreadCount > 0 ? latest.audioThreadCount : 1;
      if (await audioStateFile.exists()) {
        try {
          final content = await audioStateFile.readAsString();
          final decoded = jsonDecode(content);
          if (decoded is Map && decoded['threadCount'] is int) {
            actualAudioThreads = decoded['threadCount'] as int;
          }
        } catch (_) {}
      }
      audioBytesOnDisk = await actualDownloadedBytes(
        audioStatePath,
        threadCount: actualAudioThreads,
      );
    }
    final effectiveStateBytes = max(stateBytes, safeBytes);

    // FIX-P-01: Do NOT store videoBytes + audioBytes into downloadedBytes.
    // Store ONLY video bytes.
    var synced = effectiveStateBytes > 0 &&
            (latest.status == DownloadStatus.downloading ||
                latest.status == DownloadStatus.paused)
        ? latest.copyWith(downloadedBytes: effectiveStateBytes)
        : latest;

    // FIX P-2: Read per-chunk progress ratios from state document
    final stateChunks =
        await _readDmxStateChunks(latest.tempFilePath, latest.threadCount);
    if (stateChunks != null && stateChunks.isNotEmpty) {
      synced = synced.copyWith(chunks: stateChunks);
    }

    // FIX 3: Probe raw audio file length when audioBytesOnDisk is 0
    final validatedAudioTask = await validateAudioProgress(synced.copyWith(
      audioDownloadedBytes: audioBytesOnDisk,
      audioProgress: latest.audioSize > 0
          ? (audioBytesOnDisk / latest.audioSize).clamp(0.0, 1.0)
          : latest.audioProgress,
    ));
    double syncedAudioProgress = validatedAudioTask.audioProgress;

    // FIX-2: If pause fires while an audio onProgress callback is in-flight,
    // the in-memory audioProgress can lag the .audio file on disk. Re-read the
    // authoritative byte count and recompute the fraction so the paused task
    // resumes from the correct offset.
    if (synced.mergedAudioUrl != null &&
        synced.mergedAudioUrl!.isNotEmpty &&
        synced.audioSize > 0) {
      final diskAudioBytes = await actualDownloadedBytes(
        '${synced.tempFilePath}.audio',
        threadCount: synced.audioThreadCount > 0 ? synced.audioThreadCount : 1,
      );
      if (diskAudioBytes > 0) {
        final correctedFraction =
            (diskAudioBytes / synced.audioSize).clamp(0.0, 1.0);
        syncedAudioProgress = correctedFraction;
      }
    }

    // FIX(P5): Carry per-file snapshot into the final state
    final snapshotFiles = latest.torrentFiles ?? task.torrentFiles;

    await _setTask(
      synced.copyWith(
        status: DownloadStatus.paused,
        speed: 0,
        clearEta: true,
        clearError: true,
        clearStatusMessage: true,
        clearScheduledAt: !scheduleStillPending,
        pausedByUser: true,
        audioProgress: syncedAudioProgress,
        audioDownloadedBytes: audioBytesOnDisk,
        torrentFiles: snapshotFiles,
      ),
    );

    // FIX-P-05: Cancel notification for the paused task
    _notifications.cancelForTask(id);

    if (scheduleStillPending) {
      _scheduleManager.reschedule();
    }

    _downloadEngine.updateSpeedLimit(
      _effectiveSpeedLimit(),
      activeOrSeedingCount,
    );

    pumpQueue();

    if (activeOrSeedingCount == 0) {
      _stopWidgetTimer();
    }

    _updateTelemetryWidget();
  }

  // ---------------------------------------------------------------------------
  // Batch Operations
  // ---------------------------------------------------------------------------
  Future<void> pauseMultipleTasks(List<String> ids) async {
    for (final id in ids) {
      await pauseTask(id);
    }
  }

  Future<void> resumeMultipleTasks(List<String> ids) async {
    for (final id in ids) {
      await resumeTask(id);
    }
  }

  Future<void> deleteMultipleTasks(List<String> ids,
      {bool deleteFiles = false}) async {
    for (final id in List<String>.from(ids)) {
      await deleteTask(id, deleteFiles: deleteFiles);
    }
  }

  Future<void> changeCategoryForMultipleTasks(
      List<String> ids, String newCategory) async {
    for (final id in ids) {
      final task = _findTask(id);
      if (task != null) {
        await _setTask(task.copyWith(category: newCategory));
      }
    }
  }

  @override
  Future<void> resumeTask(String id) async {
    final rawTask = _findTask(id);
    if (rawTask == null) return;

    // FIX T-4: Validate torrent URL before resume
    if (rawTask.isTorrent) {
      final url = rawTask.url.trim();
      final isValid = url.startsWith('magnet:') ||
          url.endsWith('.torrent') ||
          url.startsWith('file://') ||
          url.startsWith('http://') ||
          url.startsWith('https://');
      if (!isValid) {
        await _setTask(rawTask.copyWith(
          status: DownloadStatus.failed,
          errorMessage:
              'Invalid torrent source URL. Please re-add the torrent.',
        ));
        return;
      }
    }

    var task = rawTask;
    final isStoppedSeedingTorrent = task.status == DownloadStatus.completed &&
        task.isTorrent &&
        !task.seedingEnabled;

    if (task.status != DownloadStatus.paused &&
        task.status != DownloadStatus.failed &&
        !isStoppedSeedingTorrent) {
      return;
    }

    if (task.isTorrent) {
      final torrentId = _torrentIds[task.id];
      if (torrentId != null && !TorrentService.isTorrentAlive(torrentId)) {
        _torrentIds.remove(task.id);
        debugPrint(
            '[DMX] B1 FIX: Removed stale torrent handle $torrentId for task ${task.id}');
      }
    }

    if (isStoppedSeedingTorrent) {
      await _setTask(
        task.copyWith(
          seedingEnabled: true,
          clearError: true,
          clearStatusMessage: true,
          pausedByUser: false,
        ),
      );
      updateActualTorrentUploadLimit();
      pumpQueue();
      _downloadEngine.updateSpeedLimit(
        _effectiveSpeedLimit(),
        activeOrSeedingCount,
      );
      _updateTelemetryWidget(force: true);
      return;
    }

    // FIX-R-04: Clear effectiveThreadOverrides entry on resume
    effectiveThreadOverrides.remove(id);

    _retryTimers[id]?.cancel();
    _retryTimers.remove(id);
    _retryCounts.remove(id);
    _resumeRejectionRestarts.remove(id);
    _orchestrator.clearSessionCachedTotalSize(id);

    // ═══ FIX YT-5: Proactive YouTube URL refresh on resume ═══
    if (task.youtubeQualityPreset != null &&
        task.downloadPageUrl != null &&
        task.downloadPageUrl!.isNotEmpty &&
        _isYoutubeUrlExpired(task.url)) {
      try {
        final fresh = await YoutubeService.getFreshStreams(
            task.downloadPageUrl!,
            preferredType: task.youtubePreferredType);
        if (fresh != null && fresh['url'] != null) {
          final freshUrl = fresh['url']!;
          final freshAudioUrl = fresh['audioUrl'];
          final urlChanged = freshUrl != task.url;
          final audioChanged =
              freshAudioUrl != null && freshAudioUrl != task.mergedAudioUrl;
          if (urlChanged || audioChanged) {
            debugPrint(
                '[DMX] YT-5 FIX: Refreshed expired stream URL on resume');
            final identityChanged =
                youtubeStreamIdentityChanged(task.url, freshUrl);
            if (identityChanged) {
              debugPrint(
                  '[DMX] YT-5 FIX: Stream identity changed on refresh, resetting progress and deleting video temp file');
              for (final p in [
                task.tempFilePath,
                '${task.tempFilePath}.dmxstate',
                '${task.tempFilePath}.journal',
              ]) {
                try {
                  final f = File(p);
                  if (await f.exists()) await f.delete();
                } catch (_) {}
              }
            } else if (urlChanged) {
              final stateFile = File('${task.tempFilePath}.dmxstate');
              if (await stateFile.exists()) {
                try {
                  await stateFile.delete();
                } catch (_) {}
              }
            }

            // ── FIX YT-1: Independent audio identity validation ──
            if (task.mergedAudioUrl != null &&
                task.mergedAudioUrl!.isNotEmpty) {
              final oldAudioUri = Uri.tryParse(task.mergedAudioUrl!);
              final newAudioUri =
                  freshAudioUrl != null ? Uri.tryParse(freshAudioUrl) : null;
              final oldAudioItag = oldAudioUri?.queryParameters['itag'];
              final newAudioItag = newAudioUri?.queryParameters['itag'];
              final oldAudioMime = oldAudioUri?.queryParameters['mime'];
              final newAudioMime = newAudioUri?.queryParameters['mime'];
              final audioIdentityChanged = (oldAudioItag != null &&
                      newAudioItag != null &&
                      oldAudioItag != newAudioItag) ||
                  (oldAudioMime != null &&
                      newAudioMime != null &&
                      oldAudioMime != newAudioMime);

              if (audioIdentityChanged) {
                debugPrint(
                    '[DMX] YT-1 FIX: Audio stream identity changed on resume, resetting audio progress');
                // Delete audio sidecars so the engine re-downloads cleanly
                for (final p in [
                  '${task.tempFilePath}.audio',
                  '${task.tempFilePath}.audio.dmxstate',
                  '${task.tempFilePath}.audio.journal',
                ]) {
                  try {
                    final f = File(p);
                    if (await f.exists()) await f.delete();
                  } catch (_) {}
                }
                task = task.copyWith(audioProgress: 0.0, audioSize: 0);
              }

              if (audioChanged && task.tempFilePath.isNotEmpty) {
                final videoFile = File(task.tempFilePath);
                if (await videoFile.exists()) {
                  final videoLen = await actualDownloadedBytes(
                    task.tempFilePath,
                    threadCount: task.threadCount,
                  );
                  if (videoLen > 0) {
                    // Check if new audio mime is compatible with video container
                    final newAudioUri = Uri.tryParse(freshAudioUrl);
                    final newAudioMime = newAudioUri?.queryParameters['mime'];
                    if (newAudioMime != null &&
                        !newAudioMime.startsWith('audio/mp4') &&
                        !newAudioMime.startsWith('audio/webm') &&
                        !newAudioMime.startsWith('audio/m4a')) {
                      debugPrint('[DMX] R-4: Audio codec may be incompatible, '
                          'will rely on FFmpeg fallback');
                    }
                  }
                }
              }
            }

            final updatedTask = task.copyWith(
              url: urlChanged ? freshUrl : task.url,
              mergedAudioUrl: freshAudioUrl ?? task.mergedAudioUrl,
              downloadedBytes: identityChanged ? 0 : task.downloadedBytes,
              chunks: identityChanged
                  ? List<double>.filled(task.threadCount, 0.0)
                  : task.chunks,
              audioProgress: identityChanged ? 0.0 : task.audioProgress,
            );
            final idx = _tasks.indexWhere((t) => t.id == id);
            if (idx != -1) {
              _tasks[idx] = updatedTask;
              await _databaseService.saveTask(updatedTask);
            }
            task = updatedTask;
          }
        }
      } catch (e) {
        debugPrint(
            '[DMX] YT-5: Proactive refresh failed, will retry on error: $e');
      }
    }
    // ═══ END FIX YT-5 ═══

    // FIX-R-02: Separate video and audio bytes on resume
    int videoBytesOnly = task.downloadedBytes; // fallback
    // FIX(R1): For torrents, derive progress from live engine if alive, otherwise from torrentFiles
    if (task.isTorrent) {
      final torrentId = _torrentIds[task.id];
      if (torrentId != null && TorrentService.isTorrentAlive(torrentId)) {
        try {
          final liveFiles = TorrentService.getFiles(torrentId);
          if (liveFiles.isNotEmpty) {
            videoBytesOnly =
                liveFiles.fold<int>(0, (s, f) => s + f.safeDownloadedBytes);
            if (task.torrentFiles != null) {
              final liveMap = {for (final lf in liveFiles) lf.name: lf};
              final updatedFiles = task.torrentFiles!.map((f) {
                final name = f['name'] as String? ?? '';
                final match = liveMap[name];
                if (match != null) {
                  return {...f, 'downloadedBytes': match.downloadedBytes};
                }
                return f;
              }).toList();
              task = task.copyWith(torrentFiles: updatedFiles);
            }
          }
        } catch (e) {
          debugPrint('[DMX] Live torrent stats query failed on resume: $e');
        }
      }

      if (videoBytesOnly <= 0 && task.torrentFiles != null) {
        videoBytesOnly = torrentBytesFromFiles(task.torrentFiles);
      }
    } else {
      try {
        // FIX(R-1): Pass threadCount so multi-thread guard works correctly
        final vBytes = await _readDmxStateBytes(
          task.tempFilePath,
          threadCount: task.threadCount,
        );

        if (vBytes > 0) {
          videoBytesOnly = vBytes;
        }
      } catch (e) {
        debugPrint('[DMX] resumeTask .dmxstate read failed: $e');
        // FIX R-1: Fallback to journal if .dmxstate read fails
        try {
          final journalPath = '${task.tempFilePath}.journal';
          final recovered = await DownloadJournal.recover(journalPath);
          if (recovered != null && recovered.isNotEmpty) {
            final journalTotal = recovered.fold<int>(0, (s, b) => s + b);
            if (journalTotal > 0) {
              videoBytesOnly = journalTotal;
              debugPrint(
                '[DMX] resumeTask: recovered $journalTotal bytes from journal',
              );
            }
          }
        } catch (_) {}
      }
    }

    if (task.fileSize > 0) {
      videoBytesOnly = videoBytesOnly.clamp(0, task.fileSize);
    } else {
      videoBytesOnly = max(0, videoBytesOnly);
    }

    final stateChunks =
        await _readDmxStateChunks(task.tempFilePath, task.threadCount);
    final chunks = reconcileChunks(
      stateChunks: stateChunks,
      actualBytesOnDisk: videoBytesOnly,
      fileSize: task.fileSize,
      threadCount: task.threadCount,
    );

    // FIX-R-01: Validate audio progress on resume
    double validatedAudioProgress = 0.0;
    int audioBytesOnDisk = 0;
    if (task.mergedAudioUrl != null && task.mergedAudioUrl!.isNotEmpty) {
      final audioStatePath = '${task.tempFilePath}.audio';
      final audioStateFile = File('$audioStatePath.dmxstate');
      if (await audioStateFile.exists()) {
        audioBytesOnDisk = await _readDmxStateBytes(
          audioStatePath,
          threadCount: task.audioThreadCount,
        );
      } else {
        final audioFile = File(audioStatePath);
        if (await audioFile.exists()) {
          audioBytesOnDisk = await actualDownloadedBytes(
            audioStatePath,
            threadCount: task.audioThreadCount > 0 ? task.audioThreadCount : 1,
          );
        }
      }

      if (task.audioSize > 0 && audioBytesOnDisk > 0) {
        validatedAudioProgress =
            (audioBytesOnDisk / task.audioSize).clamp(0.0, 1.0);
      } else if (audioBytesOnDisk > 0) {
        validatedAudioProgress = task.audioProgress.clamp(0.0, 1.0);
      }
    }

    // FIX-10: Clamp to fileSize so a stale per-file sum can never
    // push the progress bar past 100 %.
    final safeVideoBytes = task.fileSize > 0
        ? videoBytesOnly.clamp(0, task.fileSize)
        : videoBytesOnly;
    var validatedTask = task.copyWith(
      status: DownloadStatus.queued,
      downloadedBytes: safeVideoBytes,
      chunks: chunks,
      audioProgress: validatedAudioProgress,
      audioDownloadedBytes: audioBytesOnDisk,
      speed: 0,
      clearEta: true,
      clearError: true,
      clearStatusMessage: true,
      clearCompletedAt: true,
      clearScheduledAt: true,
      clearWasScheduledAt: true,
      pausedByUser: false,
    );
    validatedTask = await validateAudioProgress(validatedTask);

    await _setTask(validatedTask);

    _scheduleManager.reschedule();

    _downloadEngine.updateSpeedLimit(
      _effectiveSpeedLimit(),
      activeOrSeedingCount,
    );

    pumpQueue();
    _updateTelemetryWidget(force: true);
  }

  Future<void> pauseAllTasks() => mixinPauseAllTasks(notifyListeners);

  Future<void> resumeAllTasks() => mixinResumeAllTasks(notifyListeners);

  Future<void> toggleStartStopAll() => mixinToggleStartStopAll(notifyListeners);

  Future<void> cancelTask(String id) async {
    final task = _findTask(id);
    if (task == null) return;

    // Flush any pending throttled progress and drop tracking state.
    await _flushPendingProgress(id);

    _retryCounts.remove(id);
    _speedHistories.remove(id);
    _lastProgressUpdateTimes.remove(id);
    _lastDbSaveTimes.remove(id);
    _lastDbSaveBytes.remove(id);
    _pendingProgressUpdates.remove(id);

    // FIX-R-04: Clear effectiveThreadOverrides entry on resume
    effectiveThreadOverrides.remove(id);

    _retryTimers[id]?.cancel();
    _retryTimers.remove(id);

    _ytLowSpeedCounts.remove(id);
    _ytThrottlingRefreshing.remove(id);
    _lastTorrentFileDiskSync.remove(id);

    // Cancel the token - removing it allows future resumes.
    _cancelTokens[id]?.cancel('cancelled');
    _cancelTokens.remove(id);

    // Cancel any lingering progress notification (M2).
    _notifications.cancelForTask(id);

    final torrentId = _torrentIds[id];
    if (torrentId != null) {
      TorrentService.removeTorrent(torrentId, deleteFiles: false);
      _torrentIds.remove(id);
    }

    // Remove temporary state files safely while preserving downloaded parts
    // so user can retry/resume later.
    await cleanupPartFiles(task, preserveParts: true);

    await _setTask(
      task.copyWith(
        status: DownloadStatus.failed,
        speed: 0,
        clearEta: true,
        errorMessage: 'Transfer cancelled.',
        pausedByUser: true,
      ),
    );

    pumpQueue();

    if (activeOrSeedingCount == 0) {
      _stopWidgetTimer();
    }

    _updateTelemetryWidget(force: true);
  }

  Future<void> retryTask(String id) async {
    final rawTask = _findTask(id);
    if (rawTask == null || rawTask.status == DownloadStatus.completed) return;
    // H4: Only tasks that are not actively downloading are admissible. A
    // downloading task already runs an engine future; retrying it would race
    // the live isolate job with a duplicate _startTaskBody. A queued task has
    // no running future yet, so retry may proceed (it re-validates progress
    // from .dmxstate and re-queues).
    if (rawTask.status == DownloadStatus.downloading) {
      return;
    }
    var task = rawTask;

    // FIX YT-4: Check for merge-only retry before re-downloading
    final isMergeFailure = task.statusMessage == 'MERGE_FAILED' ||
        (task.errorMessage != null &&
            task.errorMessage!.contains('FFmpeg merge failed'));
    // FIX-MERGE-RETRY: Also look for the "_video_only" leg produced by a
    // previous failed merge, and require the audio sidecar to be non-empty
    // before attempting a merge-only retry.
    final ext = p.extension(task.localFilePath).isNotEmpty
        ? p.extension(task.localFilePath)
        : '.mp4';
    final videoOnlyPath =
        '${p.withoutExtension(task.localFilePath)}_video_only$ext';
    final videoExists = await File(task.tempFilePath).exists() ||
        await File(task.localFilePath).exists() ||
        await File(videoOnlyPath).exists();

    final audioFile = File('${task.tempFilePath}.audio');
    final audioExists =
        await audioFile.exists() && await audioFile.length() > 0;

    final shouldMergeRetry = isMergeFailure ||
        (videoExists &&
            audioExists &&
            task.mergedAudioUrl != null &&
            task.mergedAudioUrl!.isNotEmpty);
    if (shouldMergeRetry) {
      if (videoExists && audioExists) {
        debugPrint('[DMX] FIX YT-4: Retrying merge only for task ${task.id}');
        await _setTask(
            task.copyWith(isMergeInProgress: false)); // FIX-05: unstick flag
        await _orchestrator.retryMergeOnly(task);
        return;
      } else {
        debugPrint(
            '[DMX] Merge-only retry missing temp leg file. Restarting both streams.');
        task = task.copyWith(
          statusMessage: 'Restarting both streams...',
        );
      }
    }

    // FIX(D1): If the failure was "file changed on server", the saved
    // progress is invalid. Delete state files so retry starts fresh.
    final classification = ErrorTaxonomy.classify(
      task.errorMessage ?? '',
      message: task.errorMessage,
    );
    final family = classification.family;
    final status = classification.httpStatus;
    final errMsg = task.errorMessage?.toLowerCase() ?? '';

    final isUnrecoverable = errMsg.contains('file changed') ||
        errMsg.contains('filechangedonserver') ||
        errMsg.contains('403') ||
        errMsg.contains('410') ||
        errMsg.contains('forbidden') ||
        errMsg.contains('checksum') ||
        errMsg.contains('sha-256') ||
        errMsg.contains('too small') ||
        errMsg.contains('incomplete') ||
        errMsg.contains('not found') ||
        errMsg.contains('missing');

    // Resource identity changed or non-resumeable auth/gone error force a clean state wipe:
    final shouldClearState = family == ErrorFamily.integrity ||
        family == ErrorFamily.auth ||
        status == 410 ||
        status == 404 ||
        errMsg.contains('file changed') ||
        errMsg.contains('filechangedonserver') ||
        errMsg.contains('server rejected resume') ||
        errMsg.contains('gone') ||
        errMsg.contains('expired') ||
        errMsg.contains('sign in to confirm');

    final shouldResetAllProgressMetadata = shouldClearState || isUnrecoverable;

    if (shouldResetAllProgressMetadata) {
      debugPrint(
        '[DMX] S1 FIX: Unrecoverable/expired error detected. '
        'Clearing state for fresh retry.',
      );
      for (final path in [
        task.tempFilePath,
        '${task.tempFilePath}.dmxstate',
        '${task.tempFilePath}.journal',
        '${task.tempFilePath}.audio',
        '${task.tempFilePath}.audio.dmxstate',
        '${task.tempFilePath}.audio.journal',
      ]) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      // Reset progress to zero locally
      task = task.copyWith(
        downloadedBytes: 0,
        chunks: List<double>.filled(
            task.threadCount > 0 ? task.threadCount : 1, 0.0),
        audioProgress: 0.0,
        audioDownloadedBytes: 0,
      );
    }

    // FIX-AUDIT-1: clear journal files on retry if task failed, preserving temp data and state files
    if (task.status == DownloadStatus.failed) {
      task = task.copyWith(
        clearEta: true,
        clearError: true,
        clearStatusMessage: true,
      );

      // FIX-AUDIT-B3: Reset audio progress on retry for YouTube tasks if audio file missing
      if (task.hasMergedAudio) {
        final audioFile = File('${task.tempFilePath}.audio');
        if (!await audioFile.exists()) {
          task = task.copyWith(audioProgress: 0.0, audioDownloadedBytes: 0);
        }
      }

      for (final path in [
        '${task.tempFilePath}.journal',
        '${task.tempFilePath}.audio.journal',
      ]) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }

      // FIX-YT-05 / FIX-6: Only clean audio sidecars when the audio file is
      // corrupt or absent. Deleting unconditionally discards valid partial
      // audio progress on every retry.
      final audioFile = File('${task.tempFilePath}.audio');
      final audioState = File('${task.tempFilePath}.audio.dmxstate');
      if (await audioFile.exists()) {
        var audioValid = true;
        try {
          if (await audioState.exists()) {
            jsonDecode(await audioState.readAsString()); // throws if corrupt
          }
        } catch (_) {
          audioValid = false;
        }
        if (audioValid) {
          debugPrint('[DMX] Keeping valid audio sidecars for retry');
        } else {
          for (final p in [
            audioFile.path,
            audioState.path,
            '${task.tempFilePath}.audio.journal',
          ]) {
            try {
              final f = File(p);
              if (await f.exists()) await f.delete();
            } catch (_) {}
          }
        }
      } else {
        for (final p in [
          audioState.path,
          '${task.tempFilePath}.audio.journal',
        ]) {
          try {
            final f = File(p);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }

      if (task.isTorrent) {
        // FIX-TORR-RETRY: also remove the stale native handle from _torrentIds
        // so the next resume does not attempt to reuse a dead torrent handle.
        final staleTorrentId = _torrentIds.remove(task.id);
        if (staleTorrentId != null) {
          try {
            TorrentService.pauseTorrent(staleTorrentId);
            TorrentService.removeTorrent(staleTorrentId, deleteFiles: false);
          } catch (_) {}
        }
        unawaited(TorrentResumeStore.deleteResumeDataForSource(task.url));
      }
    }

    // FIX(H-4): Check disk space before retrying
    try {
      final hasSpace = await _downloadEngine.hasEnoughDiskSpace(
          task.savePath, task.fileSize);
      if (!hasSpace) {
        await _setTask(task.copyWith(
          status: DownloadStatus.failed,
          errorMessage: 'Insufficient disk space to retry download.',
        ));
        notifyListeners();
        return;
      }
    } catch (e) {
      debugPrint(
          '[DMX] H-4: Disk space check failed, proceeding with retry: $e');
    }

    // FIX-R-04: Clear effectiveThreadOverrides entry on resume
    effectiveThreadOverrides.remove(id);

    _retryTimers[id]?.cancel();
    _retryTimers.remove(id);
    _retryCounts.remove(id);
    _resumeRejectionRestarts.remove(id);
    _orchestrator.clearSessionCachedTotalSize(id);

    // ═══ FIX RT-2: Refresh YouTube URL on retry ═══
    if (task.youtubeQualityPreset != null &&
        task.downloadPageUrl != null &&
        task.downloadPageUrl!.isNotEmpty &&
        _isYoutubeUrlExpired(task.url)) {
      try {
        final fresh = await YoutubeService.getFreshStreams(
          task.downloadPageUrl!,
          preferredType: task.youtubePreferredType,
        );
        if (fresh != null && fresh['url'] != null) {
          final freshUrl = fresh['url']!;
          final freshAudioUrl = fresh['audioUrl'];
          final urlChanged = freshUrl != task.url;
          final audioChanged =
              freshAudioUrl != null && freshAudioUrl != task.mergedAudioUrl;

          final identityChanged =
              youtubeStreamIdentityChanged(task.url, freshUrl);
          if (identityChanged) {
            debugPrint(
                '[DMX] RT-2 FIX: Stream identity changed on refresh, resetting progress and deleting video temp file');
            for (final p in [
              task.tempFilePath,
              '${task.tempFilePath}.dmxstate',
              '${task.tempFilePath}.journal',
            ]) {
              try {
                final f = File(p);
                if (await f.exists()) await f.delete();
              } catch (_) {}
            }
          } else if (urlChanged) {
            final stateFile = File('${task.tempFilePath}.dmxstate');
            if (await stateFile.exists()) {
              try {
                await stateFile.delete();
              } catch (_) {}
            }
          }

          if (audioChanged) {
            for (final p in [
              '${task.tempFilePath}.audio',
              '${task.tempFilePath}.audio.dmxstate',
              '${task.tempFilePath}.audio.journal',
              '${task.tempFilePath}.audio.itag',
            ]) {
              try {
                final f = File(p);
                if (await f.exists()) await f.delete();
              } catch (_) {}
            }
          }

          task = task.copyWith(
            url: urlChanged ? freshUrl : task.url,
            mergedAudioUrl: freshAudioUrl ?? task.mergedAudioUrl,
            downloadedBytes: identityChanged ? 0 : task.downloadedBytes,
            chunks: identityChanged
                ? List<double>.filled(
                    task.threadCount > 0 ? task.threadCount : 1, 0.0)
                : task.chunks,
            audioProgress: audioChanged ? 0.0 : task.audioProgress,
          );
        }
      } catch (e) {
        debugPrint('[DMX] RT-2: YouTube refresh on retry failed: $e');
      }
    }
    // ═══ END FIX RT-2 ═══

    // ═══ FIX H-7: Validate state before retry ═══
    final stateFile = File('${task.tempFilePath}.dmxstate');
    if (await stateFile.exists()) {
      try {
        final content = await stateFile.readAsString();
        jsonDecode(content);
      } catch (e) {
        debugPrint('[DMX] H-7 FIX: Corrupted state file detected, deleting');
        try {
          await stateFile.delete();
        } catch (_) {}
        final idx = _tasks.indexWhere((t) => t.id == id);
        if (idx != -1) {
          _tasks[idx] = _tasks[idx].copyWith(
            downloadedBytes: 0,
            chunks: List<double>.filled(
                task.threadCount > 0 ? task.threadCount : 1, 0.0),
          );
          await _databaseService.saveTask(_tasks[idx]);
        }
      }
    }
    // ═══ END FIX H-7 ═══

    // ── Read ACTUAL progress from .dmxstate, never from pre-allocated file length ──
    final videoBytes = await _readDmxStateBytes(
      task.tempFilePath,
      threadCount: task.threadCount,
    );
    var audioBytes = 0;
    if (task.mergedAudioUrl != null && task.mergedAudioUrl!.isNotEmpty) {
      // FIX-13: Use task.audioThreadCount > 0 ? task.audioThreadCount : 1
      audioBytes = await _readDmxStateBytes(
        '${task.tempFilePath}.audio',
        threadCount: task.audioThreadCount > 0 ? task.audioThreadCount : 1,
      );
    }

    var realBytesOnDisk = videoBytes + audioBytes;

    // FIX-T2: Recalculate aggregate downloadedBytes from per-file data for torrents
    try {
      if (task.isTorrent) {
        final totalFromFiles = torrentBytesFromFiles(task.torrentFiles);
        if (totalFromFiles > 0) {
          realBytesOnDisk = totalFromFiles;
          debugPrint(
              '[FIX-T2] Torrent retry: using per-file total=$totalFromFiles');
        }
      }
    } catch (e) {
      debugPrint('[FIX-T2] Torrent retry per-file calculation failed: $e');
    }

    // FIX RT-3: Use video-only size for chunk reconciliation
    final videoOnlySize = task.hasMergedAudio && task.audioSize > 0
        ? max(task.fileSize - task.audioSize, 0)
        : task.fileSize;

    final stateChunks =
        await _readDmxStateChunks(task.tempFilePath, task.threadCount);
    final chunks = reconcileChunks(
      stateChunks: stateChunks,
      actualBytesOnDisk: videoBytes, // video bytes only
      fileSize: videoOnlySize, // video size only
      threadCount: task.threadCount,
    );

    await _setTask(
      task.copyWith(
        status: DownloadStatus.queued,
        downloadedBytes: realBytesOnDisk,
        chunks: chunks,
        audioProgress: task.audioSize > 0 && audioBytes > 0
            ? (audioBytes / task.audioSize).clamp(0.0, 1.0)
            : 0.0,
        speed: 0,
        clearEta: true,
        clearError: true,
        clearStatusMessage: true,
        clearCompletedAt: true,
        clearFailureCategory: true, // FIX RT-1
        pausedByUser: false,
        videoStreamSize: shouldResetAllProgressMetadata
            ? 0
            : task.videoStreamSize, // FIX RT-4
        audioDownloadedBytes: shouldResetAllProgressMetadata
            ? 0
            : task.audioDownloadedBytes, // FIX RT-4
      ),
    );

    _downloadEngine.updateSpeedLimit(
      _effectiveSpeedLimit(),
      activeOrSeedingCount,
    );

    pumpQueue();
    _updateTelemetryWidget(force: true);
    notifyListeners();
  }

  /// ── FIX-4 / FIX-1 / FIX-11: Robust .dmxstate reading with journal fallback ──
  /// ── FIX-4 / FIX-1 / FIX-11: Robust .dmxstate reading via StateStore ──
  static Future<int> _readDmxStateBytes(
    String tempFilePath, {
    int threadCount = 1,
  }) async {
    return actualDownloadedBytes(tempFilePath, threadCount: threadCount);
  }

  /// Reads per-chunk progress percentages via StateStore.
  static Future<List<double>?> _readDmxStateChunks(
    String tempFilePath,
    int expectedThreadCount,
  ) async {
    try {
      final result = await StateStore.loadOrCreate(
        tempFilePath,
        url: '',
        threadCount: expectedThreadCount,
        knownFileSize: 0,
      );
      var ratios = result.state.chunkRatios;
      // FIX-AUDIT-F1: Ensure chunk count matches expected
      if (ratios.length < expectedThreadCount) {
        ratios = [
          ...ratios,
          ...List.filled(expectedThreadCount - ratios.length, 0.0)
        ];
      } else if (ratios.length > expectedThreadCount) {
        ratios = ratios.sublist(0, expectedThreadCount);
      }
      return ratios;
    } catch (e) {
      debugPrint('[DMX] _readDmxStateChunks failed: $e');
      return List.filled(
          expectedThreadCount, 0.0); // Return zeros instead of null
    }
  }

  Future<void> deleteTask(String id, {bool deleteFiles = false}) async {
    final task = _findTask(id);
    if (task == null) return;

    // FIX-X-05: Cancel notification immediately on delete
    final notifId = _notifications.idFor(id);
    _notifications.cancelNotification(notifId);
    _notifications.cancelForTask(id);

    // 1. Cancel the token IMMEDIATELY
    final token = _cancelTokens[id];

    if (token != null && !token.isCancelled) {
      try {
        token.cancel('deleted');
      } catch (e) {
        // Ignore
      }
    }

    // 2. For torrents, pause + remove from session IMMEDIATELY
    if (task.isTorrent) {
      final torrentId = _torrentIds[id];
      if (torrentId != null && TorrentService.isTorrentAlive(torrentId)) {
        // FIX-B10: Guard with alive check
        try {
          TorrentService.pauseTorrent(torrentId);
          TorrentService.removeTorrent(torrentId, deleteFiles: false);
        } catch (e) {
          _log.warning('[deleteTask] Torrent cleanup failed: $e');
        }
        _torrentIds.remove(id);
        providerTorrentIds.remove(id);
      } else {
        _torrentIds.remove(id);
        providerTorrentIds.remove(id);
      }
    }

    // 3. Remove from UI IMMEDIATELY (optimistic update)
    _tasks.removeWhere((t) => t.id == id);
    filteredTasksDirty = true;
    _cancelTokens.remove(id);
    _speedHistories.remove(id);
    _lastProgressUpdateTimes.remove(id);
    _lastDbSaveTimes.remove(id);
    _lastDbSaveBytes.remove(id);
    _pendingProgressUpdates.remove(id);
    effectiveThreadOverrides.remove(id);
    _retryCounts.remove(id);
    _resumeRejectionRestarts.remove(id);
    _ytLowSpeedCounts.remove(id);

    _ytThrottlingRefreshing.remove(id);

    // FIX-R-04: Clear effectiveThreadOverrides entry on resume
    effectiveThreadOverrides.remove(id);

    _retryTimers[id]?.cancel();
    _retryTimers.remove(id);

    _lastTorrentFileDiskSync.remove(id);
    _downloadMetrics.remove(id);
    _dbRetryCounts.remove(id);
    _dbRetryTimers[id]?.cancel();
    _dbRetryTimers.remove(id);
    _orchestrator.cleanupTaskState(
        id); // FIX-12 & FIX-17: Clean up orchestrator state maps

    notifyListeners();

    // 4. Remove notification IMMEDIATELY
    _notifications
        .cancelForTask(id); // FIX-18: Ensure notification is cancelled early
    final savedNotificationId = _notifications.removeId(id);
    if (savedNotificationId != null) {
      _notifications.cancelNotification(savedNotificationId);
    }

    // 5. Delete from DB (with retries in background)
    unawaited(() async {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await _databaseService.deleteTask(id);
          return;
        } catch (e) {
          debugPrint('[DMX] deleteTask DB attempt ${attempt + 1} failed: $e');
          if (attempt < 2) {
            await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
          }
        }
      }
      debugPrint('[DMX] deleteTask DB delete permanently failed for $id');
    }());

    // 6. Heavy cleanup in BACKGROUND
    unawaited(_backgroundDeleteCleanup(task, deleteFiles));

    updateActualTorrentUploadLimit();
    pumpQueue();

    if (activeOrSeedingCount == 0) {
      BackgroundService.stop();
      _stopWidgetTimer();
    }

    _updateTelemetryWidget(force: true);
  }

  /// Runs file cleanup without blocking the UI thread.
  Future<void> _backgroundDeleteCleanup(
      DownloadTask task, bool deleteFiles) async {
    try {
      // Wait for the active future with a HARD 5-second timeout
      final future = _activeFutures[task.id];
      if (future != null) {
        await Future.any([
          future.catchError((_) {}),
          Future.delayed(const Duration(seconds: 5)),
        ]);
      }
      _activeFutures.remove(task.id);

      // Clean up temp/state/journal files ALWAYS
      await cleanupPartFiles(task, preserveParts: false);

      // Delete the actual file only if user requested
      if (deleteFiles) {
        await _deleteTaskOutputFiles(task);
      }
    } catch (e) {
      _log.warning('[deleteTask] Background cleanup failed for ${task.id}: $e');
    }
  }

  /// Deletes the final output file(s). Large files are deleted in a background isolate.
  Future<void> _deleteTaskOutputFiles(DownloadTask task) async {
    try {
      final localFile = File(task.localFilePath);
      if (await localFile.exists()) {
        final size = await localFile.length();
        if (size > 512 * 1024 * 1024) {
          // > 512 MB: use isolate
          await Isolate.run(() => File(task.localFilePath).delete());
        } else {
          await localFile.delete();
        }
      }
    } catch (e) {
      _log.warning('[deleteTask] Completed file deletion failed: $e');
    }

    if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
      final root = p.normalize(task.savePath);

      for (final f in task.torrentFiles!) {
        final relPath = f['name'] as String?;

        if (relPath != null && relPath.isNotEmpty) {
          try {
            final fullPath = p.normalize(p.join(root, relPath));

            // Prevent path traversal and prevent deleting the root folder itself.
            if (fullPath == root || !p.isWithin(root, fullPath)) {
              debugPrint(
                '[DMX] Blocked unsafe torrent file path: $relPath',
              );
              continue;
            }

            final file = File(fullPath);
            if (await file.exists()) {
              await file.delete();
            }
          } catch (e) {
            debugPrint(
              'Failed to delete torrent file segment $relPath: $e',
            );
          }
        }
      }
    }
  }

  Future<void> clearHistoryTasks(List<String> ids) async {
    for (final id in ids) {
      _cancelTokens.remove(id);
      _speedHistories.remove(id);
      _lastProgressUpdateTimes.remove(id);
      _lastDbSaveTimes.remove(id);
      _lastDbSaveBytes.remove(id);
      _pendingProgressUpdates.remove(id);
      _retryCounts.remove(id);
      _resumeRejectionRestarts.remove(id);
      _ytLowSpeedCounts.remove(id);

      _ytThrottlingRefreshing.remove(id);
      _lastTorrentFileDiskSync.remove(id);
      _downloadMetrics.remove(id);
      _dbRetryCounts.remove(id);
      effectiveThreadOverrides.remove(id);

      // FIX-R-04: Clear effectiveThreadOverrides entry on resume
      effectiveThreadOverrides.remove(id);

      _retryTimers[id]?.cancel();
      _retryTimers.remove(id);
      _dbRetryTimers[id]?.cancel();
      _dbRetryTimers.remove(id);

      _activeFutures.remove(id);

      final notifId = _notifications.idFor(id);
      _notifications.cancelNotification(notifId);
      final savedNotificationId = _notifications.removeId(id);

      _tasks.removeWhere((task) => task.id == id);

      final torrentId = _torrentIds[id];
      if (torrentId != null) {
        TorrentService.removeTorrent(torrentId, deleteFiles: false);
        _torrentIds.remove(id);
      }

      if (savedNotificationId != null) {
        _notifications.cancelNotification(savedNotificationId);
      }
    }

    filteredTasksDirty = true;

    await _databaseService.deleteTasks(ids);

    updateActualTorrentUploadLimit();

    notifyListeners();
  }

  /// Deletes residual temporary download files on disk for [task].
  ///
  /// Cleans temporary HTTP transfer sidecars and temporary `.dmxpart` files.
  Future<void> cleanupHttpArtifacts(DownloadTask task,
      {bool preserveParts = false}) async {
    await _orchestrator.cleanupHttpArtifacts(task,
        preserveParts: preserveParts);
  }

  /// Cleans temporary Torrent transfer sidecars without deleting user payload files.
  Future<void> cleanupTorrentArtifacts(DownloadTask task) async {
    await _orchestrator.cleanupTorrentArtifacts(task);
  }

  /// Cleans all temporary transfer artifacts safely depending on task type.
  Future<void> cleanupAllArtifacts(DownloadTask task,
      {bool preserveParts = false}) async {
    await _orchestrator.cleanupAllArtifacts(task, preserveParts: preserveParts);
  }

  @override
  Future<void> cleanupPartFiles(DownloadTask task,
      {bool preserveParts = false}) async {
    await _orchestrator.cleanupAllArtifacts(task, preserveParts: preserveParts);
  }

  /// Persists any throttled in-memory progress for [id] that hasn't yet
  /// been flushed to the database. No-op if there's nothing pending.
  Future<void> _flushPendingProgress(String id) async {
    if (_flushingIds.contains(id)) return;
    _flushingIds.add(id);
    try {
      _lastProgressUpdateTimes.remove(id);
      _lastDbSaveTimes.remove(id);

      if (!_pendingProgressUpdates.contains(id)) return;

      final index = _tasks.indexWhere((t) => t.id == id);
      if (index == -1) {
        _pendingProgressUpdates.remove(id);
        return;
      }

      final task = _tasks[index];

      try {
        await _databaseService.saveTask(task);
        _pendingProgressUpdates.remove(id);
      } catch (e) {
        debugPrint('[DMX] flushPendingProgress failed for $id: $e');
      }
    } finally {
      _flushingIds.remove(id);
    }
  }

  Future<void> updateTaskSpeedLimit(String taskId, int speedLimitKbps) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    _tasks[index] = _tasks[index].copyWith(speedLimitKbps: speedLimitKbps);

    await _databaseService.saveTask(_tasks[index]);
    notifyListeners();
  }

  DownloadTask? taskById(String id) {
    return _findTask(id);
  }

  // ---------------------------------------------------------------------------
  // Download engine orchestration
  // ---------------------------------------------------------------------------

  @override
  int get pendingStartCount => _orchestrator.pendingStartCount;

  /// Merges structural fields from [incoming] into [live], preserving
  /// progress fields (downloadedBytes, speed, eta, chunks, audioProgress)
  /// from the live in-memory task. This prevents state regression when a
  /// structural update (status change, URL edit, metadata save) carries
  /// stale progress values captured before the update was enqueued.
  DownloadTask _mergeTaskUpdate(DownloadTask live, DownloadTask incoming) {
    // Terminal states are never overwritten by non-terminal incoming updates.
    if (live.status == DownloadStatus.completed &&
        incoming.status != DownloadStatus.completed) {
      return live;
    }
    // FIX-H5: Protect merging status from stale downloading snapshots
    if ((live.status == DownloadStatus.paused ||
            live.status == DownloadStatus.failed ||
            live.status == DownloadStatus.merging) &&
        incoming.status == DownloadStatus.downloading) {
      return live;
    }

    // FIX F7: A reset is any incoming update that explicitly zeroes progress fields
    final isReset = incoming.downloadedBytes == 0 &&
        (incoming.status == DownloadStatus.queued ||
            incoming.status == DownloadStatus.failed ||
            (incoming.status == DownloadStatus.downloading &&
                live.downloadedBytes > 0) ||
            (incoming.audioProgress == 0.0 &&
                incoming.mergedAudioUrl != live.mergedAudioUrl));

    if (isReset) return incoming;

    // For progress ticks during active download, accept the larger value
    // to prevent regression from out-of-order ticks.
    final isProgressTick = incoming.status == DownloadStatus.downloading &&
        live.status == DownloadStatus.downloading;

    if (isProgressTick) {
      final effectiveDownloadedBytes =
          incoming.downloadedBytes > live.downloadedBytes
              ? incoming.downloadedBytes
              : live.downloadedBytes;
      final effectiveAudioProgress = incoming.audioProgress > live.audioProgress
          ? incoming.audioProgress
          : live.audioProgress;
      return incoming.copyWith(
        downloadedBytes: effectiveDownloadedBytes,
        audioProgress: effectiveAudioProgress,
      );
    }

    // All other transitions: trust incoming unconditionally.
    return incoming;
  }

  Future<void> _setTask(DownloadTask updated) async {
    // FIX-H-06: Clamp downloadedBytes to fileSize
    if (updated.fileSize > 0 && updated.downloadedBytes > updated.fileSize) {
      updated = updated.copyWith(downloadedBytes: updated.fileSize);
    }

    // FIX-X-01: Clamp audioProgress, guarding NaN
    if (updated.audioProgress.isNaN ||
        updated.audioProgress < 0.0 ||
        updated.audioProgress > 1.0) {
      updated = updated.copyWith(
        audioProgress: updated.audioProgress.isNaN
            ? 0.0
            : updated.audioProgress.clamp(0.0, 1.0),
      );
    }

    // FIX-X-02: Clamp chunks
    // FIX-09: Also sanitize NaN chunks which would otherwise survive clamp()
    if (updated.chunks.any((c) => c < 0.0 || c > 1.0 || c.isNaN)) {
      updated = updated.copyWith(
        chunks: updated.chunks
            .map((c) => c.isNaN ? 0.0 : c.clamp(0.0, 1.0))
            .toList(),
      );
    }

    final index = _tasks.indexWhere((task) => task.id == updated.id);
    if (index == -1) return;

    final prev = _tasks[index];
    final protocol = updated.isTorrent
        ? 'TORRENT'
        : (updated.hasMergedAudio || updated.mergedAudioUrl != null
            ? 'YOUTUBE'
            : 'HTTP');
    if (prev.status != updated.status ||
        prev.statusMessage != updated.statusMessage) {
      debugPrint(
          '[LIFECYCLE] [$protocol] [${updated.id}] status: ${prev.status.name} -> ${updated.status.name} (msg: "${updated.statusMessage ?? ''}")');
    }
    // Merge structural fields from `updated` into the live in-memory task,
    // preserving progress fields (downloadedBytes, speed, eta, chunks,
    // audioProgress) to prevent state regression during active downloads.
    _tasks[index] = _mergeTaskUpdate(prev, updated);

    // ═══ FIX H-6: Clamp downloadedBytes to fileSize ═══
    final currentTask = _tasks[index];
    if (currentTask.fileSize > 0 &&
        currentTask.downloadedBytes > currentTask.fileSize) {
      debugPrint('[DMX] H-6 FIX: Clamping downloadedBytes from '
          '${currentTask.downloadedBytes} to ${currentTask.fileSize}');
      _tasks[index] =
          currentTask.copyWith(downloadedBytes: currentTask.fileSize);
    }

    if (updated.status == DownloadStatus.failed) {
      final id = updated.id;
      _speedHistories.remove(id);
      _lastProgressUpdateTimes.remove(id);
      _lastDbSaveTimes.remove(id);
      _pendingProgressUpdates.remove(id);
      _ytLowSpeedCounts.remove(id);
      _ytThrottlingRefreshing.remove(id);
      _lastTorrentFileDiskSync.remove(id);

      if (_cancelTokens.containsKey(id)) {
        final token = _cancelTokens[id];
        if (token != null && !token.isCancelled) {
          try {
            token.cancel('failed');
          } catch (_) {}
        }
        _cancelTokens.remove(id);
      }
      final torrentId = _torrentIds[id];
      if (torrentId != null && !TorrentService.isTorrentAlive(torrentId)) {
        _torrentIds.remove(id);
      }
    }

    // FIX-A4: Immediate DB save when task status == DownloadStatus.failed
    // FIX-F1: Immediate DB save when status transitions queued -> downloading
    if (updated.status == DownloadStatus.failed ||
        (prev.status == DownloadStatus.queued &&
            updated.status == DownloadStatus.downloading)) {
      unawaited(_databaseService.saveTask(_tasks[index]).catchError((e) {
        debugPrint('[DMX] Immediate DB save failed on status transition: $e');
      }));
    }

    // Only invalidate the filter/sort cache when a "structural" field changes
    // (status, category, name, URL, or fileSize). Progress-only updates (speed,
    // downloadedBytes, chunks, eta) must NOT set filteredTasksDirty to true,
    // otherwise the filtered list would be recomputed on every tick, wasting CPU
    // and causing unnecessary widget rebuilds.
    final isStructuralChange = prev.status != updated.status ||
        prev.category != updated.category ||
        prev.fileName != updated.fileName ||
        prev.url != updated.url ||
        prev.fileSize != updated.fileSize ||
        prev.scheduledAt != updated.scheduledAt;

    if (isStructuralChange) {
      filteredTasksDirty = true;
    }

    if (prev.scheduledAt != updated.scheduledAt ||
        prev.status != updated.status) {
      _scheduleManager.reschedule();
    }

    updateActualTorrentUploadLimit();

    _pushTick(updated.id, updated.progress, updated.speed.toDouble());

    // Progress-only changes (speed, bytes, eta, chunks) skip the immediate
    // DB save and notifyListeners. The timer-based batch save persists
    // progress periodically, and _notifyPending coalesces UI notifications
    // to the timer frequency (~5 s) so we don't rebuild widgets on every tick.
    if (!isStructuralChange) {
      _pendingProgressUpdates.add(updated.id);
      _notifyPending = true;
      // FIX(D-1): ensure widget timer is running for progress flush
      if (_widgetTimer == null) _startWidgetTimer();

      // Complete any previous queued save so the chain stays consistent.
      final previousSave = _dbSaveQueues[updated.id];
      if (previousSave != null) {
        try {
          await previousSave;
        } catch (e, st) {
          // FIX(D-2): log previous DB save failure at severe level
          _log.severe('[download_provider] previous DB save failed', e, st);
        }
      }
      return;
    }

    // Structural change — persist immediately.
    final previousSave = _dbSaveQueues[updated.id] ?? Future.value();
    final completer = Completer<void>();

    _dbSaveQueues[updated.id] = completer.future;

    try {
      await previousSave;
    } catch (e) {
      _log.warning('Previous DB save failed for ${updated.id}', e);
    }

    try {
      await _databaseService.saveTask(updated);
      lastSaveError.value = null;

      // Notify AFTER successful DB write to keep UI and persistence in sync.
      notifyListeners();

      completer.complete();
    } catch (e) {
      // CRITICAL: Do NOT replace in-memory progress with stale DB data.
      // The in-memory [updated] task is the source of truth during active downloads.
      _log.severe('Error saving task to database for ${updated.id}', e);

      // Expose the error via a notifier so callers (e.g., UI snackbars) can react
      lastSaveError.value = 'DB save failed for ${updated.id}: $e';

      // Schedule a retry with backoff
      _scheduleDbRetry(updated.id, updated);

      completer.complete();
      notifyListeners();
    } finally {
      if (identical(_dbSaveQueues[updated.id], completer.future)) {
        _dbSaveQueues.remove(updated.id);
      }
    }
  }

  /// Schedules a retry of a failed DB save with exponential backoff.
  /// The in-memory task remains the source of truth.
  void _scheduleDbRetry(String taskId, DownloadTask task) {
    final retries = _dbRetryCounts[taskId] ?? 0;
    if (retries >= 5) {
      _log.severe(
        'DB save retry exhausted for $taskId after $retries attempts',
      );
      lastSaveError.value = 'DB save failed after $retries retries for $taskId';
      return;
    }
    _dbRetryCounts[taskId] = retries + 1;
    // Exponential backoff with jitter: min(2^retries * 1000 + random(0, 500), 30000)
    final random = Random();
    final baseDelay = (1 << retries) * 1000 + random.nextInt(500);
    final delayMs = baseDelay.clamp(0, 30000);
    final delay = Duration(milliseconds: delayMs);
    _log.warning(
      'Scheduling DB save retry #${retries + 1} for $taskId in ${delay.inMilliseconds}ms',
    );

    _dbRetryTimers[taskId]?.cancel();
    _dbRetryTimers[taskId] = Timer(delay, () {
      _dbRetryTimers.remove(taskId);
      final idx = _tasks.indexWhere((t) => t.id == taskId);
      if (idx == -1) return;
      // Re-read from _tasks so the retry always uses the latest in-memory state.
      // "Latest state wins" semantics: if the task was updated again after the
      // original failure, the newer values are persisted instead of stale ones.
      _setTask(_tasks[idx]);
    });
  }

  DownloadTask? _findTask(String id) {
    final index = _tasks.indexWhere((task) => task.id == id);
    if (index == -1) return null;
    return _tasks[index];
  }

  /// Build per-thread chunk progress fallback returning unified overall progress.
  List<double> _buildChunks(
    int threadCount,
    int fileSize,
    int downloadedBytes,
  ) {
    final effectiveThreadCount = threadCount > 0 ? threadCount : 1;
    if (fileSize <= 0) {
      return List<double>.filled(effectiveThreadCount, 0.0);
    }

    final overallProgress = (downloadedBytes / fileSize).clamp(0.0, 1.0);
    // FIX-M6: Fill evenly across chunks instead of sequential fill
    return List<double>.filled(effectiveThreadCount, overallProgress);
  }

  // ---------------------------------------------------------------------------
  // Connectivity & scheduling
  // ---------------------------------------------------------------------------

  int? _lastCleanupDays;

  void _onSettingsChanged() {
    _networkMonitor.checkNetworkConnectivity();

    _downloadEngine.updateSpeedLimit(
      _effectiveSpeedLimit(),
      downloadingTasksCount,
    );

    updateActualTorrentUploadLimit();

    TorrentService.configureSession(_settingsProvider);
    checkTorrentRatioLimits();
    enforceTorrentQueue();

    if (_lastCleanupDays == null) {
      _lastCleanupDays = _settingsProvider.cleanupDays;
    } else if (_lastCleanupDays != _settingsProvider.cleanupDays) {
      _lastCleanupDays = _settingsProvider.cleanupDays;
      load(pauseOrphanDownloads: false);
    }

    // When battery saver is toggled ON, pause excess active downloads so the
    // queue pump restarts only `maxDownloads` tasks with reduced thread counts.
    if (_settingsProvider.batterySaverMode) {
      final maxSlots = _settingsProvider.maxDownloads;

      final active = providerTasks
          .where((t) => t.status == DownloadStatus.downloading)
          .toList();

      if (active.length > maxSlots) {
        for (var i = maxSlots; i < active.length; i++) {
          pauseTask(active[i].id);
        }
      }
    }

    pumpQueue();
  }

  Future<void> startUpdateDownload(UpdateInfo update) async {
    final updatesDir = await UpdateService().getUpdatesDirectory();

    final fileName = 'XDM_${update.latestVersion}_v${update.versionCode}.apk';

    final existing = _tasks.firstWhere(
      (t) => t.isAppUpdate && t.fileName == fileName,
      orElse: () => DownloadTask(
        id: '',
        fileName: '',
        url: '',
        fileSize: 0,
        downloadedBytes: 0,
        category: 'APK',
        status: DownloadStatus.failed,
        savePath: '',
        localFilePath: '',
        tempFilePath: '',
        threadCount: 1,
        chunks: const [0.0],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );

    if (existing.id.isNotEmpty && existing.status == DownloadStatus.completed) {
      final file = File(existing.localFilePath);

      final isIntact = await UpdateService().verifyApkIntegrity(
        file,
        expectedSha256: update.sha256,
      );

      if (isIntact) {
        return;
      }
    }

    await addDownload(
      name: fileName,
      url: update.apkUrl,
      size: 0,
      category: 'APK',
      savePath: updatesDir.path,
      isAppUpdate: true,
    );
  }

  // ---------------------------------------------------------------------------
  // Widget / telemetry timer
  // ---------------------------------------------------------------------------

  void _updateTelemetryWidget({bool force = false}) {
    if (kIsWeb) return;
    _startWidgetTimer();
    unawaited(_pushWidgetData(force: force));
  }

  /// Builds the widget dashboard from the current task list and pushes it to
  /// the native launcher widgets (Android + iOS) via [WidgetDataBridge].
  ///
  /// Throttling is handled inside the bridge (max one push / 5 s). This is
  /// invoked from the 5-second telemetry timer while downloads are active and
  /// immediately after every state transition (add, pause, resume, complete,
  /// fail, delete).
  Future<void> _pushWidgetData({bool force = false}) async {
    try {
      // FIX-X-03: Snapshot tasks to avoid mid-mutation reads
      final tasksSnapshot = List<DownloadTask>.from(_tasks);
      final bridge = WidgetDataBridge.instance;
      final freeSpace = await bridge.fetchFreeDiskSpace();

      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day);
      final summaries = <WidgetTaskSummary>[];

      for (final task in tasksSnapshot) {
        var status = task.status.name;
        if (status == 'completed' && task.isTorrent && task.seedingEnabled) {
          status = 'seeding';
        }
        final history = _speedHistories[task.id]?.toList() ?? const <double>[];
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

      final dashboard = WidgetDashboard.fromTasks(
        summaries,
        availableStorageBytes: freeSpace,
        isOnWifi: _networkMonitor.hasWifiOrEthernet,
        // The summary model doesn't carry completion timestamps, so the
        // completed-today count is computed here from the raw tasks.
        completedTodayCount: _tasks.where((t) {
          final completedAt = t.completedAt;
          return t.status == DownloadStatus.completed &&
              completedAt != null &&
              !completedAt.isBefore(todayStart);
        }).length,
      );

      await bridge.pushDashboard(dashboard, force: force);
    } catch (e) {
      _log.fine('[download_provider] widget dashboard push failed: $e');
    }
  }

  void _startWidgetTimer() {
    _widgetTimer?.cancel();

    if (downloadingTasksCount > 0 || seedingTasksCount > 0) {
      _widgetTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
        if (_disposed) {
          timer.cancel();
          return;
        }

        _updateTelemetryWidget();

        unawaited(BackgroundService.sendHeartbeat().catchError((e, st) {
          _log.warning('[download_provider] operation failed', e, st);
        }));

        final tasksToSave = <DownloadTask>[];

        for (var i = 0; i < _tasks.length; i++) {
          final t = _tasks[i];

          if (t.status == DownloadStatus.downloading) {
            final lastBytes = _lastDbSaveBytes[t.id] ?? -1;

            if (t.downloadedBytes != lastBytes) {
              _lastDbSaveBytes[t.id] = t.downloadedBytes;
              tasksToSave.add(t);
            }
          }

          // Do NOT save queued tasks here — they have no meaningful progress
        }

        // Also persist any tasks that went through _setTask with progress-only
        // changes (which deferred the DB write to this batch save).
        for (final id in _pendingProgressUpdates) {
          final idx = _tasks.indexWhere((t) => t.id == id);
          if (idx != -1 && !tasksToSave.contains(_tasks[idx])) {
            tasksToSave.add(_tasks[idx]);
            // Keep _lastDbSaveBytes in sync so the byte-change loop on the
            // next tick doesn't re-detect the same delta and save redundantly.
            _lastDbSaveBytes[id] = _tasks[idx].downloadedBytes;
          }
        }
        _pendingProgressUpdates.clear();

        if (tasksToSave.isNotEmpty) {
          _databaseService.saveTasks(tasksToSave).catchError((e) {
            debugPrint('Batch DB save failed: $e');
          });
        }

        // Coalesce notifyListeners() calls from _setTask progress-only updates
        // so widgets rebuild at most once per timer tick instead of on every tick.
        final shouldNotify = _notifyPending || updateSeedingSpeeds();
        _notifyPending = false;
        if (shouldNotify) {
          notifyListeners();
        }
      });
    }
  }

  void _stopWidgetTimer() {
    _widgetTimer?.cancel();
    _widgetTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Task mutation helpers
  // ---------------------------------------------------------------------------

  Future<void> updateTaskThreadCount(String taskId, int threadCount) async {
    final taskIndex = _tasks.indexWhere((t) => t.id == taskId);
    if (taskIndex == -1) return;

    var task = _tasks[taskIndex];

    final targetThreadCount = threadCount.clamp(1, 32);
    if (task.threadCount == targetThreadCount) return;

    var activeIdx = taskIndex;
    final wasDownloading = task.status == DownloadStatus.downloading;

    if (wasDownloading) {
      await pauseTask(taskId);

      activeIdx = _tasks.indexWhere((t) => t.id == taskId);
      if (activeIdx == -1) return;

      task = _tasks[activeIdx];
    }

    if (task.downloadedBytes > 0) {
      try {
        await cleanupPartFiles(task);
      } catch (e) {
        debugPrint('Error deleting segment files on thread count change: $e');
      }

      task = task.copyWith(
        threadCount: targetThreadCount,
        downloadedBytes: 0,
        chunks: List<double>.filled(targetThreadCount, 0.0),
        status: DownloadStatus.paused,
        clearError: true,
      );
    } else {
      task = task.copyWith(
        threadCount: targetThreadCount,
        chunks: List<double>.filled(targetThreadCount, 0.0),
      );
    }

    // FIX-9: Normalize the chunk sum after the thread-count redistribution so
    // bar segments stay aligned with downloadedBytes/fileSize.
    task = task.copyWith(
      chunks: DownloadOrchestrator.normalizeChunks(
        task.chunks,
        task.fileSize,
        task.downloadedBytes,
      ),
    );

    _tasks[activeIdx] = task;

    await _databaseService.saveTask(task);

    notifyListeners();
    _updateTelemetryWidget(force: true);
  }

  Future<void> updateTaskUrl(
    String taskId,
    String newUrl, {
    String? newAudioUrl,
    int? newFileSize,
    int? newAudioSize,
    bool isRefresh = false,
    bool clearAudioUrl = false,
    bool isSameResource = false,
  }) async {
    // FIX-X-04: Validate URL before applying
    if (!isValidTransmissionUrl(newUrl.trim())) {
      throw Exception('Invalid URL: $newUrl');
    }

    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    var task = _tasks[index];
    if (task.isTorrent &&
        !newUrl.startsWith('magnet:') &&
        !newUrl.endsWith('.torrent')) {
      throw Exception('Cannot set a non-torrent URL on a torrent task.');
    }
    bool preserve = false;

    final cleanUrl = newUrl.trim();
    if (task.url == cleanUrl) return;

    if (!isValidTransmissionUrl(cleanUrl)) {
      throw Exception('Invalid URL/Magnet');
    }

    final wasDownloading = task.status == DownloadStatus.downloading;

    if (wasDownloading) {
      await pauseTask(taskId);

      final activeFuture = _activeFutures[taskId];
      if (activeFuture != null) {
        try {
          await activeFuture;
        } catch (e) {
          debugPrint('[DMX] activeFuture error in updateTaskUrl: $e');
        }
      }

      final updatedIdx = _tasks.indexWhere((t) => t.id == taskId);
      if (updatedIdx != -1) {
        task = _tasks[updatedIdx];
      }
    }

    try {
      bool sameTorrent(String a, String b) {
        if (a == b) return true; // FIX-10: File path / URL exact comparison
        final ha = parseMagnetUrl(a)['infoHash']?.toString().toLowerCase();
        final hb = parseMagnetUrl(b)['infoHash']?.toString().toLowerCase();
        if (ha != null && hb != null && ha != hb) {
          debugPrint('[DMX] M-5: Torrent hash changed from $ha to $hb');
        }
        if (ha != null && hb != null) return ha == hb;
        // FIX-07: For .torrent file URLs: compare info-hash / file identity
        if (a.endsWith('.torrent') && b.endsWith('.torrent')) {
          if (a == b) return true;
          try {
            final fa = Uri.tryParse(a)?.toFilePath() ?? a;
            final fb = Uri.tryParse(b)?.toFilePath() ?? b;
            if (fa == fb) return true;
          } catch (_) {}
        }
        return false;
      }

      final wasTorrent = task.isTorrent;
      final isNewTorrent = cleanUrl.startsWith('magnet:') ||
          cleanUrl.toLowerCase().endsWith('.torrent');

      if (wasTorrent || isNewTorrent) {
        final torrentId = _torrentIds[taskId];
        if (torrentId != null) {
          TorrentService.removeTorrent(torrentId, deleteFiles: false);
          _torrentIds.remove(taskId);
        }

        preserve =
            isSameResource || isRefresh || sameTorrent(task.url, cleanUrl);
        if (task.url != cleanUrl) {
          // FIX T-6: Invalidate old resume data
          await TorrentResumeStore.deleteResumeDataForSource(task.url);
        }
        await cleanupPartFiles(task, preserveParts: preserve);

        if (!preserve) {
          if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
            final root = p.normalize(task.savePath);
            for (final f in task.torrentFiles!) {
              final relPath = f['name'] as String?;
              if (relPath != null && relPath.isNotEmpty) {
                try {
                  final fullPath = p.normalize(p.join(root, relPath));

                  if (fullPath == root || !p.isWithin(root, fullPath)) {
                    debugPrint(
                      '[DMX] Blocked unsafe torrent file path: $relPath',
                    );
                    continue;
                  }

                  final file = File(fullPath);
                  if (await file.exists()) {
                    await file.delete();
                  }
                } catch (e) {
                  debugPrint(
                    'Failed to delete old torrent payload file $relPath: $e',
                  );
                }
              }
            }

            try {
              if (task.fileName.isNotEmpty) {
                final folderPath = p.normalize(p.join(root, task.fileName));
                if (p.isWithin(root, folderPath)) {
                  final dir = Directory(folderPath);
                  if (await dir.exists() && (await dir.list().isEmpty)) {
                    await dir.delete();
                  }
                }
              }
            } catch (e) {
              debugPrint('[DMX] Failed to delete empty torrent folder: $e');
            }
          }
        }

        DownloadMetadata? metadata;

        try {
          metadata = await _downloadEngine.resolveMetadata(
            url: cleanUrl,
            requestedFileName: task.fileName,
            customUserAgent: _settingsProvider.customUserAgent,
            enableProxy: _settingsProvider.enableProxy,
            proxyAddress: _settingsProvider.proxyAddress,
            proxyHost: _settingsProvider.proxyHost,
            proxyPort: _settingsProvider.proxyPort,
            proxyUsername: _settingsProvider.proxyUsername,
            proxyPassword: _settingsProvider.proxyPassword,
            bypassSSL: _settingsProvider.bypassSSL,
          );
        } catch (e) {
          throw Exception('Failed to resolve new torrent: $e');
        }

        final updatedTask = task.copyWith(
          url: cleanUrl,
          fileSize: metadata.fileSize > 0
              ? metadata.fileSize
              : (preserve ? task.fileSize : 0),
          supportsResume: metadata.supportsResume,
          // FIX-H4: Preserve bytes when the torrent identity is unchanged
          downloadedBytes:
              (isSameResource || isRefresh || sameTorrent(task.url, cleanUrl))
                  ? task.downloadedBytes
                  : 0,
          audioProgress: 0.0,
          chunks: List<double>.filled(task.threadCount, 0.0),
          torrentFiles: metadata.torrentFiles,
          clearTorrentFiles: !preserve && metadata.torrentFiles == null,
          fileName: (task.fileName.isEmpty ||
                  task.fileName == 'torrent_download.zip' ||
                  !preserve)
              ? metadata.fileName
              : task.fileName,
          clearError: true,
        );

        _tasks[index] = updatedTask;

        if (metadata.torrentId != null) {
          _torrentIds[updatedTask.id] = metadata.torrentId!;
        }

        await _databaseService.saveTask(updatedTask);

        notifyListeners();

        if (wasDownloading) {
          await resumeTask(taskId);
        }

        return;
      }

      // Resolve metadata for standard URL
      DownloadMetadata? metadata;

      final isYoutube = task.downloadPageUrl != null &&
          (task.downloadPageUrl!.contains('youtube.com/') ||
              task.downloadPageUrl!.contains('youtu.be/'));

      // FIX-04: For YouTube tasks, resolve via stream API instead of HEAD probe
      if (task.youtubeQualityPreset != null &&
          (cleanUrl.contains('youtube.com') || cleanUrl.contains('youtu.be'))) {
        try {
          final videoId = YoutubeService.extractVideoId(cleanUrl);
          if (videoId != null) {
            final streamInfo = await YoutubeService.getStreamForVideo(
              videoId,
              task.youtubeQualityPreset,
            );
            if (streamInfo != null && streamInfo['src'] != null) {
              final resolvedUrl = streamInfo['src'] as String;
              final resolvedAudioUrl = streamInfo['audioSrc'] as String?;
              final resolvedAudioSize = streamInfo['audioSize'] as int? ?? 0;
              final resolvedFileSize = streamInfo['size'] as int? ?? 0;
              final updatedTask = task.copyWith(
                url: resolvedUrl,
                mergedAudioUrl: resolvedAudioUrl,
                audioSize:
                    resolvedAudioSize > 0 ? resolvedAudioSize : task.audioSize,
                fileSize:
                    resolvedFileSize > 0 ? resolvedFileSize : task.fileSize,
                clearError: true,
              );
              _tasks[index] = updatedTask;
              _orchestrator.clearSessionCachedTotalSize(taskId); // FIX-11
              await _databaseService.saveTask(updatedTask);
              notifyListeners();
              if (wasDownloading) {
                await resumeTask(taskId);
              }
              return;
            }
          }
        } catch (e) {
          // Fall through to normal resolveMetadata path
        }
      }

      if (newFileSize == null && !isRefresh) {
        try {
          metadata = await _downloadEngine.resolveMetadata(
            url: cleanUrl,
            requestedFileName: task.fileName,
            customUserAgent: _settingsProvider.customUserAgent,
            enableProxy: _settingsProvider.enableProxy,
            proxyAddress: _settingsProvider.proxyAddress,
            proxyHost: _settingsProvider.proxyHost,
            proxyPort: _settingsProvider.proxyPort,
            proxyUsername: _settingsProvider.proxyUsername,
            proxyPassword: _settingsProvider.proxyPassword,
            bypassSSL: _settingsProvider.bypassSSL,
          );
        } catch (e) {
          throw Exception('Failed to resolve new link: $e');
        }
      }

      final resolvedFileSize =
          newFileSize ?? metadata?.fileSize ?? task.fileSize;

      final resolvedSupportsResume =
          isRefresh ? true : (metadata?.supportsResume ?? task.supportsResume);

      final wasYoutube = task.youtubeQualityPreset != null ||
          task.mergedAudioUrl != null ||
          (task.downloadPageUrl != null &&
              (task.downloadPageUrl!.contains('youtube.com/') ||
                  task.downloadPageUrl!.contains('youtu.be/')));
      final isNewYoutube =
          cleanUrl.contains('youtube.com/') || cleanUrl.contains('youtu.be/');

      final oldProto =
          wasTorrent ? 'torrent' : (wasYoutube ? 'youtube' : 'http');
      final newProto =
          isNewTorrent ? 'torrent' : (isNewYoutube ? 'youtube' : 'http');
      final isProtocolSwitch = oldProto != newProto;

      bool sizeChanged = isProtocolSwitch ||
          (!isSameResource && !isRefresh && (cleanUrl != task.url));
      // FIX-M7: Always check size; tighten tolerance for isSameResource
      if (!isRefresh && task.downloadedBytes > 0 && resolvedFileSize > 0) {
        final sizeDiff = (resolvedFileSize - task.fileSize).abs();
        final tolerance = isSameResource
            ? 1024.0 // tight: 1 KB
            : (task.fileSize * 0.01).clamp(1024.0, 10.0 * 1024 * 1024);
        if (sizeDiff > tolerance) {
          debugPrint(
              '[FIX-M7] Size changed (${task.fileSize} → $resolvedFileSize, diff=$sizeDiff, tol=$tolerance). Resetting progress.');
          sizeChanged = true;
        }
      }
      // FIX-8: When the new server omits Content-Length (resolvedFileSize == 0),
      // the size-diff guard above is skipped, so a completely different file
      // could resume into the existing temp file and corrupt it. If the
      // host/path changed, treat it as a new resource and reset progress.
      if (!isRefresh &&
          !isSameResource &&
          resolvedFileSize <= 0 &&
          task.downloadedBytes > 0) {
        final f8OldUri = Uri.tryParse(task.url);
        final f8NewUri = Uri.tryParse(cleanUrl);
        final hostChanged = f8OldUri?.host != f8NewUri?.host;
        final pathChanged = f8OldUri?.path != f8NewUri?.path;
        if (hostChanged || pathChanged) {
          debugPrint(
              '[FIX-8] Size unknown and resource changed. Resetting progress.');
          sizeChanged = true;
        }
      }
      if (isProtocolSwitch) {
        debugPrint(
            '[DMX] Protocol switch detected ($oldProto → $newProto). Resetting progress.');
      }

      final oldUri = Uri.tryParse(task.url);
      final newUri = Uri.tryParse(cleanUrl);

      final oldItag = oldUri?.queryParameters['itag'];
      final newItag = newUri?.queryParameters['itag'];

      final itagChanged =
          oldItag != null && newItag != null && oldItag != newItag;

      // FIX-YT-07: Also detect mime changes
      final oldMime = oldUri?.queryParameters['mime'];
      final newMime = newUri?.queryParameters['mime'];
      final mimeChanged =
          oldMime != null && newMime != null && oldMime != newMime;
      final streamIdentityChanged = itagChanged || mimeChanged;

      // ── FIX YT-1: Parallel audio identity check ──
      bool audioStreamIdentityChanged = false;
      if (task.mergedAudioUrl != null && (newAudioUrl != null || isRefresh)) {
        final oldAudioUri = Uri.tryParse(task.mergedAudioUrl!);
        final newAudioUri =
            newAudioUrl != null ? Uri.tryParse(newAudioUrl) : null;
        final oldAudioItag = oldAudioUri?.queryParameters['itag'];
        final newAudioItag = newAudioUri?.queryParameters['itag'];
        final oldAudioMime = oldAudioUri?.queryParameters['mime'];
        final newAudioMime = newAudioUri?.queryParameters['mime'];
        audioStreamIdentityChanged = (oldAudioItag != null &&
                newAudioItag != null &&
                oldAudioItag != newAudioItag) ||
            (oldAudioMime != null &&
                newAudioMime != null &&
                oldAudioMime != newAudioMime);
      }

      // FIX-B4: Detect token-only URL changes (covers null vs non-null)
      if (isYoutube && (streamIdentityChanged || audioStreamIdentityChanged)) {
        sizeChanged = true;
      } else if (!isRefresh &&
          resolvedFileSize > 0 &&
          task.fileSize > 0 &&
          resolvedFileSize != task.fileSize) {
        if (!isYoutube) {
          sizeChanged = true;
        }
      }

      if (!sizeChanged && !isYoutube && task.downloadedBytes > 0) {
        try {
          final int resolvedMetaSize;
          if (metadata != null) {
            resolvedMetaSize = metadata.fileSize;
          } else {
            final meta = await _downloadEngine.resolveMetadata(url: cleanUrl);
            resolvedMetaSize = meta.fileSize;
          }

          final newFileName = metadata?.fileName;
          if (newFileName != null &&
              newFileName.isNotEmpty &&
              newFileName != task.fileName &&
              task.fileName.isNotEmpty &&
              task.fileName != 'torrent_download.zip') {
            // FIX(B-3): Reset progress when fileName differs regardless of byte size match
            sizeChanged = true;
            debugPrint(
              '[DMX] URL update: fileName changed ${task.fileName} → '
              '$newFileName, resetting progress',
            );
          }

          // FIX-18: Use percentage-based tolerance instead of fixed 1024 bytes
          final tolerance =
              (task.fileSize * 0.01).clamp(1024.0, 10.0 * 1024 * 1024);
          if (resolvedMetaSize > 0 &&
              task.fileSize > 0 &&
              (resolvedMetaSize - task.fileSize).abs() > tolerance) {
            sizeChanged = true;

            debugPrint(
              '[DMX] URL update: size changed ${task.fileSize} → '
              '$resolvedMetaSize, resetting progress',
            );
          }
        } catch (e) {
          debugPrint(
            '[DMX] URL update: HEAD probe failed, assuming same size: $e',
          );
        }
      }

      // Re-resolve size when URL changes for non-torrent tasks
      if (!task.isTorrent &&
          cleanUrl != task.url &&
          newFileSize == null &&
          !isRefresh) {
        try {
          final meta = await _downloadEngine.resolveMetadata(
            url: cleanUrl,
            customUserAgent: _settingsProvider.customUserAgent,
            enableProxy: _settingsProvider.enableProxy,
            proxyAddress: _settingsProvider.proxyAddress,
            proxyHost: _settingsProvider.proxyHost,
            proxyPort: _settingsProvider.proxyPort,
            bypassSSL: _settingsProvider.bypassSSL,
          );
          if (meta.fileSize > 0) {
            // If size changed significantly, reset progress
            if (task.fileSize > 0 &&
                (meta.fileSize - task.fileSize).abs() >
                    (task.fileSize * 0.01)) {
              sizeChanged = true;
            }
          }
        } catch (e) {
          debugPrint('[DMX] Size re-resolution failed for new URL: $e');
        }
      }

      // FIX-01: State file update logic for URL refresh vs manual URL change
      if (isRefresh) {
        if (streamIdentityChanged) {
          // BUG 7 FIX: Cancel active download token first so isolate stops writing
          final token = _cancelTokens[taskId];
          if (token != null && !token.isCancelled) {
            token.cancel('stream_identity_changed');
            final fut = _activeFutures[taskId];
            if (fut != null) {
              try {
                await fut.timeout(const Duration(seconds: 3));
              } catch (_) {}
            }
          }
          // Stream identity changed on refresh -> delete state and part files
          for (final path in [
            task.tempFilePath,
            '${task.tempFilePath}.dmxstate',
            '${task.tempFilePath}.dmxstate.tmp',
          ]) {
            try {
              final f = File(path);
              if (await f.exists()) await f.delete();
            } catch (_) {}
          }
        } else {
          // Stream identity unchanged -> do NOT delete .dmxstate.
          // Update url field, clear etag and lastModified, and write back atomically.
          try {
            final stateFile = File('${task.tempFilePath}.dmxstate');
            if (await stateFile.exists()) {
              final raw = await stateFile.readAsString();
              final decoded = jsonDecode(raw);
              if (decoded is Map<String, dynamic>) {
                decoded['url'] = cleanUrl;
                decoded['etag'] = null;
                decoded['lastModified'] = null;
                final tmpFile = File('${task.tempFilePath}.dmxstate.tmp');
                await tmpFile.writeAsString(jsonEncode(decoded));
                if (await tmpFile.exists()) {
                  await tmpFile.rename(stateFile.path);
                }
              }
            }
          } catch (e) {
            debugPrint(
                '[DMX] FIX-01: Failed atomic state update on refresh: $e');
          }
        }
      } else if (cleanUrl != task.url &&
          !isSameResource &&
          !sameTorrent(task.url, cleanUrl)) {
        // Only delete .dmxstate on manual URL change when not same resource
        for (final p in [
          '${task.tempFilePath}.dmxstate',
          '${task.tempFilePath}.dmxstate.tmp',
        ]) {
          try {
            final f = File(p);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }

      // FIX(U-1): Also delete the temp file and audio temp file when size changes
      if (sizeChanged) {
        // Delete stale state files on size change
        for (final path in [
          task.tempFilePath,
          '${task.tempFilePath}.dmxstate',
          '${task.tempFilePath}.dmxstate.tmp',
          '${task.tempFilePath}.journal',
          '${task.tempFilePath}.audio',
          '${task.tempFilePath}.audio.dmxstate',
          '${task.tempFilePath}.audio.journal',
        ]) {
          try {
            final f = File(path);
            if (await f.exists()) await f.delete();
          } catch (e) {
            debugPrint('[DMX] Deleting stale file $path failed: $e');
          }
        }

        // FIX U-2: Reset audio state when size changes
        task = task.copyWith(
          audioProgress: 0.0,
          audioDownloadedBytes: 0,
          audioSize: newAudioSize ?? 0,
        );
      }

      final audioChanged = clearAudioUrl ||
          streamIdentityChanged ||
          (newAudioUrl != null && newAudioUrl != task.mergedAudioUrl);

      // FIX-08: Only delete audio sidecars when the audio itag actually changed
      final oldAudioItag =
          Uri.tryParse(task.mergedAudioUrl ?? '')?.queryParameters['itag'];
      final newAudioItag =
          Uri.tryParse(newAudioUrl ?? '')?.queryParameters['itag'];
      final audioItagChanged = oldAudioItag != null &&
          newAudioItag != null &&
          oldAudioItag != newAudioItag;
      if (audioItagChanged) {
        for (final path in [
          '${task.tempFilePath}.audio',
          '${task.tempFilePath}.audio.dmxstate',
          '${task.tempFilePath}.audio.journal',
        ]) {
          try {
            final f = File(path);
            if (await f.exists()) await f.delete();
          } catch (e) {
            debugPrint(
                '[DMX] FIX-D5: Failed to delete audio sidecar $path: $e');
          }
        }
      }

      final resolvedNewFileSize = sizeChanged || task.fileSize <= 0
          ? (resolvedFileSize > 0 ? resolvedFileSize : task.fileSize)
          : task.fileSize;
      // FIX(B-4): Clamp downloadedBytes when new file size is smaller
      final clampedBytes = resolvedNewFileSize > 0
          ? min(sizeChanged ? 0 : task.downloadedBytes, resolvedNewFileSize)
          : (sizeChanged ? 0 : task.downloadedBytes);

      // FIX(B3): On manual URL change (not auto-refresh), clear stale audio
      // unless explicitly provided. Expired audio URLs cause merge failures.
      final effectiveAudioUrl = isRefresh
          ? (newAudioUrl ?? task.mergedAudioUrl)
          : (newAudioUrl ?? (clearAudioUrl ? null : task.mergedAudioUrl));

      final shouldClearAudio = !isRefresh &&
          !clearAudioUrl &&
          newAudioUrl == null &&
          task.mergedAudioUrl != null &&
          cleanUrl != task.url;

      // FIX-11: Also clear YouTube-specific state on non-refresh URL change
      final shouldClearYoutubeState = !isRefresh &&
          task.youtubeQualityPreset != null &&
          cleanUrl != task.url;

      if (shouldClearAudio) {
        debugPrint(
          '[DMX] FIX(B3): URL changed without new audio URL. '
          'Clearing stale audio to prevent merge failure.',
        );
      }

      final updatedTask = task.copyWith(
        url: cleanUrl,
        mergedAudioUrl: (shouldClearAudio || clearAudioUrl || isProtocolSwitch)
            ? null
            : effectiveAudioUrl,
        clearMergedAudioUrl:
            shouldClearAudio || clearAudioUrl || isProtocolSwitch,
        fileSize: resolvedNewFileSize,
        audioSize: (sizeChanged || isProtocolSwitch || task.audioSize <= 0)
            ? (newAudioSize ?? (isProtocolSwitch ? 0 : task.audioSize))
            : task.audioSize,
        // FIX-03: Reset audioProgress when audioChanged OR sizeChanged
        audioProgress: (audioChanged || sizeChanged || isProtocolSwitch)
            ? 0.0
            : task.audioProgress,
        // FIX YT-U1: Reset videoStreamSize when the stream identity changed
        // so the combined size denominator is recalculated from the new stream.
        videoStreamSize:
            (sizeChanged || isProtocolSwitch || streamIdentityChanged)
                ? 0
                : task.videoStreamSize,
        youtubeQualityPreset: (shouldClearYoutubeState || isProtocolSwitch)
            ? null
            : task.youtubeQualityPreset,
        clearYoutubeQualityPreset: shouldClearYoutubeState || isProtocolSwitch,
        torrentFiles: isProtocolSwitch
            ? null
            : (metadata?.torrentFiles ?? task.torrentFiles),
        clearTorrentFiles:
            isProtocolSwitch || (!preserve && metadata?.torrentFiles == null),
        supportsResume: resolvedSupportsResume,
        downloadedBytes: isProtocolSwitch ? 0 : clampedBytes,
        chunks: (sizeChanged || isProtocolSwitch)
            ? List<double>.filled(task.threadCount, 0.0)
            : task.chunks,
        fileName: (task.fileName.isEmpty ||
                task.fileName == 'torrent_download.zip' ||
                isProtocolSwitch)
            ? (metadata?.fileName ?? task.fileName)
            : task.fileName,
        clearError: true,
      );

      _tasks[index] = updatedTask;
      _orchestrator.clearSessionCachedTotalSize(taskId);

      await _databaseService.saveTask(updatedTask);

      // FIX 8: Mark filter cache dirty after updateTaskUrl
      filteredTasksDirty = true;
      notifyListeners();

      if (wasDownloading) {
        await resumeTask(taskId);
      }
    } catch (e) {
      if (wasDownloading) {
        unawaited(resumeTask(taskId));
      }
      rethrow;
    }
  }

  @override
  Future<void> updateTaskUrlAndResume(
    String id,
    String newUrl, {
    String? newAudioUrl,
  }) async {
    final task = _findTask(id);
    if (task == null) return;

    // Check if the stream format (itag) changed
    final oldUri = Uri.tryParse(task.url);
    final newUri = Uri.tryParse(newUrl);

    final oldItag = oldUri?.queryParameters['itag'];
    final newItag = newUri?.queryParameters['itag'];

    final itagChanged =
        oldItag != null && newItag != null && oldItag != newItag;

    // FIX-B3: Extract and compare audio stream itag
    final oldAudioItag = task.mergedAudioUrl != null
        ? Uri.tryParse(task.mergedAudioUrl!)?.queryParameters['itag']
        : null;
    final newAudioItag = newAudioUrl != null
        ? Uri.tryParse(newAudioUrl)?.queryParameters['itag']
        : null;
    final audioItagChanged = oldAudioItag != null &&
        newAudioItag != null &&
        oldAudioItag != newAudioItag;

    final isYoutube = task.downloadPageUrl != null &&
        (task.downloadPageUrl!.contains('youtube.com/') ||
            task.downloadPageUrl!.contains('youtu.be/'));

    if (!isYoutube) {
      try {
        final meta = await _downloadEngine.resolveMetadata(url: newUrl);
        if (meta.fileSize > 0 &&
            task.fileSize > 0 &&
            (meta.fileSize - task.fileSize).abs() >
                max(100 * 1024, (task.fileSize * 0.05).toInt())) {
          await startOverTask(id, newUrl, newAudioUrl: newAudioUrl);
          return;
        }
      } catch (_) {
        /* probe failed → fall through to normal resume */
      }
    }

    final streamIdentityChanged = itagChanged || audioItagChanged;
    if (streamIdentityChanged) {
      // Delete all temp/state files since the stream format changed
      await cleanupPartFiles(task, preserveParts: false);
      await startOverTask(id, newUrl,
          newAudioUrl: newAudioUrl, deleteTempFiles: true);
      return;
    } else {
      // updateTaskUrl already handles resume internally for downloading tasks
      // FIX-AUDIO-REFRESH: If the refreshed stream swapped the audio URL/itag,
      // the .audio sidecars on disk belong to the OLD stream. Wipe them and reset
      // audio progress so the merge never combines mismatched audio.
      final oldAudioUri = Uri.tryParse(task.mergedAudioUrl ?? '');
      final newAudioUri =
          newAudioUrl != null ? Uri.tryParse(newAudioUrl) : null;
      final oldAudioItag = oldAudioUri?.queryParameters['itag'];
      final newAudioItag = newAudioUri?.queryParameters['itag'];
      final audioChanged =
          newAudioUrl != null && newAudioUrl != task.mergedAudioUrl;
      final audioItagChanged = oldAudioItag != null &&
          newAudioItag != null &&
          oldAudioItag != newAudioItag;
      if (audioChanged || audioItagChanged) {
        for (final p in [
          '${task.tempFilePath}.audio',
          '${task.tempFilePath}.audio.dmxstate',
          '${task.tempFilePath}.audio.journal',
          '${task.tempFilePath}.audio.itag',
        ]) {
          try {
            final f = File(p);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
        final fresh = _findTask(id);
        if (fresh != null) {
          await _setTask(
            fresh.copyWith(
              audioProgress: 0.0,
              audioDownloadedBytes: 0,
              audioSize: 0,
            ),
          );
        }
      }

      await updateTaskUrl(id, newUrl,
          newAudioUrl: newAudioUrl, isRefresh: true);
      final updated = _findTask(id);

      if (updated != null &&
          (updated.status == DownloadStatus.paused ||
              updated.status == DownloadStatus.failed)) {
        await resumeTask(id);
      }
    }
  }

  @override
  Future<void> startOverTask(
    String id,
    String newUrl, {
    String? newAudioUrl,
    bool clearAudioUrl = false,
    bool fromError = false,
    int? newFileSize,
    int? newAudioSize,
    bool deleteTempFiles = false,
  }) async {
    final task = _findTask(id);
    if (task == null) return;

    // FIX-AUDIT-04: Clear cached total so new URL's size is used as denominator
    _orchestrator.clearSessionCachedTotalSize(id);

    _cancelTokens[id]?.cancel('restart');
    _cancelTokens.remove(id);

    final activeFuture = _activeFutures[id];

    if (activeFuture != null && !fromError) {
      try {
        await activeFuture;
        // ignore: avoid_catches_without_on_clauses
      } catch (e) {
        debugPrint('[DMX] activeFuture error in cancel: $e');
      }
    }

    final torrentId = _torrentIds[id];
    if (torrentId != null) {
      TorrentService.removeTorrent(torrentId, deleteFiles: false);
      _torrentIds.remove(id);
      unawaited(TorrentResumeStore.delete(
          torrentId)); // FIX-9: Clear TorrentResumeStore
    }

    // FIX-R-1: Delete audio sidecars when newAudioUrl differs from task.mergedAudioUrl
    if (newAudioUrl != null && newAudioUrl != task.mergedAudioUrl) {
      for (final p in [
        '${task.tempFilePath}.audio',
        '${task.tempFilePath}.audio.dmxstate',
        '${task.tempFilePath}.audio.journal',
      ]) {
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }

    // Preserve any existing partial bytes and state so a restart can resume
    // from the current temp file instead of discarding it.
    await cleanupPartFiles(task, preserveParts: !deleteTempFiles);

    try {
      final localFile = File(task.localFilePath);
      if (await localFile.exists()) {
        await localFile.delete();
      }
    } catch (e) {
      debugPrint('Failed to delete completed file during start over: $e');
    }

    if (deleteTempFiles) {
      try {
        final tempFile = File(task.tempFilePath);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        // FIX-AUDIT-A5: Also delete audio sidecars
        for (final path in [
          task.tempFilePath,
          '${task.tempFilePath}.dmxstate',
          '${task.tempFilePath}.dmxstate.tmp',
          '${task.tempFilePath}.journal',
          '${task.tempFilePath}.audio',
          '${task.tempFilePath}.audio.dmxstate',
          '${task.tempFilePath}.audio.dmxstate.tmp',
          '${task.tempFilePath}.audio.journal',
          '${task.tempFilePath}.audio.itag',
        ]) {
          try {
            final f = File(path);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('Failed to delete temp files: $e');
      }
    }

    // FIX-C3: Force realBytesOnDisk to 0 when deleteTempFiles is true so task is reset clean
    final videoBytes = deleteTempFiles
        ? 0
        : await _readDmxStateBytes(
            task.tempFilePath,
            threadCount: task.threadCount, // FIX-B1: Pass task threadCount
          );
    var audioBytes = 0;
    final targetAudioUrl = newAudioUrl ?? task.mergedAudioUrl;
    if (!deleteTempFiles &&
        targetAudioUrl != null &&
        targetAudioUrl.isNotEmpty) {
      audioBytes = await _readDmxStateBytes(
        '${task.tempFilePath}.audio',
        // FIX-4: Never hardcode 2. Small audio (<5 MB) uses 1 thread → no
        // .dmxstate written → reading with threadCount:2 returns 0 and loses
        // progress. Use the task's real audio thread count.
        threadCount: task.audioThreadCount > 0 ? task.audioThreadCount : 1,
      );
    }

    final realBytesOnDisk = deleteTempFiles ? 0 : (videoBytes + audioBytes);

    await _setTask(
      task.copyWith(
        url: newUrl.trim(),
        mergedAudioUrl: targetAudioUrl,
        clearMergedAudioUrl: clearAudioUrl,
        status: DownloadStatus.queued,
        downloadedBytes: deleteTempFiles ? 0 : realBytesOnDisk,
        chunks: List<double>.filled(
            task.threadCount > 0 ? task.threadCount : 1, 0.0),
        audioProgress: deleteTempFiles ? 0.0 : task.audioProgress,
        speed: 0,
        clearEta: true,
        clearError: true,
        clearStatusMessage: true,
        clearCompletedAt: true,
        pausedByUser: false,
      ),
    );
    _orchestrator.clearSessionCachedTotalSize(id);

    pumpQueue();
    _startWidgetTimer();
    _updateTelemetryWidget(force: true);
  }

  // ---------------------------------------------------------------------------
  // Bandwidth scheduling
  // ---------------------------------------------------------------------------

  int _effectiveSpeedLimit() =>
      _settingsProvider.effectiveSpeedLimitBytesPerSecond;

  // ---------------------------------------------------------------------------
  // Dispose
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _disposed = true;

    _settingsProvider.removeListener(_onSettingsChanged);

    _notifications.dispose();
    _torrentUpdatesSubscription?.cancel();

    _networkMonitor.dispose();
    _scheduleManager.dispose();

    // Cancel ALL retry timers
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    for (final timer in _dbRetryTimers.values) {
      timer.cancel();
    }
    _dbRetryTimers.clear();

    _torrentInitTimer?.cancel();
    _scheduleManager.dispose();
    _widgetTimer?.cancel();

    // Cancel all active download tokens
    for (final token in _cancelTokens.values) {
      token.cancel('provider disposed');
    }
    _cancelTokens.clear();
    _activeFutures.clear();

    // Clear ALL tracking maps
    _speedHistories.clear();
    _lastProgressUpdateTimes.clear();
    _lastDbSaveTimes.clear();
    _lastDbSaveBytes.clear();
    _pendingProgressUpdates.clear();
    _ytLowSpeedCounts.clear();
    _ytThrottlingRefreshing.clear();
    _lastTorrentFileDiskSync.clear();
    _torrentIds.clear();
    _retryCounts.clear();
    _dbRetryCounts.clear();
    // FIX-AUDIT-14: Clear tracking sets on dispose
    _resumeRejectionRestarts.clear();
    effectiveThreadOverrides.clear();
    _downloadMetrics.clear();

    _orchestrator.dispose();

    // Drain pending DB saves, then always close the engine.
    final pendingSaves = _dbSaveQueues.values.toList();
    _dbSaveQueues.clear();

    if (pendingSaves.isNotEmpty) {
      Future.wait(pendingSaves).then(
        (_) => _downloadEngine.close(),
        onError: (_) => _downloadEngine.close(),
      );
    } else {
      _downloadEngine.close();
    }

    _latestTorrentStats.clear();
    super.dispose();
  }

  Future<void> _cleanupOrphanedFiles() async {
    final activePaths = <String>{};
    for (final task in _tasks) {
      if (task.tempFilePath.isNotEmpty) {
        activePaths.add(p.canonicalize(task.tempFilePath));
      }
      if (task.localFilePath.isNotEmpty) {
        activePaths.add(p.canonicalize(task.localFilePath));
      }
    }

    final defaultDir = await _permissionService.defaultDownloadDirectory();
    final dir = Directory(defaultDir);
    if (!await dir.exists()) return;

    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = p.canonicalize(entity.path);
        final isOrphan = (name.endsWith('.dmxpart') ||
                name.endsWith('.dmxstate') ||
                name.endsWith('.journal') ||
                name.endsWith('.audio') ||
                name.endsWith('.audio.dmxstate')) &&
            !activePaths.any((pPath) => name.startsWith(
                pPath.replaceAll('.dmxpart', '').replaceAll('.dmxstate', '')));
        if (isOrphan) {
          try {
            await entity.delete();
          } catch (e) {
            debugPrint('[DMX] Failed to cleanup orphan: ${entity.path}');
          }
        }
      }
    } catch (e) {
      debugPrint('[DMX] Orphan cleanup scan failed: $e');
    }
  }

  Future<void> _autoResumeIncomplete() async {
    final candidates = _tasks.where((t) {
      final isPausedOrInterrupted = t.status == DownloadStatus.paused ||
          t.status == DownloadStatus.failed;
      final isNotUserPausedOrScheduled = !t.pausedByUser &&
          t.errorMessage != DownloadStatusMessages.waitingWifi &&
          t.errorMessage != DownloadStatusMessages.waitingNetwork &&
          (t.scheduledAt == null || t.scheduledAt!.isBefore(DateTime.now()));
      return isPausedOrInterrupted && isNotUserPausedOrScheduled;
    }).toList();

    var updatedAny = false;
    for (var task in candidates) {
      var realBytesOnDisk = task.downloadedBytes;
      if (task.tempFilePath.isNotEmpty) {
        final stateFile = File('${task.tempFilePath}.dmxstate');
        if (await stateFile.exists()) {
          // FIX-5: If the audio temp file is gone, reset audio state so the
          // engine re-downloads audio instead of merging with phantom bytes.
          if (task.hasMergedAudio) {
            final audioTempFile = File('${task.tempFilePath}.audio');
            if (!await audioTempFile.exists()) {
              task = task.copyWith(
                audioProgress: 0.0,
                audioDownloadedBytes: 0,
              );
            }
          }

          // ── Read ACTUAL progress from .dmxstate, never from pre-allocated file length ──
          final videoBytes = await _readDmxStateBytes(task.tempFilePath,
              threadCount: task.threadCount);
          var audioBytes = 0;
          if (task.mergedAudioUrl != null && task.mergedAudioUrl!.isNotEmpty) {
            audioBytes = await _readDmxStateBytes('${task.tempFilePath}.audio',
                threadCount:
                    task.audioThreadCount > 0 ? task.audioThreadCount : 1);
          }
          final diskBytes = videoBytes + audioBytes;
          if (diskBytes > 0) {
            realBytesOnDisk = diskBytes;
          }
        }
      }

      final updated = task.copyWith(
        status: DownloadStatus.queued,
        downloadedBytes: realBytesOnDisk,
        speed: 0,
        clearEta: true,
        clearError: true,
      );

      final idx = _tasks.indexWhere((t) => t.id == task.id);
      if (idx != -1) {
        _tasks[idx] = updated;
        await _databaseService.saveTask(updated);
        updatedAny = true;
      }
    }

    if (updatedAny) {
      filteredTasksDirty = true;
      notifyListeners();
    }
  }

  bool _isYoutubeUrlExpired(String url) {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return true;
      final expireStr = uri.queryParameters['expire'];
      if (expireStr == null) return false;
      final expireTime = int.tryParse(expireStr);
      if (expireTime == null) return false;
      final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return nowSecs > (expireTime - 300); // 5 minutes buffer
    } catch (_) {
      return true;
    }
  }

  static bool youtubeStreamIdentityChanged(String oldUrl, String newUrl) {
    try {
      final oldUri = Uri.tryParse(oldUrl);
      final newUri = Uri.tryParse(newUrl);
      if (oldUri == null || newUri == null) return false;

      final oldItag = oldUri.queryParameters['itag'];
      final newItag = newUri.queryParameters['itag'];
      final oldMime = oldUri.queryParameters['mime'];
      final newMime = newUri.queryParameters['mime'];

      final hostPathChanged =
          (oldUri.host != newUri.host) || (oldUri.path != newUri.path);

      return (oldItag != null && newItag != null && oldItag != newItag) ||
          (oldMime != null && newMime != null && oldMime != newMime) ||
          hostPathChanged;
    } catch (_) {
      return false;
    }
  }
}
