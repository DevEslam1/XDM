import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/interfaces/i_download_engine.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/diagnostic_service.dart';
import '../../../core/services/download_engine.dart' hide DownloadCommand;
import '../../../core/services/download_journal.dart';
import '../../../core/services/download_metrics.dart';
import '../../../core/services/logging_service.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/power_monitor.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/services/update_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/torrent_id_resolver.dart';
import '../../settings/provider/settings_provider.dart';
import '../data/drift_task_snapshot_store.dart';
import '../domain/commands/download_commands.dart';
import '../domain/events/download_events.dart';
import '../domain/executor/task_executor.dart';
import '../models/download_add_spec.dart';
import '../models/download_task.dart';
import '../services/download_engine_adapter.dart';
import 'download_orchestrator.dart';
import 'mixins/download_backup_mixin.dart';
import 'mixins/download_filter_mixin.dart';
import 'mixins/download_queue_mixin.dart';
import 'mixins/download_torrent_mixin.dart';
import 'network_monitor.dart';
import 'notification_coordinator.dart';
import 'schedule_manager.dart';

export '../models/download_add_spec.dart';

/// Decomposed [DownloadProvider] acting as a UI projection and command dispatcher (<600 lines).
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
    IDownloadEngine? downloadEngine,
    PermissionService? permissionService,
    NotificationService? notificationService,
    bool enableBackgroundTimers = true,
  })  : _databaseService = databaseService,
        _settingsProvider = settingsProvider,
        _downloadEngine = downloadEngine ??
            DownloadEngine(
              enableCleanupTimer: enableBackgroundTimers &&
                  !Platform.environment.containsKey('FLUTTER_TEST'),
            ),
        _permissionService = permissionService ?? PermissionService(),
        _notificationService = notificationService ?? NotificationService(),
        enableBackgroundTimers = enableBackgroundTimers &&
            !Platform.environment.containsKey('FLUTTER_TEST') {
    _settingsProvider.addListener(_onSettingsChanged);
    _networkMonitor = NetworkMonitor(
      tasks: () => _tasks,
      torrentIds: () => _torrentIds,
      cancelTokens: () => _cancelTokens,
      activeFutures: () => _activeFutures,
      wifiOnly: () => _settingsProvider.wifiOnly,
      setTask: _setTask,
      pumpQueue: pumpQueue,
      onNetworkChanged: (cmd) => _executor.dispatch(cmd),
    );
    _scheduleManager = ScheduleManager(
      tasks: () => _tasks,
      databaseService: _databaseService,
      isDisposed: () => _disposed,
      downloadingTasksCount: () => downloadingTasksCount,
      updateTorrentUploadLimit: updateTorrentUploadLimit,
      notifyListeners: notifyListeners,
      pumpQueue: pumpQueue,
      onScheduleFired: (id) => _executor.dispatch(ScheduleFired(id)),
    );
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
      onStopAll: pauseAllTasks,
      onStartAll: resumeAllTasks,
      onExitApp: () async => exit(0),
    );
    _orchestrator = DownloadOrchestrator(this);
    _engineAdapter = DownloadEngineAdapter(
      downloadEngine: _downloadEngine,
      findTask: _findTask,
      saveTask: _setTask,
      pumpQueueCallback: () => pumpQueue(),
      torrentIdForTask: (taskId) => _torrentIds[taskId],
    );
    _snapshotStore = DriftTaskSnapshotStore(
      databaseService: _databaseService,
      findTask: _findTask,
      onTaskUpdated: (updated) {
        final idx = _tasks.indexWhere((t) => t.id == updated.id);
        if (idx != -1) {
          _tasks[idx] = updated;
        } else {
          _tasks.add(updated);
        }
        _taskIndex[updated.id] = updated;
        filteredTasksDirty = true;
        notifyListeners();
      },
    );
    _executor = TaskExecutor(
      enginePort: _engineAdapter,
      snapshotStore: _snapshotStore,
      auditLog: _auditLog,
    );
    _eventSubscription = _executor.events.listen(_onDomainEvent);
  }

  final DatabaseService _databaseService;
  final SettingsProvider _settingsProvider;
  final IDownloadEngine _downloadEngine;
  final PermissionService _permissionService;
  final NotificationService _notificationService;
  @override
  final bool enableBackgroundTimers;

  late final NetworkMonitor _networkMonitor;
  late final ScheduleManager _scheduleManager;
  late final NotificationCoordinator _notifications;
  late final DownloadOrchestrator _orchestrator;
  late final DownloadEngineAdapter _engineAdapter;
  late final DriftTaskSnapshotStore _snapshotStore;
  late final TaskExecutor _executor;
  final TransitionAuditLog _auditLog = TransitionAuditLog();
  final Map<String, ValueNotifier<double>> _progressNotifiers = {};
  final Map<String, ValueNotifier<double>> _speedNotifiers = {};
  StreamSubscription<DownloadEvent>? _eventSubscription;

  final List<DownloadTask> _tasks = [];
  final Map<String, DownloadTask> _taskIndex = {};
  bool _disposed = false;
  String? lastError;
  Timer? _widgetUpdateTimer;
  Timer? _torrentPollingTimer;

  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, ({CancelToken video, CancelToken audio})>
      _orchestratorTokens = {};
  final Map<String, Future<void>> _activeFutures = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, int> _retryCounts = {};
  final Map<String, Queue<double>> _speedHistories = {};
  final Map<String, Queue<double>> _uploadSpeedHistories = {};
  final Map<String, int> _lastProgressUpdateTimes = {},
      _lastDbSaveTimes = {},
      _lastDbSaveBytes = {},
      _lastTorrentFileDiskSync = {};
  final Set<String> _pendingProgressUpdates = {};
  final Map<String, int> _ytLowSpeedCounts = {};
  final Map<String, bool> _ytThrottlingRefreshing = {};
  final Map<String, int> _torrentIds = {};
  final Map<int, TorrentUpdateInfo> _latestTorrentStats = {};
  final Map<String, bool> _resumeRejectionRestarts = {};
  final Map<String, DownloadMetrics> _downloadMetrics = {};

  @override
  List<DownloadTask> get providerTasks => _tasks;
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  TransitionAuditLog get auditLog => _auditLog;
  ScheduleManager get scheduleManager => _scheduleManager;
  @override
  NetworkMonitor get networkMonitor => _networkMonitor;
  @override
  NotificationCoordinator get notifications => _notifications;
  TaskExecutor get executor => _executor;
  PermissionService get permissionService => _permissionService;
  @override
  int get pendingStartCount => _orchestrator.pendingStartCount;
  @override
  bool get providerIsOnWifi => _networkMonitor.hasWifiOrEthernet;
  @override
  bool get providerIsCharging => PowerMonitor.isCharging;
  @override
  SettingsProvider get providerSettingsProvider => _settingsProvider;
  @override
  DatabaseService get providerDatabaseService => _databaseService;
  @override
  IDownloadEngine get downloadEngine => _downloadEngine;
  @override
  bool get providerDisposed => _disposed;
  @override
  Map<String, CancelToken> get cancelTokens => _cancelTokens;
  @override
  Map<String, ({CancelToken video, CancelToken audio})>
      get orchestratorTokens => _orchestratorTokens;
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
  Map<String, int> get lastDbSaveBytes => _lastDbSaveBytes;
  @override
  Map<String, int> get lastTorrentFileDiskSync => _lastTorrentFileDiskSync;
  @override
  Set<String> get pendingProgressUpdates => _pendingProgressUpdates;
  @override
  Map<String, int> get ytLowSpeedCounts => _ytLowSpeedCounts;
  @override
  Map<String, bool> get ytThrottlingRefreshing => _ytThrottlingRefreshing;
  @override
  Map<String, int> get providerTorrentIds => _torrentIds;
  @override
  Map<int, TorrentUpdateInfo> get providerLatestTorrentStats =>
      TorrentService.latestStats.isNotEmpty
          ? TorrentService.latestStats
          : _latestTorrentStats;
  @override
  Map<String, bool> get resumeRejectionRestarts => _resumeRejectionRestarts;
  @override
  Map<String, DownloadMetrics> get downloadMetrics => _downloadMetrics;

  @override
  double get currentDownloadSpeed => _tasks
      .where((t) => t.status == DownloadStatus.downloading)
      .fold(0.0, (s, t) => s + t.speed);
  int get totalDownloadedBytes =>
      _tasks.fold(0, (s, t) => s + t.downloadedBytes);

  void _onSettingsChanged() => notifyListeners();
  void _onDomainEvent(DownloadEvent event) {
    filteredTasksDirty = true;
    notifyListeners();
  }

  Future<void> load({
    bool pauseOrphanDownloads = true,
    bool autoResume = true,
  }) async {
    final loaded = await _databaseService.loadTasks();
    final List<DownloadTask> reconciledTasks = [];

    // Phase 5 Startup Pipeline:
    // Step 1: Journal replay -> Step 2: Disk reconciliation
    for (final task in loaded) {
      var reconciled = task;
      final localPath =
          task.savePath.isNotEmpty ? task.savePath : task.localFilePath;
      final shouldReconcile = !task.isTorrent &&
          task.status != DownloadStatus.completed &&
          !task.isCancelled;

      if (shouldReconcile) {
        final tempPath = task.tempFilePath.isNotEmpty
            ? task.tempFilePath
            : (localPath.isNotEmpty ? '$localPath.dmxpart' : '');
        final localFile = localPath.isNotEmpty ? File(localPath) : null;

        // Check if final destination file exists and matches full size
        if (task.fileSize > 0 &&
            localFile != null &&
            await localFile.exists() &&
            (await localFile.length()) >= task.fileSize) {
          reconciled = reconciled.copyWith(
            status: DownloadStatus.completed,
            downloadedBytes: task.fileSize,
            errorMessage: null,
          );
        } else if (tempPath.isNotEmpty) {
          try {
            final stateResult = await StateStore.loadOrCreate(
              tempPath,
              url: task.url,
              threadCount: task.threadCount,
              knownFileSize: task.fileSize,
              taskId: task.id,
            );
            final state = stateResult.state;
            if (state.downloadedBytes > 0) {
              reconciled = reconciled.copyWith(
                downloadedBytes: state.downloadedBytes,
              );
              DiagnosticService.instance.recordTelemetryAlert(
                'journal_reconciled',
                taskId: task.id,
                details: 'bytes=${state.downloadedBytes}',
              );
            }
          } catch (e) {
            debugPrint(
                '[DownloadProvider] Startup reconciliation error for ${task.id}: $e');
          }
        }
      }

      if (pauseOrphanDownloads &&
          reconciled.status == DownloadStatus.downloading) {
        reconciled = reconciled.copyWith(
          status: DownloadStatus.paused,
          pauseReason: PauseReason.appRestarted,
          pausedByUser: false,
        );
      }

      // Step 3: DB update (Order matters; DB is updated last after journal & disk reconciliation)
      if (reconciled != task) {
        await _databaseService.saveTask(reconciled);
      }

      reconciledTasks.add(reconciled);
    }

    // Step 4: UI update (DB write complete, now expose to in-memory state & notify UI)
    _tasks.clear();
    _taskIndex.clear();
    _tasks.addAll(reconciledTasks);
    for (final task in reconciledTasks) {
      _taskIndex[task.id] = task;
    }
    filteredTasksDirty = true;
    notifyListeners();

    _scheduleManager.setReady(true);
    await _networkMonitor.ensureInitialConnectivity();
    if (autoResume) {
      _autoResumeIncomplete();
    }
    _startTorrentPollingTimer();
  }

  void _autoResumeIncomplete() {
    for (final task in _tasks) {
      if (task.isCancelled || task.pausedByUser) continue;
      if (task.status == DownloadStatus.downloading) {
        resumeTask(task.id);
      } else if (task.status == DownloadStatus.paused) {
        final isWaitingWifi =
            task.errorMessage?.toLowerCase().contains('waiting for wifi') ==
                true;
        final isWaitingNet =
            task.errorMessage?.toLowerCase().contains('waiting for network') ==
                true;
        if (isWaitingWifi) {
          if (_networkMonitor.hasWifiOrEthernet) resumeTask(task.id);
        } else if (isWaitingNet) {
          if (_networkMonitor.hasConnection) resumeTask(task.id);
        } else if (_settingsProvider.autoStart) {
          resumeTask(task.id);
        }
      }
    }
  }

  DownloadTask? _findTask(String id) => _taskIndex[id];

  @override
  DownloadTask? findTaskById(String id) => _taskIndex[id];
  DownloadTask? taskById(String id) => _taskIndex[id];
  bool isTaskOperationPending(String taskId) => false;
  bool get isLoadingTasks => false;
  bool get isReconciling => false;
  void setActiveTabIndex(int index) => setMixinActiveTabIndex(index);
  DownloadMetrics? getMetrics(String taskId) => _downloadMetrics[taskId];
  List<double> getSpeedHistory(String taskId) =>
      _speedHistories[taskId]?.toList() ?? const [];
  List<double> getUploadSpeedHistory(String taskId) =>
      _uploadSpeedHistories[taskId]?.toList() ?? const [];
  ValueNotifier<double> progressNotifier(String taskId) =>
      _progressNotifiers.putIfAbsent(taskId, () => ValueNotifier<double>(0.0));
  ValueNotifier<double> speedNotifier(String taskId) =>
      _speedNotifiers.putIfAbsent(taskId, () => ValueNotifier<double>(0.0));
  void disposeTaskNotifier(String taskId) {
    _progressNotifiers.remove(taskId)?.dispose();
    _speedNotifiers.remove(taskId)?.dispose();
  }

  void updateTorrentUploadLimit() => updateActualTorrentUploadLimit();

  static bool youtubeStreamIdentityChanged(String? oldUrl, String? newUrl) {
    if (oldUrl == null || newUrl == null || oldUrl == newUrl) return false;
    final oldUri = Uri.tryParse(oldUrl);
    final newUri = Uri.tryParse(newUrl);
    if (oldUri == null ||
        newUri == null ||
        oldUri.host.isEmpty ||
        newUri.host.isEmpty) {
      return false;
    }
    if (oldUri.host != newUri.host) return true;
    final oldId =
        oldUri.queryParameters['id'] ?? oldUri.queryParameters['docid'];
    final newId =
        newUri.queryParameters['id'] ?? newUri.queryParameters['docid'];
    final oldItag = oldUri.queryParameters['itag'];
    final newItag = newUri.queryParameters['itag'];
    final oldMime = oldUri.queryParameters['mime'];
    final newMime = newUri.queryParameters['mime'];
    final oldClen = oldUri.queryParameters['clen'];
    final newClen = newUri.queryParameters['clen'];
    return (oldId != null && newId != null && oldId != newId) ||
        (oldItag != null && newItag != null && oldItag != newItag) ||
        (oldMime != null && newMime != null && oldMime != newMime) ||
        (oldClen != null && newClen != null && oldClen != newClen);
  }

  static int torrentBytesFromFiles(List<Map<String, dynamic>>? files) =>
      files == null
          ? 0
          : files.where((f) => f['selected'] != false).fold(
              0, (s, f) => s + ((f['downloadedBytes'] as num?)?.toInt() ?? 0));

  static int torrentSelectedFilesTotalSize(List<Map<String, dynamic>>? files) =>
      files == null
          ? 0
          : files.where((f) => f['selected'] != false).fold(
              0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0));

  static List<double> reconcileChunks({
    required List<double> stateChunks,
    required int actualBytesOnDisk,
    required int fileSize,
    required int threadCount,
  }) {
    if (threadCount <= 0) return const [];
    if (fileSize <= 0) return List.filled(threadCount, 0.0);
    return List.filled(
        threadCount, (actualBytesOnDisk / fileSize).clamp(0.0, 1.0));
  }

  static int calculateDownloadedFromState(Map<String, dynamic> stateJson) {
    if (stateJson.containsKey('downloadedBytes')) {
      return (stateJson['downloadedBytes'] as num?)?.toInt() ?? 0;
    }
    if (stateJson['progress'] is List) {
      final list = stateJson['progress'] as List;
      final total = (stateJson['totalSize'] as num?)?.toInt() ?? 0;
      var sum = 0;
      for (final item in list) {
        if (item is num) {
          if (item <= 1.0 && total > 0) {
            sum += (item * (total / list.length)).round();
          } else {
            sum += item.toInt();
          }
        }
      }
      return sum;
    }
    return 0;
  }

  void _startTorrentPollingTimer() {
    if (_torrentPollingTimer != null && _torrentPollingTimer!.isActive) return;
    _torrentPollingTimer?.cancel();
    _torrentPollingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _pollTorrentStatusAndSpeeds();
    });
  }

  void _stopTorrentPollingTimer() {
    _torrentPollingTimer?.cancel();
    _torrentPollingTimer = null;
  }

  void _pollTorrentStatusAndSpeeds() {
    if (_disposed) {
      _stopTorrentPollingTimer();
      return;
    }

    bool hasActiveTorrents = false;
    bool hasActiveDownloads = false;
    bool tasksModified = false;

    for (int i = 0; i < _tasks.length; i++) {
      var task = _tasks[i];

      // 1. Record download speed history for downloading tasks
      if (task.status == DownloadStatus.downloading) {
        hasActiveDownloads = true;
        final q = _speedHistories.putIfAbsent(task.id, () => Queue<double>());
        q.add(task.speed);
        if (q.length > 60) q.removeFirst();
      }

      // 2. Poll torrent status and file progress
      if (task.isTorrent) {
        final isDownloading = task.status == DownloadStatus.downloading;
        final isSeeding =
            task.status == DownloadStatus.completed && task.seedingEnabled;
        final isCompleted = task.status == DownloadStatus.completed;

        if (isDownloading || isSeeding || isCompleted) {
          final torrentId = task.torrentId ??
              TorrentIdResolver.resolve(task, providerMap: _torrentIds);
          if (torrentId != null && torrentId >= 0) {
            if (isDownloading || isSeeding) {
              hasActiveTorrents = true;
            }

            // The torrent service already receives the native status snapshot
            // (including per-file progress) from the libtorrent update stream.
            // Do not issue another synchronous FFI status query here: status()
            // and file_progress() block the caller and used to race the
            // handler's snapshot, producing stale cards and unnecessary work.
            final status = TorrentService.latestStats[torrentId];

            if (status != null) {
              // The public service snapshot exposes aggregate piece counts.
              // Use them consistently for chunk progress; the native bridge
              // does not expose a stable per-piece bitfield in its C ABI.
              List<double>? updatedChunks;
              final count = task.threadCount > 0 ? task.threadCount : 1;
              if (status.piecesTotal > 0 && status.piecesHave >= 0) {
                final overallRatio =
                    (status.piecesHave / status.piecesTotal).clamp(0.0, 1.0);
                updatedChunks = List.filled(count, overallRatio);
              }

              // File progress propagation with a brand new list & map reference
              List<Map<String, dynamic>>? updatedFiles;
              int selectedFileDownloaded = 0;
              bool hasSelectedFileProgress = false;
              if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
                updatedFiles = List<Map<String, dynamic>>.from(
                  task.torrentFiles!.map((f) => Map<String, dynamic>.from(f)),
                );
                for (int fIdx = 0; fIdx < updatedFiles.length; fIdx++) {
                  final f = updatedFiles[fIdx];
                  final len = (f['length'] as num?)?.toInt() ??
                      (f['size'] as num?)?.toInt() ??
                      0;
                  int dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
                  if (fIdx < status.fileProgress.length &&
                      status.fileProgress[fIdx] >= 0) {
                    dl = status.fileProgress[fIdx];
                    f['downloadedBytes'] = dl;
                    f['progressEstimated'] = false;
                    final selected = (f['selected'] as bool?) ?? true;
                    final priority = (f['priority'] as num?)?.toInt() ?? 4;
                    if (selected && priority > 0) {
                      selectedFileDownloaded += dl;
                      hasSelectedFileProgress = true;
                    }
                  }
                  final bool isComp =
                      (len > 0 && dl >= len) || f['isComplete'] == true;
                  f['isComplete'] = isComp;
                  f['progress'] = len > 0
                      ? (dl / len).clamp(0.0, 1.0)
                      : (isComp ? 1.0 : 0.0);
                }
              }

              final newFileSize = task.fileSize > 0
                  ? task.fileSize
                  : (status.totalWanted > 0
                      ? status.totalWanted
                      : task.fileSize);
              final newDownloaded = isCompleted && newFileSize > 0
                  ? newFileSize
                  : (hasSelectedFileProgress
                      ? selectedFileDownloaded
                      : (status.totalWantedDone > 0
                          ? status.totalWantedDone
                          : (status.totalDone > 0
                              ? status.totalDone
                              : task.downloadedBytes)));

              final updatedTask = task.copyWith(
                torrentId: torrentId,
                fileSize: newFileSize,
                downloadedBytes: newDownloaded,
                uploadedBytes: status.totalPayloadUpload > 0
                    ? status.totalPayloadUpload
                    : task.uploadedBytes,
                speed: isDownloading
                    ? status.downloadRate.toDouble()
                    : (isSeeding ? status.uploadRate.toDouble() : task.speed),
                completedPieces: status.piecesHave > 0
                    ? status.piecesHave
                    : task.completedPieces,
                totalPieces:
                    status.piecesTotal > 0
                        ? status.piecesTotal
                        : task.totalPieces,
                chunks: updatedChunks ?? task.chunks,
                torrentFiles: updatedFiles ?? task.torrentFiles,
              );

              if (updatedTask != task) {
                _tasks[i] = updatedTask;
                _taskIndex[task.id] = updatedTask;
                task = updatedTask;
                tasksModified = true;
              }
            }

            // Record upload speed history
            final ulSpeed = getTorrentUploadSpeed(task.id);
            final uq = _uploadSpeedHistories.putIfAbsent(
                task.id, () => Queue<double>());
            uq.add(ulSpeed);
            if (uq.length > 60) uq.removeFirst();
          }
        }
      }
    }

    if (updateSeedingSpeeds()) {
      tasksModified = true;
    }
    checkTorrentRatioLimits();

    if (tasksModified) {
      filteredTasksDirty = true;
      notifyListeners();
    } else {
      notifyListeners();
    }

    if (!hasActiveTorrents && !hasActiveDownloads) {
      _stopTorrentPollingTimer();
    }
  }

  Future<void> _setTask(DownloadTask task) async {
    await _databaseService.saveTask(task);
    final idx = _tasks.indexWhere((t) => t.id == task.id);
    if (idx != -1) {
      _tasks[idx] = task;
    } else {
      _tasks.add(task);
    }
    _taskIndex[task.id] = task;
    filteredTasksDirty = true;
    if (task.status == DownloadStatus.downloading ||
        (task.isTorrent && task.seedingEnabled)) {
      _startTorrentPollingTimer();
    }
    if (!DownloadEngine.isInBackground || !PowerMonitor.screenOff) {
      notifyListeners();
    }
  }

  @override
  Future<void> setTaskState(DownloadTask task) async {
    final existing = _findTask(task.id);
    if (existing != null) {
      if (existing.pausedByUser && task.status == DownloadStatus.downloading) {
        task = task.copyWith(
          status: DownloadStatus.paused,
          pausedByUser: true,
        );
      } else if (existing.status == DownloadStatus.failed &&
          task.status == DownloadStatus.downloading) {
        return;
      } else if (existing.status == DownloadStatus.completed &&
          task.status != DownloadStatus.completed) {
        return;
      }
    }
    final isProgressOnly = existing != null &&
        existing.status == task.status &&
        existing.status == DownloadStatus.downloading &&
        existing.downloadedBytes != task.downloadedBytes;
    final idx = _tasks.indexWhere((t) => t.id == task.id);
    if (idx != -1) {
      _tasks[idx] = task;
    } else {
      _tasks.add(task);
    }
    _taskIndex[task.id] = task;
    filteredTasksDirty = true;
    if (task.status == DownloadStatus.downloading ||
        (task.isTorrent && task.seedingEnabled)) {
      _startTorrentPollingTimer();
    }
    if (isProgressOnly) {
      _pendingProgressUpdates.add(task.id);
    } else {
      _pendingProgressUpdates.remove(task.id);
      await _databaseService.saveTask(task);
    }
    if (!DownloadEngine.isInBackground || !PowerMonitor.screenOff) {
      notifyListeners();
    }
  }

  Future<void> updateTask(DownloadTask task) => setTaskState(task);
  Future<void> restoreTask(DownloadTask task) => _setTask(task);

  Future<void> _deleteFileSafely(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _applyStateChange(
    String id,
    DomainDownloadState toState,
    DownloadCommand cmd, {
    String? reason,
    String? errorMessage,
    bool? pausedByUser,
    bool? isCancelled,
    String? pauseReason,
  }) async {
    final task = _findTask(id);
    if (task == null) return;
    DownloadStateMachine(
            taskId: id, initialState: DownloadStateMachine.fromStatus(task.status))
        .transition(toState, reason: reason ?? errorMessage);
    await _snapshotStore.onTaskStateChanged(
      id,
      DownloadStateMachine.fromStatus(task.status),
      toState,
      cmd,
      errorMessage: errorMessage,
      pausedByUser: pausedByUser,
      isCancelled: isCancelled,
      pauseReason: pauseReason,
    );
    final updated = _findTask(id);
    if (updated != null) {
      _tasks[_tasks.indexOf(updated)] = updated;
      _taskIndex[updated.id] = updated;
      filteredTasksDirty = true;
      notifyListeners();
    }
    pumpQueue();
  }

  Future<void> markCompletedFileMissing(String taskId) => _applyStateChange(
        taskId,
        DomainDownloadState.failed,
        CancelTask(taskId),
        errorMessage: 'File missing',
      );

  Future<void> updateTaskThreadCount(String id, int threadCount) async {
    final task = _findTask(id);
    if (task == null) return;
    final isZeroProgress = task.downloadedBytes == 0;
    if (!isZeroProgress) {
      await _deleteFileSafely(task.tempFilePath);
      await _deleteFileSafely('${task.tempFilePath}.dmxstate');
    }
    await _setTask(task.copyWith(
      threadCount: threadCount,
      chunks: List<double>.filled(threadCount, 0.0),
      downloadedBytes: isZeroProgress ? task.downloadedBytes : 0,
    ));
  }

  Future<void> updateTaskSpeedLimit(String id, int limitKbps) async {
    final task = _findTask(id);
    if (task != null) await _setTask(task.copyWith(speedLimitKbps: limitKbps));
  }

  Future<void> deleteMultipleTasks(List<String> ids,
      {bool deleteFiles = false}) async {
    for (final id in ids) {
      await deleteTask(id, deleteFiles: deleteFiles);
    }
  }

  Future<void> resumeMultipleTasks(List<String> ids) async {
    for (final id in ids) {
      await resumeTask(id);
    }
  }

  Future<void> pauseMultipleTasks(List<String> ids) async {
    for (final id in ids) {
      await pauseTask(id);
    }
  }

  Future<void> changeCategoryForMultipleTasks(
      List<String> ids, String category) async {
    for (final id in ids) {
      final t = _findTask(id);
      if (t != null) await _setTask(t.copyWith(category: category));
    }
  }

  Future<bool> addDownload({
    String url = '',
    String? name,
    String? category,
    int? size,
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
    String? savePath,
    String? expectedSha256,
    List<String>? mirrorUrls,
    String? siteType,
    String? siteDisplayName,
    String? contentHint,
  }) async {
    var effectiveSavePath = (savePath != null && savePath.isNotEmpty)
        ? savePath
        : (_settingsProvider.customDownloadPath != null &&
                _settingsProvider.customDownloadPath!.isNotEmpty)
            ? _settingsProvider.customDownloadPath!
            : '';
    if (effectiveSavePath.isEmpty) {
      effectiveSavePath = await _permissionService.defaultDownloadDirectory();
    }
    final taskName = name ?? (url.split('/').lastOrNull ?? 'download');
    final threads = threadCount ?? _settingsProvider.defaultThreadCount;
    final task = DownloadTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      fileName: taskName,
      url: url,
      fileSize: size ?? 0,
      downloadedBytes: 0,
      category: category ?? 'Other',
      status: scheduledAt != null
          ? DownloadStatus.paused
          : DownloadStatus.queued,
      savePath: effectiveSavePath,
      localFilePath: '$effectiveSavePath/$taskName',
      tempFilePath: '$effectiveSavePath/$taskName.dmxpart',
      threadCount: threads,
      chunks: List<double>.filled(threads, 0.0),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
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
      expectedSha256: expectedSha256,
      mirrorUrls: mirrorUrls,
      siteType: siteType,
      siteDisplayName: siteDisplayName,
      contentHint: contentHint,
      pausedByUser: false,
    );
    await _setTask(task);
    if (scheduledAt == null) pumpQueue();
    return true;
  }

  Future<List<String>> addDownloadsBatch(List<DownloadAddSpec> specs) async {
    final ids = <String>[];
    for (final s in specs) {
      await addDownload(
        url: s.url,
        name: s.name,
        category: s.category,
        size: s.size,
        savePath: s.savePath,
        threadCount: s.threadCount,
        scheduledAt: s.scheduledAt,
        torrentFiles: s.torrentFiles,
        downloadPageUrl: s.downloadPageUrl,
        mergedAudioUrl: s.mergedAudioUrl,
        audioSize: s.audioSize,
        youtubeQualityPreset: s.youtubeQualityPreset,
        torrentId: s.torrentId,
        isAppUpdate: s.isAppUpdate,
        playlistId: s.playlistId,
        playlistTitle: s.playlistTitle,
        thumbnailUrl: s.thumbnailUrl,
      );
      ids.add(_tasks.last.id);
    }
    return ids;
  }

  Future<List<String>> addBatchDownloads({
    List<DownloadAddSpec>? specs,
    List<DownloadTask>? tasks,
    String? savePath,
  }) async {
    final ids = <String>[];
    if (specs != null) {
      for (final s in specs) {
        await addDownload(
          url: s.url,
          name: s.name,
          category: s.category,
          size: s.size,
          savePath: s.savePath,
          threadCount: s.threadCount,
          scheduledAt: s.scheduledAt,
          torrentFiles: s.torrentFiles,
          downloadPageUrl: s.downloadPageUrl,
          mergedAudioUrl: s.mergedAudioUrl,
          audioSize: s.audioSize,
          youtubeQualityPreset: s.youtubeQualityPreset,
          torrentId: s.torrentId,
          isAppUpdate: s.isAppUpdate,
          playlistId: s.playlistId,
          playlistTitle: s.playlistTitle,
          thumbnailUrl: s.thumbnailUrl,
        );
        ids.add(_tasks.last.id);
      }
    }
    if (tasks != null) {
      for (final t in tasks) {
        await _setTask(t);
        ids.add(t.id);
      }
      pumpQueue();
    }
    return ids;
  }

  Future<void> startTask(String id) => _executor.dispatch(StartTask(id));

  @override
  Future<void> pauseTask(
    String id, {
    PauseReason reason = PauseReason.userRequested,
  }) async {
    final taskBeforePause = _findTask(id);
    final wasActive = taskBeforePause != null &&
        (taskBeforePause.status == DownloadStatus.downloading ||
            taskBeforePause.status == DownloadStatus.queued);

    // Publish paused before waiting for the in-flight downloader.
    if (wasActive) {
      await setTaskState(taskBeforePause.copyWith(
        status: DownloadStatus.paused,
        speed: 0,
        clearEta: true,
        pausedByUser: reason == PauseReason.userRequested,
        pauseReason: reason,
      ));
    }

    final token = _cancelTokens.remove(id);
    if (token != null && !token.isCancelled) {
      token.cancel('paused:${reason.name}');
    }
    final orchTokens = _orchestratorTokens.remove(id);
    if (orchTokens != null) {
      if (!orchTokens.video.isCancelled) {
        orchTokens.video.cancel('paused:${reason.name}');
      }
      if (!orchTokens.audio.isCancelled) {
        orchTokens.audio.cancel('paused:${reason.name}');
      }
    }
    final future = _activeFutures.remove(id);
    if (future != null) {
      try {
        await future.timeout(const Duration(seconds: 5), onTimeout: () {});
      } catch (_) {}
    }
    if (!wasActive) {
      await _applyStateChange(
        id,
        DomainDownloadState.paused,
        PauseTask(id,
            reason: reason.name,
            userInitiated: reason == PauseReason.userRequested),
        reason: reason.name,
        pausedByUser: reason == PauseReason.userRequested,
        pauseReason: reason.name,
      );
    }
  }

  @override
  Future<void> resumeTask(String id) async {
    final task = _findTask(id);
    if (task == null) return;
    final isTorrent = task.url.startsWith('magnet:') ||
        task.url.endsWith('.torrent') ||
        task.category == 'Torrent' ||
        (task.torrentFiles != null && task.torrentFiles!.isNotEmpty);
    if (task.status == DownloadStatus.completed && isTorrent) {
      await _setTask(task.copyWith(seedingEnabled: true));
      return;
    }
    await _applyStateChange(
      id,
      DomainDownloadState.queued,
      ResumeTask(id),
      pausedByUser: false,
      isCancelled: false,
    );
    _startTorrentPollingTimer();
  }

  Future<void> cancelTask(String id) async {
    _cancelTokens.remove(id)?.cancel('cancelled');
    _notifications.cancelForTask(id);
    await _applyStateChange(
      id,
      DomainDownloadState.failed,
      CancelTask(id),
      reason: 'Transfer cancelled.',
      errorMessage: 'Transfer cancelled.',
      pausedByUser: true,
      isCancelled: true,
    );
  }

  Future<void> cancelDownload(String taskId) => cancelTask(taskId);

  final Set<String> _deletingTaskIds = {};

  Future<bool> deleteTask(String id, {bool deleteFiles = false}) async {
    if (_deletingTaskIds.contains(id)) return false;
    _deletingTaskIds.add(id);
    try {
      final task = _findTask(id);
      if (task != null) {
        final torrentId = _torrentIds.remove(id);
        if (torrentId != null) {
          TorrentService.removeTorrent(
            torrentId,
            deleteFiles: deleteFiles,
            deleteResumeData: true,
          );
          _latestTorrentStats.remove(torrentId);
        }
        _cancelTokens.remove(id)?.cancel('deleted');
        _notifications.cancelForTask(id);
        if (deleteFiles) {
          await _deleteFileSafely(task.localFilePath);
          await _deleteFileSafely(task.tempFilePath);
        }
        await _databaseService.deleteTask(id);
        _tasks.removeWhere((t) => t.id == id);
        _taskIndex.remove(id);
        _speedHistories.remove(id);
        _uploadSpeedHistories.remove(id);
        _lastProgressUpdateTimes.remove(id);
        _ytLowSpeedCounts.remove(id);
        _ytThrottlingRefreshing.remove(id);
        filteredTasksDirty = true;
        notifyListeners();
        return true;
      }
      return false;
    } catch (e, st) {
      LoggingService.logger('DownloadProvider')
          .warning('Failed to delete task $id', e, st);
      return false;
    } finally {
      _deletingTaskIds.remove(id);
    }
  }

  Future<void> retryTask(String id) async {
    final task = _findTask(id);
    if (task == null) return;
    var newUrl = task.url,
        newAudioUrl = task.mergedAudioUrl,
        downloadedBytes = task.downloadedBytes;
    final msg = task.errorMessage?.toLowerCase() ?? '';
    final isCorruptionRetry = msg.contains('file changed') ||
        msg.contains('checksum') ||
        msg.contains('corrupt') ||
        msg.contains('integrity') ||
        msg.contains('unrecoverable') ||
        task.failureCategory == FailureCategory.integrityError ||
        task.failureCategory == FailureCategory.fileChanged;
    var shouldResetProgress = isCorruptionRetry;
    if (task.downloadPageUrl != null && task.youtubeQualityPreset != null) {
      try {
        final streams =
            await YoutubeService.getFreshStreams(task.downloadPageUrl!);
        if (streams != null) {
          final freshUrl = streams['url'], freshAudioUrl = streams['audioUrl'];
          if (freshUrl != null &&
              youtubeStreamIdentityChanged(task.url, freshUrl)) {
            shouldResetProgress = true;
          }
          if (freshUrl != null) newUrl = freshUrl;
          if (freshAudioUrl != null) newAudioUrl = freshAudioUrl;
        }
      } catch (_) {}
    }
    if (shouldResetProgress) {
      downloadedBytes = 0;
      await _deleteFileSafely(task.tempFilePath);
      await _deleteFileSafely('${task.tempFilePath}.dmxstate');
      await _deleteFileSafely('${task.tempFilePath}.journal');
      await _deleteFileSafely('${task.tempFilePath}.audio');
      await _deleteFileSafely('${task.tempFilePath}.audio.dmxstate');
      await _deleteFileSafely('${task.tempFilePath}.audio.journal');
    } else {
      final stateFile = File('${task.tempFilePath}.dmxstate');
      if (await stateFile.exists()) {
        try {
          final content = await stateFile.readAsString();
          downloadedBytes = calculateDownloadedFromState(
              jsonDecode(content) as Map<String, dynamic>);
        } catch (_) {
          downloadedBytes = 0;
        }
      }
    }
    await _applyStateChange(id, DomainDownloadState.queued, RetryTask(id),
        pausedByUser: false, isCancelled: false);
    final updated = _findTask(id);
    if (updated != null) {
      await _setTask(updated.copyWith(
        url: newUrl,
        mergedAudioUrl: newAudioUrl,
        downloadedBytes: downloadedBytes,
        videoStreamSize: shouldResetProgress ? 0 : updated.videoStreamSize,
        audioDownloadedBytes:
            shouldResetProgress ? 0 : updated.audioDownloadedBytes,
        chunks: shouldResetProgress
            ? List.filled(updated.threadCount, 0.0)
            : updated.chunks,
        failureCategory: null,
        clearFailureCategory: true,
        errorMessage: null,
        clearError: true,
        recoveryHint: null,
        clearRecoveryHint: true,
        speed: 0,
        clearEta: true,
      ));
    }
  }

  Future<void> clearHistoryTasks(List<String> ids) async {
    for (final id in ids) {
      await deleteTask(id);
    }
  }

  Future<void> startUpdateDownload(UpdateInfo update) async {
    final dir = await UpdateService().getUpdatesDirectory();
    await addDownload(
      url: update.downloadUrl,
      name: 'XDM_${update.latestVersion}_v${update.versionCode}.apk',
      category: 'Other',
      savePath: dir.path,
      isAppUpdate: true,
    );
  }

  void markTorrentTasksFailed(String message) {
    for (final t in _tasks) {
      final isT = t.url.startsWith('magnet:') ||
          t.url.endsWith('.torrent') ||
          t.category == 'Torrent' ||
          (t.torrentFiles != null && t.torrentFiles!.isNotEmpty);
      if (isT &&
          (t.status == DownloadStatus.downloading ||
              t.status == DownloadStatus.queued)) {
        _applyStateChange(t.id, DomainDownloadState.failed, CancelTask(t.id),
            errorMessage: message);
      }
    }
  }

  Future<void> pauseAllTasks() => mixinPauseAllTasks(notifyListeners);
  Future<void> resumeAllTasks() => mixinResumeAllTasks(notifyListeners);
  Future<void> toggleStartStopAll() => mixinToggleStartStopAll(notifyListeners);

  @override
  bool startTaskFromQueue(DownloadTask task) => _orchestrator.startTask(task);
  @override
  bool isTaskPendingStart(String taskId) =>
      _orchestrator.isTaskPendingStart(taskId);
  @override
  bool isTaskWaitingForRetry(String taskId) => _retryTimers.containsKey(taskId);
  @override
  Future<void> flushPendingProgress(String id) async {
    final task = _findTask(id);
    if (task != null && _pendingProgressUpdates.remove(id)) {
      await _databaseService.saveTask(task);
    }
  }

  @override
  int effectiveSpeedLimit() => 0;
  @override
  List<double> buildChunks(int count, int size, int bytes) => count <= 0
      ? const []
      : size <= 0
          ? List.filled(count, 0.0)
          : List.filled(count, (bytes / size).clamp(0.0, 1.0));
  @override
  ({int total, List<Map<String, dynamic>>? files}) scanExistingTorrentData(
          String p, List<Map<String, dynamic>>? f) =>
      (total: 0, files: f);
  @override
  Future<void> updateTaskUrlAndResume(String id, String url,
      {String? newAudioUrl}) async {
    final task = _findTask(id);
    if (task == null) return;
    final updated = task.copyWith(
      url: url,
      mergedAudioUrl: newAudioUrl ?? task.mergedAudioUrl,
      updatedAt: DateTime.now(),
      errorMessage: null,
    );
    await _setTask(updated);
    await resumeTask(id);
  }

  Future<void> updateTaskUrl(String id, String url, {String? newAudioUrl}) =>
      updateTaskUrlAndResume(id, url, newAudioUrl: newAudioUrl);
  @override
  void updateTelemetryWidget() {}
  @override
  void providerStartWidgetTimer() {
    _startTorrentPollingTimer();
  }

  @override
  void providerStopWidgetTimer() {
    _stopTorrentPollingTimer();
  }

  @override
  void providerNotifyListeners() => notifyListeners();
  @override
  void pushProgressTick(String id, double p, double s) {
    if (_progressNotifiers.containsKey(id)) {
      _progressNotifiers[id]!.value = p;
    }
    if (_speedNotifiers.containsKey(id)) {
      _speedNotifiers[id]!.value = s;
    }
  }

  @override
  Future<void> cleanupPartFiles(DownloadTask t,
      {bool preserveParts = false}) async {
    if (!preserveParts) await _deleteFileSafely(t.tempFilePath);
  }

  @override
  Future<void> startOverTask(
    String id,
    String url, {
    String? newAudioUrl,
    bool clearAudioUrl = false,
    bool fromError = false,
    int? newFileSize,
    int? newAudioSize,
    bool deleteTempFiles = false,
  }) async {
    final t = _findTask(id);
    if (t == null) return;
    if (deleteTempFiles) {
      await _deleteFileSafely(t.tempFilePath);
      await _deleteFileSafely('${t.tempFilePath}.dmxstate');
      await _deleteFileSafely('${t.tempFilePath}.journal');
      await _deleteFileSafely('${t.tempFilePath}.audio');
      await _deleteFileSafely('${t.tempFilePath}.audio.dmxstate');
      await _deleteFileSafely('${t.tempFilePath}.audio.journal');
    }
    final updated = t.copyWith(
      url: url,
      mergedAudioUrl: clearAudioUrl ? null : (newAudioUrl ?? t.mergedAudioUrl),
      fileSize: newFileSize ?? (deleteTempFiles ? 0 : t.fileSize),
      audioSize: newAudioSize ?? (deleteTempFiles ? 0 : t.audioSize),
      downloadedBytes: deleteTempFiles ? 0 : t.downloadedBytes,
      audioDownloadedBytes: deleteTempFiles ? 0 : t.audioDownloadedBytes,
      audioProgress: deleteTempFiles ? 0.0 : t.audioProgress,
      chunks: deleteTempFiles ? List.filled(t.threadCount, 0.0) : t.chunks,
      status: DownloadStatus.queued,
      errorMessage: null,
      updatedAt: DateTime.now(),
    );
    await _setTask(updated);
    await resumeTask(id);
  }

  @override
  void dispose() {
    _disposed = true;
    _eventSubscription?.cancel();
    _widgetUpdateTimer?.cancel();
    _torrentPollingTimer?.cancel();
    _torrentPollingTimer = null;
    _networkMonitor.dispose();
    _scheduleManager.dispose();
    _notifications.dispose();
    _orchestrator.dispose();
    _executor.dispose();
    _settingsProvider.removeListener(_onSettingsChanged);
    _taskIndex.clear();
    _ytLowSpeedCounts.clear();
    _ytThrottlingRefreshing.clear();
    for (final n in _progressNotifiers.values) {
      n.dispose();
    }
    _progressNotifiers.clear();
    for (final n in _speedNotifiers.values) {
      n.dispose();
    }
    _speedNotifiers.clear();
    super.dispose();
  }
}
