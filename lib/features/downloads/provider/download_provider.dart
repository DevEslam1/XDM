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

import '../../../core/services/torrent_service.dart';
import '../../../core/services/update_service.dart';
// ignore_for_file: prefer_initializing_formals
import '../../../core/services/background_service.dart';
import '../../../core/services/database/app_database.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/download_engine.dart';
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
    this.enableBackgroundTimers = true,
  })  : _databaseService = databaseService,
        _settingsProvider = settingsProvider,
        _downloadEngine = downloadEngine ?? DownloadEngine(),
        _permissionService = permissionService ?? PermissionService(),
        _notificationService = notificationService ?? NotificationService() {
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

    _scheduleManager = ScheduleManager(
      tasks: () => _tasks,
      databaseService: _databaseService,
      isDisposed: () => _disposed,
      downloadingTasksCount: () => downloadingTasksCount,
      updateTorrentUploadLimit: updateActualTorrentUploadLimit,
      notifyListeners: notifyListeners,
      pumpQueue: pumpQueue,
    );
    if (enableBackgroundTimers) {
      _scheduleManager.start();
    }

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

    _orchestrator = DownloadOrchestrator(this);

    // Subscribe lazily — torrent engine may not be initialized yet.
    if (enableBackgroundTimers) {
      _initTorrentSubscription();
    }
  }

  Timer? _torrentInitTimer;

  void _initTorrentSubscription() {
    if (_torrentUpdatesSubscription != null) return;

    if (!TorrentService.isInitialized) {
      _torrentInitTimer?.cancel();
      _torrentInitTimer = Timer(const Duration(seconds: 2), () {
        if (_disposed) return;
        _initTorrentSubscription();
      });
      return;
    }

    _torrentUpdatesSubscription = TorrentService.torrentUpdates.listen((
      torrents,
    ) {
      _latestTorrentStats = torrents;
    });
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
  final Map<String, Queue<double>> _speedHistories = {};
  final Map<String, Future<void>> _dbSaveQueues = {};

  /// Per-task progress and speed ValueNotifiers for isolated repainting.
  final Map<String, ValueNotifier<double>> _progressNotifiers = {};
  final Map<String, ValueNotifier<double>> _speedNotifiers = {};

  ValueNotifier<double> progressNotifier(String taskId) =>
      _progressNotifiers.putIfAbsent(taskId, () => ValueNotifier(0.0));

  ValueNotifier<double> speedNotifier(String taskId) =>
      _speedNotifiers.putIfAbsent(taskId, () => ValueNotifier(0.0));

  void _pushTick(String taskId, double progress, double speed) {
    progressNotifier(taskId).value = progress;
    speedNotifier(taskId).value = speed;
  }

  /// FIX(R2): Surfaces the most recent DB-save failure without crashing the zone.
  /// Callers (e.g. UI snackbars) can listen to this to warn the user.
  final ValueNotifier<String?> lastSaveError = ValueNotifier<String?>(null);

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
  void startTaskFromQueue(DownloadTask task) => _orchestrator.startTask(task);

  @override
  void updateTelemetryWidget({bool force = false}) =>
      _updateTelemetryWidget(force: force);

  @override
  bool isTaskWaitingForRetry(String taskId) => _retryTimers.containsKey(taskId);

  @override
  void providerNotifyListeners() => notifyListeners();

  @override
  void providerStartWidgetTimer() => _startWidgetTimer();

  // ---------------------------------------------------------------------------
  // DownloadOrchestratorHost contract implementations
  // ---------------------------------------------------------------------------

  @override
  Map<String, CancelToken> get cancelTokens => _cancelTokens;

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

  Future<int?> _actualPartialBytes(DownloadTask task) async {
    if (task.tempFilePath.trim().isEmpty) return null;

    final fileState = await _statPartialFileIsolate(task.tempFilePath);
    if (!fileState.exists) {
      return task.downloadedBytes;
    }

    final targetSize = fileState.targetSize;

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
            return totalInt > targetSize ? targetSize : totalInt;
          }

          return task.downloadedBytes > 0
              ? task.downloadedBytes.clamp(0, targetSize)
              : 0;
        } catch (e) {
          // State file corrupted — fall back to actual file size on disk
          debugPrint('[DMX] .dmxstate corrupted for ${task.id}, '
              'falling back to file size: $e');
          try {
            final partFile = File(task.tempFilePath);
            if (await partFile.exists()) {
              return await partFile.length();
            }
          } catch (_) {}
          return 0;
        }
      }

      // Multi-threaded: partial file may be pre-allocated to full size.
      // Without .dmxstate, the file size is meaningless as progress.
      return task.downloadedBytes > 0
          ? task.downloadedBytes.clamp(0, targetSize)
          : 0;
    }

    if (task.downloadedBytes > 0 && task.downloadedBytes <= targetSize) {
      return task.downloadedBytes;
    }

    return targetSize;
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

  /// [pauseOrphanDownloads] should be true only on initial app startup, when
  /// in-flight downloads (from a previous run) cannot be resumed safely.
  /// On user-triggered reload, we must preserve currently active downloads.
  Future<void> load({bool pauseOrphanDownloads = true}) async {
    _generation++;

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

    final loaded = dbTasks.map((task) {
      // Only mark in-flight downloads as paused on initial load.
      // If a CancelToken exists in the in-memory map, an active download
      // stream is still running and must not be flipped to paused.
      final hasActiveStream = _cancelTokens.containsKey(task.id);

      if (pauseOrphanDownloads &&
          task.status == DownloadStatus.downloading &&
          !hasActiveStream) {
        return task.copyWith(
          status: DownloadStatus.paused,
          speed: 0,
          clearEta: true,
          errorMessage: DownloadStatusMessages.pausedOrphaned,
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

    filteredTasksDirty = true;

    for (final task in toDelete) {
      await _databaseService.deleteTask(task.id);
      await cleanupPartFiles(task);
    }

    await _databaseService.saveTasks(_tasks);

    // Automatically restart seeding for completed torrents with seeding enabled
    for (final task in _tasks) {
      if (task.isTorrent &&
          task.status == DownloadStatus.completed &&
          task.seedingEnabled) {
        startSeedingTorrent(task);
      }
    }

    updateActualTorrentUploadLimit();

    _startWidgetTimer();
    notifyListeners();

    // Resolve connectivity BEFORE any scheduled downloads or pumpQueue to
    // prevent downloads starting on mobile data when wifiOnly is enabled.
    await _networkMonitor.ensureInitialConnectivity();
    await _networkMonitor.checkNetworkConnectivity(skipPump: true);

    _scheduleManager.checkScheduledDownloads();

    // Auto-resume if enabled — unpause orphaned downloads (excluding
    // user-paused, scheduled, or Wi-Fi-waiting tasks) and pump the queue so queued
    // downloads start immediately.
    if (_settingsProvider.autoStart) {
      final pausedCandidates = _tasks
          .where(
            (t) =>
                t.status == DownloadStatus.paused &&
                !t.pausedByUser &&
                t.errorMessage != DownloadStatusMessages.waitingWifi &&
                (t.scheduledAt == null ||
                    t.scheduledAt!.isBefore(DateTime.now())),
          )
          .toList();

      for (final candidate in pausedCandidates) {
        _cancelTokens.remove(candidate.id);

        final videoBytes = await _readDmxStateBytes(candidate.tempFilePath);
        var audioBytes = 0;
        if (candidate.mergedAudioUrl != null &&
            candidate.mergedAudioUrl!.isNotEmpty) {
          audioBytes =
              await _readDmxStateBytes('${candidate.tempFilePath}.audio');
        }

        final realBytesOnDisk = videoBytes + audioBytes;
        final hasState =
            await File('${candidate.tempFilePath}.dmxstate').exists();
        final chunks = hasState
            ? candidate.chunks
            : List<double>.filled(candidate.threadCount, 0.0);

        final updatedTask = candidate.copyWith(
          status: DownloadStatus.queued,
          downloadedBytes: realBytesOnDisk,
          chunks: chunks,
          speed: 0,
          clearEta: true,
          clearError: true,
        );

        final idx = _tasks.indexWhere((t) => t.id == candidate.id);
        if (idx != -1) {
          _tasks[idx] = updatedTask;
          await _databaseService.saveTask(updatedTask);
        }
      }

      if (pausedCandidates.isNotEmpty) {
        filteredTasksDirty = true;
        notifyListeners();
      }
    }

    // Always pump the queue so queued-downloads (including newly
    // auto-resumed ones) start without requiring user interaction.
    pumpQueue();

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

    // 1. Add all tasks to the in-memory list first (no pump yet).
    _tasks.addAll(tasks);
    filteredTasksDirty = true;

    // 2. Persist in a single batch write.
    try {
      await _databaseService.saveTasks(tasks);
    } catch (e) {
      debugPrint('[DMX] batch save failed: $e');
    }

    // 3. Notify UI immediately so all cards appear at once.
    notifyListeners();

    // 4. Pump once with the full batch size as the concurrency ceiling.
    pumpQueue(maxConcurrentOverride: tasks.length);
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

    final defaultDirectory =
        _settingsProvider.customDownloadPath?.isNotEmpty == true
            ? _settingsProvider.customDownloadPath!
            : await _permissionService.defaultDownloadDirectory();

    final bool isMagnet = url.trim().toLowerCase().startsWith('magnet:');
    final bool isTorrent = isTorrentUrl(url, fileName: name);

    String resolvedCategory;
    String fileName;
    int fileSize;
    bool supportsResume;

    final int torrentFilesTotalSize = (torrentFiles != null &&
            torrentFiles.isNotEmpty)
        ? torrentFiles
            .where((f) => f['selected'] == true)
            .fold(0, (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0))
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
          (f) => f['selected'] == true,
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
          : (catCandidate != 'Other' ? catCandidate : 'Video');

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
          : categoryFromFileName(fileName);

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
    );

    _tasks.insert(0, task);

    if (torrentId != null) {
      _torrentIds[task.id] = torrentId;
    }

    filteredTasksDirty = true;

    await _databaseService.saveTask(task);

    notifyListeners();
    _updateTelemetryWidget(force: true);

    if (!isScheduled && shouldPumpQueue) {
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
    final task = _findTask(id);
    if (task == null) return;

    // Flush any pending throttled progress to disk so resume has the latest bytes.
    await _flushPendingProgress(id);

    _retryCounts.remove(id);
    _speedHistories.remove(id);
    _lastProgressUpdateTimes.remove(id);
    _lastDbSaveTimes.remove(id);
    _lastDbSaveBytes.remove(id);
    _pendingProgressUpdates.remove(id);

    _retryTimers[id]?.cancel();
    _retryTimers.remove(id);

    if (task.status == DownloadStatus.downloading) {
      final torrentId = _torrentIds[id];
      if (torrentId != null) {
        TorrentService.pauseTorrent(torrentId);
      }

      // Cancel the token only.
      // Cancellation gates new starts via the cancel token check in _startTaskBody;
      // Removing the cancel token allows future resumes.
      try {
        _cancelTokens[id]?.cancel('paused');
      } catch (e) {
        // Ignore
      }

      _cancelTokens.remove(id);
    }

    // Cancel any lingering progress notification (M2).
    _notifications.cancelForTask(id);

    await _setTask(
      task.copyWith(
        status: DownloadStatus.paused,
        speed: 0,
        clearEta: true,
        clearError: true,
        clearStatusMessage: true,
        clearScheduledAt: true,
        pausedByUser: true,
      ),
    );

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
    final task = _findTask(id);
    if (task == null || task.status == DownloadStatus.completed) return;

    _retryCounts.remove(id);

    await _setTask(
      task.copyWith(
        status: DownloadStatus.queued,
        speed: 0,
        clearEta: true,
        clearError: true,
        clearStatusMessage: true,
        clearCompletedAt: true,
        pausedByUser: false,
      ),
    );

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
      ),
    );

    pumpQueue();

    if (activeOrSeedingCount == 0) {
      _stopWidgetTimer();
    }

    _updateTelemetryWidget(force: true);
  }

  Future<void> retryTask(String id) async {
    final task = _findTask(id);
    if (task == null || task.status == DownloadStatus.completed) return;

    _retryCounts.remove(id);

    // ── Read ACTUAL progress from .dmxstate, never from pre-allocated file length ──
    final videoBytes = await _readDmxStateBytes(task.tempFilePath);
    var audioBytes = 0;
    if (task.mergedAudioUrl != null && task.mergedAudioUrl!.isNotEmpty) {
      audioBytes = await _readDmxStateBytes('${task.tempFilePath}.audio');
    }

    final realBytesOnDisk = videoBytes + audioBytes;

    // If no .dmxstate exists, engine will start fresh → reset chunks
    final hasState = await File('${task.tempFilePath}.dmxstate').exists();
    final chunks = hasState
        ? task.chunks
        : List<double>.filled(task.threadCount > 0 ? task.threadCount : 1, 0.0);

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
        pausedByUser: false,
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

  /// Reads the sum of chunk progress from a `.dmxstate` sidecar file.
  /// Returns 0 when the file is missing, corrupt, or empty.
  static Future<int> _readDmxStateBytes(String tempFilePath) async {
    final stateFile = File('$tempFilePath.dmxstate');
    if (await stateFile.exists()) {
      try {
        final content = await stateFile.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is Map && decoded['progress'] is List) {
          return (decoded['progress'] as List)
              .fold<int>(0, (sum, chunk) => sum + ((chunk as num).toInt()));
        }
      } catch (e, st) {
        _log.warning('[download_provider] operation failed', e, st);
        // Corrupt state → treat as fresh start
      }
    }
    // Fallback if no .dmxstate exists (e.g. single-threaded download or finished stream file)
    try {
      final tempFile = File(tempFilePath);
      if (await tempFile.exists()) {
        return await tempFile.length();
      }
    } catch (_) {}
    return 0;
  }

  Future<void> deleteTask(String id, {bool deleteFiles = false}) async {
    final task = _findTask(id);
    if (task == null) return;

    final activeFuture = _activeFutures[id];

    try {
      _cancelTokens[id]?.cancel('deleted');
    } catch (e) {
      // Ignore
    }

    if (activeFuture != null) {
      try {
        await activeFuture;
        // ignore: avoid_catches_without_on_clauses
      } catch (e) {
        debugPrint('[DMX] activeFuture error in save: $e');
      }
    }

    _cancelTokens.remove(id);
    _speedHistories.remove(id);
    _lastProgressUpdateTimes.remove(id);
    _lastDbSaveTimes.remove(id);
    _lastDbSaveBytes.remove(id);
    _pendingProgressUpdates.remove(id);
    effectiveThreadOverrides.remove(id);
    _retryCounts.remove(id);
    _ytLowSpeedCounts.remove(id);
    _ytThrottlingRefreshing.remove(id);

    _retryTimers[id]?.cancel();
    _retryTimers.remove(id);

    _lastTorrentFileDiskSync.remove(id);
    _downloadMetrics.remove(id);
    _dbRetryCounts.remove(id);
    _dbRetryTimers[id]?.cancel();
    _dbRetryTimers.remove(id);

    final savedNotificationId = _notifications.removeId(id);

    _activeFutures.remove(id);

    // Permanent delete → full cleanup, no preservation
    await cleanupPartFiles(task, preserveParts: false);

    _tasks.removeWhere((task) => task.id == id);
    filteredTasksDirty = true;

    final torrentId = _torrentIds[id];
    if (torrentId != null) {
      TorrentService.removeTorrent(torrentId, deleteFiles: deleteFiles);
      _torrentIds.remove(id);
    }

    if (deleteFiles) {
      try {
        final localFile = File(task.localFilePath);
        if (await localFile.exists()) {
          await localFile.delete();
        }
      } catch (e) {
        debugPrint('Failed to delete completed file: $e');
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

    await _databaseService.deleteTask(id);

    if (savedNotificationId != null) {
      _notifications.cancelNotification(savedNotificationId);
    }

    updateActualTorrentUploadLimit();

    notifyListeners();
    pumpQueue();

    if (activeOrSeedingCount == 0) {
      BackgroundService.stop();
      _stopWidgetTimer();
    }

    _updateTelemetryWidget(force: true);
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
      _ytLowSpeedCounts.remove(id);
      _ytThrottlingRefreshing.remove(id);
      _lastTorrentFileDiskSync.remove(id);
      _downloadMetrics.remove(id);
      _dbRetryCounts.remove(id);
      effectiveThreadOverrides.remove(id);

      _retryTimers[id]?.cancel();
      _retryTimers.remove(id);
      _dbRetryTimers[id]?.cancel();
      _dbRetryTimers.remove(id);

      _activeFutures.remove(id);

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
    final useIncomingProgress =
        incoming.downloadedBytes >= live.downloadedBytes ||
            incoming.status != live.status;

    return incoming.copyWith(
      downloadedBytes:
          useIncomingProgress ? incoming.downloadedBytes : live.downloadedBytes,
      speed: useIncomingProgress ? incoming.speed : live.speed,
      eta: useIncomingProgress ? incoming.eta : live.eta,
      chunks: useIncomingProgress ? incoming.chunks : live.chunks,
      audioProgress:
          useIncomingProgress ? incoming.audioProgress : live.audioProgress,
    );
  }

  Future<void> _setTask(DownloadTask updated) async {
    final index = _tasks.indexWhere((task) => task.id == updated.id);
    if (index == -1) return;

    final prev = _tasks[index];
    // Merge structural fields from `updated` into the live in-memory task,
    // preserving progress fields (downloadedBytes, speed, eta, chunks,
    // audioProgress) to prevent state regression during active downloads.
    _tasks[index] = _mergeTaskUpdate(prev, updated);

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

    updateActualTorrentUploadLimit();

    _pushTick(updated.id, updated.progress, updated.speed.toDouble());

    // Progress-only changes (speed, bytes, eta, chunks) skip the immediate
    // DB save and notifyListeners. The timer-based batch save persists
    // progress periodically, and _notifyPending coalesces UI notifications
    // to the timer frequency (~5 s) so we don't rebuild widgets on every tick.
    if (!isStructuralChange) {
      _pendingProgressUpdates.add(updated.id);
      _notifyPending = true;

      // Complete any previous queued save so the chain stays consistent.
      final previousSave = _dbSaveQueues[updated.id];
      if (previousSave != null) {
        try {
          await previousSave;
        } catch (e, st) {
          _log.warning('[download_provider] operation failed', e, st);
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
    final chunks = List<double>.filled(effectiveThreadCount, 0.0);
    double remaining = overallProgress * effectiveThreadCount;
    for (int i = 0; i < effectiveThreadCount; i++) {
      chunks[i] = remaining.clamp(0.0, 1.0);
      remaining -= chunks[i];
    }
    return chunks;
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
      final bridge = WidgetDataBridge.instance;
      final freeSpace = await bridge.fetchFreeDiskSpace();

      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day);
      final summaries = <WidgetTaskSummary>[];

      for (final task in _tasks) {
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
            fileSizeBytes: task.resolvedFileSize,
            downloadedBytes: task.downloadedBytes,
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
        await cleanupPartFiles(task, preserveParts: true);
      } catch (e) {
        debugPrint('Error preserving segment files on thread count change: $e');
      }

      task = task.copyWith(
        threadCount: targetThreadCount,
        status: DownloadStatus.paused,
        clearError: true,
      );
    } else {
      task = task.copyWith(
        threadCount: targetThreadCount,
        chunks: List<double>.filled(targetThreadCount, 0.0),
      );
    }

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
  }) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    var task = _tasks[index];

    final cleanUrl = newUrl.trim();
    if (task.url == cleanUrl) return;

    if (!isValidTransmissionUrl(cleanUrl)) {
      throw Exception('Invalid URL/Magnet');
    }

    final wasDownloading = task.status == DownloadStatus.downloading;

    if (wasDownloading) {
      await pauseTask(taskId);

      final updatedIdx = _tasks.indexWhere((t) => t.id == taskId);
      if (updatedIdx != -1) {
        task = _tasks[updatedIdx];
      }
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

      await cleanupPartFiles(task, preserveParts: true);

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
        fileSize: metadata.fileSize > 0 ? metadata.fileSize : task.fileSize,
        supportsResume: metadata.supportsResume,
        downloadedBytes: 0,
        chunks: List<double>.filled(task.threadCount, 0.0),
        torrentFiles: metadata.torrentFiles,
        fileName:
            (task.fileName.isEmpty || task.fileName == 'torrent_download.zip')
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

    final resolvedFileSize = newFileSize ?? metadata?.fileSize ?? task.fileSize;

    final resolvedSupportsResume =
        isRefresh ? true : (metadata?.supportsResume ?? task.supportsResume);

    bool sizeChanged = false;

    final oldUri = Uri.tryParse(task.url);
    final newUri = Uri.tryParse(cleanUrl);

    final oldItag = oldUri?.queryParameters['itag'];
    final newItag = newUri?.queryParameters['itag'];

    final itagChanged =
        oldItag != null && newItag != null && oldItag != newItag;

    if (isYoutube && itagChanged) {
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
        final meta = await _downloadEngine.resolveMetadata(url: cleanUrl);

        if (meta.fileSize > 0 &&
            task.fileSize > 0 &&
            (meta.fileSize - task.fileSize).abs() > 1024) {
          sizeChanged = true;

          debugPrint(
            '[DMX] URL update: size changed ${task.fileSize} → '
            '${meta.fileSize}, resetting progress',
          );
        }
      } catch (e) {
        debugPrint(
          '[DMX] URL update: HEAD probe failed, assuming same size: $e',
        );
      }
    }

    final updatedTask = task.copyWith(
      url: cleanUrl,
      mergedAudioUrl: newAudioUrl ?? task.mergedAudioUrl,
      fileSize: sizeChanged || task.fileSize <= 0
          ? (resolvedFileSize > 0 ? resolvedFileSize : task.fileSize)
          : task.fileSize,
      audioSize: sizeChanged || task.audioSize <= 0
          ? (newAudioSize ?? task.audioSize)
          : task.audioSize,
      supportsResume: resolvedSupportsResume,
      // Only reset progress when the file actually changed
      downloadedBytes: sizeChanged ? 0 : task.downloadedBytes,
      chunks: sizeChanged
          ? List<double>.filled(task.threadCount, 0.0)
          : task.chunks,
      fileName:
          (task.fileName.isEmpty || task.fileName == 'torrent_download.zip')
              ? (metadata?.fileName ?? task.fileName)
              : task.fileName,
      clearError: true,
    );

    _tasks[index] = updatedTask;

    await _databaseService.saveTask(updatedTask);

    notifyListeners();

    if (wasDownloading) {
      await resumeTask(taskId);
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

    if (itagChanged) {
      await startOverTask(id, newUrl, newAudioUrl: newAudioUrl);
    } else {
      // updateTaskUrl already handles resume internally for downloading tasks
      await updateTaskUrl(
        id,
        newUrl,
        newAudioUrl: newAudioUrl,
        isRefresh: true,
      );

      final updated = _findTask(id);

      if (updated != null &&
          (updated.status == DownloadStatus.paused ||
              updated.status == DownloadStatus.failed)) {
        await resumeTask(id);
      }
    }
  }

  Future<void> startOverTask(
    String id,
    String newUrl, {
    String? newAudioUrl,
    bool clearAudioUrl = false,
    bool fromError = false,
    int? newFileSize,
    int? newAudioSize,
  }) async {
    final task = _findTask(id);
    if (task == null) return;

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
    }

    // Preserve any existing partial bytes and state so a restart can resume
    // from the current temp file instead of discarding it.
    await cleanupPartFiles(task, preserveParts: true);

    try {
      final localFile = File(task.localFilePath);
      if (await localFile.exists()) {
        await localFile.delete();
      }
    } catch (e) {
      debugPrint('Failed to delete completed file during start over: $e');
    }

    final videoBytes = await _readDmxStateBytes(task.tempFilePath);
    var audioBytes = 0;
    final targetAudioUrl = newAudioUrl ?? task.mergedAudioUrl;
    if (targetAudioUrl != null && targetAudioUrl.isNotEmpty) {
      audioBytes = await _readDmxStateBytes('${task.tempFilePath}.audio');
    }
    final realBytesOnDisk = videoBytes + audioBytes;

    await _setTask(
      task.copyWith(
        url: newUrl.trim(),
        mergedAudioUrl: targetAudioUrl,
        clearMergedAudioUrl: clearAudioUrl,
        fileSize: newFileSize ?? task.fileSize,
        audioSize: newAudioSize ?? task.audioSize,
        status: DownloadStatus.queued,
        downloadedBytes: realBytesOnDisk,
        speed: 0,
        clearEta: true,
        clearError: true,
        clearCompletedAt: true,
        chunks: List<double>.filled(task.threadCount, 0.0),
      ),
    );

    pumpQueue();
    _startWidgetTimer();
    _updateTelemetryWidget(force: true);
  }

  // ---------------------------------------------------------------------------
  // Bandwidth scheduling
  // ---------------------------------------------------------------------------

  int _effectiveSpeedLimit() {
    final settings = _settingsProvider;

    if (settings.bandwidthScheduleEnabled) {
      final now = TimeOfDay.now();

      final start = _parseTimeOfDay(settings.scheduleStartTime);
      final end = _parseTimeOfDay(settings.scheduleEndTime);

      if (_isWithinWindow(now, start, end)) {
        final scheduleLimit =
            (settings.scheduleSpeedLimitMb * 1024 * 1024).round();

        final globalLimit = settings.speedLimitBytesPerSecond;

        if (scheduleLimit > 0 &&
            (globalLimit == 0 || scheduleLimit < globalLimit)) {
          return scheduleLimit;
        }
      }
    }

    return settings.speedLimitBytesPerSecond;
  }

  TimeOfDay _parseTimeOfDay(String value) {
    final parts = value.split(':');

    final hour = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 0) : 0;
    final minute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;

    return TimeOfDay(hour: hour.clamp(0, 23), minute: minute.clamp(0, 59));
  }

  bool _isWithinWindow(TimeOfDay now, TimeOfDay start, TimeOfDay end) {
    final nowMinutes = now.hour * 60 + now.minute;
    final startMinutes = start.hour * 60 + start.minute;
    final endMinutes = end.hour * 60 + end.minute;

    if (startMinutes <= endMinutes) {
      return nowMinutes >= startMinutes && nowMinutes <= endMinutes;
    }

    // Overnight window (e.g., 23:00 - 07:00)
    return nowMinutes >= startMinutes || nowMinutes <= endMinutes;
  }

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

    super.dispose();
  }
}
