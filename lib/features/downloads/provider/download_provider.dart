import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../../../core/interfaces/i_download_engine.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/diagnostic_service.dart';
import '../../../core/services/download_engine.dart' hide DownloadCommand;
import '../../../core/services/download_journal.dart';
import '../../../core/services/download_metrics.dart';
import '../../../core/services/engine/http_transfer_job.dart'
    show HttpTransferJob;
import '../../../core/services/logging_service.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/power_monitor.dart';
import '../../../core/services/torrent_resume_store.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/services/update_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/torrent_id_resolver.dart';
import '../../settings/provider/settings_provider.dart';
import '../data/drift_task_snapshot_store.dart';
import '../domain/commands/download_commands.dart';
import '../domain/events/download_events.dart';
import '../domain/executor/task_executor.dart';
import '../models/download_add_spec.dart';
import '../models/download_task.dart';
import '../services/download_engine_adapter.dart';
import '../services/download_widget_sync.dart';
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
    _lastDownloadOnlyWhileCharging =
        _settingsProvider.downloadOnlyWhileCharging;
    PowerMonitor.isChargingNotifier.addListener(_onChargingChanged);
    _networkMonitor = NetworkMonitor(
      tasks: () => _tasks,
      torrentIds: () => _torrentIds,
      cancelTokens: () => _cancelTokens,
      activeFutures: () => _activeFutures,
      wifiOnly: () => _settingsProvider.wifiOnly,
      pauseOnCellular: () => _settingsProvider.pauseOnCellular,
      setTask: _setTask,
      pumpQueue: pumpQueue,
      onNetworkChanged: (cmd) => _executor.dispatch(cmd),
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
    // SCHED-FIX-5: route the scheduled-start callback into the coordinator so
    // a scheduled task that auto-starts posts its notification.
    _scheduleManager = ScheduleManager(
      tasks: () => _tasks,
      databaseService: _databaseService,
      isDisposed: () => _disposed,
      downloadingTasksCount: () => downloadingTasksCount,
      updateTorrentUploadLimit: updateTorrentUploadLimit,
      notifyListeners: notifyListeners,
      pumpQueue: pumpQueue,
      onScheduleFired: (id) => _executor.dispatch(ScheduleFired(id)),
      onScheduledTaskStarted: (taskName, scheduledAt) =>
          _notifications.showScheduledStarted(taskName, scheduledAt),
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
        if (_disposed || _executor.isTombstoned(updated.id)) return;
        final idx = _tasks.indexWhere((t) => t.id == updated.id);
        if (idx != -1) {
          _tasks[idx] = updated;
          _taskIndex[updated.id] = updated;
          filteredTasksDirty = true;
          safeNotify();
        }
      },
    );
    _executor = TaskExecutor(
      enginePort: _engineAdapter,
      snapshotStore: _snapshotStore,
      auditLog: _auditLog,
    );
    _eventSubscription = _executor.events.listen(_onDomainEvent);
    // FIX(C-6): Subscribe to notification action taps. Without this, the
    // pause/resume/cancel/install buttons on system notifications were
    // queued forever with no listener (NotificationCoordinator.init was
    // never called from anywhere).
    _notifications.init();
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
  // FIX-1.1: Lock all mutations in DownloadProvider
  final Lock _tasksLock = Lock();
  bool _disposed = false;
  bool _isLoadingTasks = false;
  bool _isReconciling = false;
  final Set<String> _pendingTaskOperations = {};
  String? lastError;
  Timer? _widgetUpdateTimer;
  final DownloadWidgetSync _widgetSync = DownloadWidgetSync();
  Timer? _torrentPollingTimer;

  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, ({CancelToken video, CancelToken audio})>
      _orchestratorTokens = {};
  final Map<String, Future<void>> _activeFutures = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, int> _retryCounts = {};
  final Map<String, Queue<double>> _speedHistories = {};
  final Map<String, Queue<double>> _uploadSpeedHistories = {};
  // BUG6: the per-task DB-throttle maps (lastDbSaveTimes/lastDbSaveBytes)
  // were never written and progress-only rows now flush periodically via
  // DownloadOrchestrator.flushPendingProgressToDatabase — removed.
  final Map<String, int> _lastProgressUpdateTimes = {},
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
  Map<String, int> get lastTorrentFileDiskSync => _lastTorrentFileDiskSync;
  @override
  Set<String> get pendingProgressUpdates => _pendingProgressUpdates;
  @override
  Map<String, int> get ytLowSpeedCounts => _ytLowSpeedCounts;
  @override
  Map<String, bool> get ytThrottlingRefreshing => _ytThrottlingRefreshing;
  // FIX: Orchestrator mutates these maps during _startTaskBody.
  // Returning UnmodifiableMapView causes "Cannot modify unmodifiable map"
  // in tests (download_orchestrator.dart:3460). Expose mutable for host.
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
  final Set<String> _reservedTaskIds = <String>{};

  // `currentDownloadSpeed` is provided by DownloadFilterMixin (identical
  // aggregate over providerTasks); a second definition here was a duplicate.
  int get totalDownloadedBytes =>
      _tasks.fold(0, (s, t) => s + t.downloadedBytes);

  int _lastBroadcastSpeedLimit = -1;
  int _lastBroadcastActiveCount = -1;
  void _syncEngineSpeedLimit() {
    final bps = _settingsProvider.effectiveSpeedLimitBytesPerSecond;
    final activeCount = downloadingTasksCount;
    if (bps == _lastBroadcastSpeedLimit &&
        activeCount == _lastBroadcastActiveCount) {
      return;
    }
    _lastBroadcastSpeedLimit = bps;
    _lastBroadcastActiveCount = activeCount;
    _downloadEngine.updateSpeedLimit(bps, activeCount);
  }

  bool _lastDownloadOnlyWhileCharging = false;
  final Set<String> _tasksPausedDueToCharging = {};

  void _onSettingsChanged() {
    _syncEngineSpeedLimit();
    final chargeGate = _settingsProvider.downloadOnlyWhileCharging;
    if (chargeGate != _lastDownloadOnlyWhileCharging) {
      _lastDownloadOnlyWhileCharging = chargeGate;
      _reconcileChargingState();
    }
    safeNotify();
  }

  void _onChargingChanged() {
    if (_disposed) return;
    if (!_settingsProvider.downloadOnlyWhileCharging) return;
    _reconcileChargingState();
  }

  void _reconcileChargingState() {
    if (_disposed) return;
    if (_settingsProvider.downloadOnlyWhileCharging &&
        !PowerMonitor.isCharging) {
      unawaited(_pauseForCharging());
    } else {
      unawaited(_resumeWaitingForCharging());
    }
  }

  Future<void> _pauseForCharging() async {
    if (_disposed) return;
    final active = _tasks
        .where((t) =>
            t.status == DownloadStatus.downloading ||
            t.status == DownloadStatus.queued)
        .toList();
    for (final task in active) {
      _tasksPausedDueToCharging.add(task.id);
      final token = _cancelTokens.remove(task.id);
      if (token != null && !token.isCancelled) {
        token.cancel('charging_pause');
      }
      final orchTokens = _orchestratorTokens.remove(task.id);
      if (orchTokens != null) {
        if (!orchTokens.video.isCancelled) {
          orchTokens.video.cancel('charging_pause');
        }
        if (!orchTokens.audio.isCancelled) {
          orchTokens.audio.cancel('charging_pause');
        }
      }
      final fut = _activeFutures.remove(task.id);
      if (fut != null) {
        try {
          await fut.timeout(const Duration(seconds: 5), onTimeout: () {});
        } catch (_) {}
      }
      final torrentId = _torrentIds[task.id];
      if (torrentId != null) {
        TorrentService.pauseTorrent(torrentId);
      }
      await _setTask(task.copyWith(
        status: DownloadStatus.paused,
        speed: 0,
        clearEta: true,
        errorMessage: DownloadStatusMessages.waitingCharging,
      ));
    }
  }

  Future<void> _resumeWaitingForCharging() async {
    if (_disposed) return;
    final waiting = _tasks
        .where((t) =>
            (_tasksPausedDueToCharging.contains(t.id) ||
                t.errorMessage == DownloadStatusMessages.waitingCharging) &&
            t.status == DownloadStatus.paused)
        .toList();
    var resumedAny = false;
    for (final task in waiting) {
      if (task.pausedByUser || task.pauseReason == PauseReason.user) {
        _tasksPausedDueToCharging.remove(task.id);
        continue;
      }
      await _setTask(task.copyWith(
        status: DownloadStatus.queued,
        clearError: true,
      ));
      resumedAny = true;
    }
    _tasksPausedDueToCharging.clear();
    if (resumedAny) pumpQueue();
  }

  void _onDomainEvent(DownloadEvent event) {
    _syncEngineSpeedLimit();
    filteredTasksDirty = true;
    updateTelemetryWidget();
    safeNotify();
  }

  // FIX-1.1: Lock all mutations in DownloadProvider
  Future<void> load({
    bool pauseOrphanDownloads = true,
    bool autoResume = true,
  }) async {
    if (_disposed) return;
    _isLoadingTasks = true;
    _isReconciling = true;
    safeNotify();
    try {
      await _tasksLock.synchronized(() async {
        if (_disposed) return;
        List<DownloadTask> loaded = [];
        int loadRetries = 0;
        while (true) {
          try {
            loaded = await _databaseService.loadTasks();
            break;
          } catch (e) {
            loadRetries++;
            if (loadRetries >= 3) rethrow;
            await Future.delayed(Duration(milliseconds: 200 * loadRetries));
          }
        }
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

            // H1: a durable `.dmxdone` completion marker means the worker's
            // _finalize fully finished (bytes flushed + temp renamed to final)
            // even if the process died before the DB committed `completed`.
            // This is the ONLY reconcile signal that recovers unknown-length
            // (fileSize == 0) downloads, which the size gate below structurally
            // cannot match. Consume + delete the marker here.
            final finalFilePath =
                task.localFilePath.isNotEmpty ? task.localFilePath : localPath;
            final finalFile =
                finalFilePath.isNotEmpty ? File(finalFilePath) : null;
            final doneMarker =
                tempPath.isNotEmpty ? File('$tempPath.dmxdone') : null;

            if (doneMarker != null &&
                finalFile != null &&
                await doneMarker.exists() &&
                await finalFile.exists()) {
              final actualLen = await finalFile.length();
              var markedSize = 0;
              try {
                markedSize =
                    int.tryParse((await doneMarker.readAsString()).trim()) ?? 0;
              } catch (_) {}
              reconciled = reconciled.copyWith(
                status: DownloadStatus.completed,
                downloadedBytes: actualLen,
                fileSize: task.fileSize > 0
                    ? task.fileSize
                    : (markedSize > 0 ? markedSize : actualLen),
                errorMessage: null,
              );
              try {
                await doneMarker.delete();
              } catch (_) {}
              DiagnosticService.instance.recordTelemetryAlert(
                'completion_marker_reconciled',
                taskId: task.id,
                details: 'bytes=$actualLen unknownSize=${task.fileSize == 0}',
              );
            } else if (task.fileSize > 0 &&
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
                if (!stateResult.created ||
                    stateResult.diskAdjusted ||
                    state.downloadedBytes > 0) {
                  reconciled = reconciled.copyWith(
                    downloadedBytes: state.downloadedBytes,
                    fileSize: state.totalSize > 0
                        ? state.totalSize
                        : reconciled.fileSize,
                    chunks: state.chunks.isNotEmpty
                        ? state.chunkRatios
                        : reconciled.chunks,
                  );
                  if (state.downloadedBytes > 0) {
                    DiagnosticService.instance.recordTelemetryAlert(
                      'journal_reconciled',
                      taskId: task.id,
                      details: 'bytes=${state.downloadedBytes}',
                    );
                  }
                }
              } catch (e) {
                debugPrint(
                    '[DownloadProvider] Startup reconciliation error for ${task.id}: $e');
              }
            }
          } else if (task.isTorrent && !task.isCancelled) {
            try {
              final snap =
                  await TorrentResumeStore.loadTaskReconciliationSnapshot(
                task.url,
                infoHash: task.infoHash,
              );
              if (snap != null) {
                final restoredFiles =
                    snap.files.isNotEmpty ? snap.files : task.torrentFiles;
                final restoredSize = snap.selectedTotalBytes > 0
                    ? snap.selectedTotalBytes
                    : task.fileSize;
                final rawDone =
                    snap.selectedDownloadedBytes > task.downloadedBytes
                        ? snap.selectedDownloadedBytes
                        : task.downloadedBytes;
                final restoredDone =
                    restoredSize > 0 ? rawDone.clamp(0, restoredSize) : rawDone;
                final resolvedComplete =
                    snap.isComplete && task.status != DownloadStatus.failed;
                reconciled = reconciled.copyWith(
                  fileSize: restoredSize,
                  downloadedBytes: resolvedComplete && restoredSize > 0
                      ? restoredSize
                      : restoredDone,
                  torrentFiles: restoredFiles,
                  chunks: buildChunks(
                    task.threadCount > 0 ? task.threadCount : 1,
                    restoredSize,
                    resolvedComplete && restoredSize > 0
                        ? restoredSize
                        : restoredDone,
                  ),
                  status: resolvedComplete
                      ? DownloadStatus.completed
                      : reconciled.status,
                  resumeDataSaved: snap.hasNativeResumeBlob
                      ? true
                      : reconciled.resumeDataSaved,
                  clearError: resolvedComplete,
                );
              }
            } catch (e) {
              debugPrint(
                '[DownloadProvider] Torrent reconciliation error for ${task.id}: $e',
              );
            }
          }
          if (task.status == DownloadStatus.completed) {
            // FIX(M-28 / P0-3): Reconcile completed tasks with disk and pin bytes to 100%
            final targetPath = task.localFilePath.isNotEmpty
                ? task.localFilePath
                : (task.savePath.isNotEmpty ? task.savePath : '');
            if (targetPath.isNotEmpty && !task.isTorrent) {
              final targetFile = File(targetPath);
              if (await targetFile.exists()) {
                final diskLen = await targetFile.length();
                if (diskLen > 0 &&
                    (task.fileSize <= 0 || task.downloadedBytes != diskLen)) {
                  reconciled = reconciled.copyWith(
                    downloadedBytes: diskLen,
                    fileSize: task.fileSize > 0 ? task.fileSize : diskLen,
                  );
                }
              }
            }
            if (reconciled.fileSize > 0 &&
                reconciled.downloadedBytes != reconciled.fileSize) {
              reconciled = reconciled.copyWith(
                downloadedBytes: reconciled.fileSize,
              );
            }
          }

          if (pauseOrphanDownloads &&
              reconciled.status == DownloadStatus.downloading) {
            reconciled = reconciled.copyWith(
              status: DownloadStatus.paused,
              pauseReason: PauseReason.appRestarted,
              pausedByUser: false,
              speed: 0,
              clearEta: true,
              clearStatusMessage: true,
            );
          } else if (reconciled.status != DownloadStatus.downloading &&
              reconciled.speed > 0) {
            reconciled = reconciled.copyWith(
              speed: 0,
              clearEta: true,
            );
          }

          // Step 3: DB update (Order matters; DB is updated last after journal & disk reconciliation)
          if (reconciled != task) {
            await _databaseService.saveTask(reconciled);
          }

          reconciledTasks.add(reconciled);
        }

        // Step 4: UI update (DB write complete, now expose to in-memory state & notify UI)
        if (_disposed) return;
        _tasks.clear();
        _taskIndex.clear();
        _tasks.addAll(reconciledTasks);
        for (final task in reconciledTasks) {
          _taskIndex[task.id] = task;
          _executor
              .stateMachineFor(task.id)
              .syncState(DownloadStateMachine.fromStatus(task.status));
        }
        filteredTasksDirty = true;
      });

      _scheduleManager.setReady(true);
      // FIX(C-5): ScheduleManager.start() was never invoked anywhere, so the
      // dynamic scheduling tick never ran on any platform.
      _scheduleManager.start();
      // BG-09: register the OS-level alarm dispatcher so scheduled downloads
      // also fire when the app process is killed (the in-app tick only
      // covers the foreground case).
      try {
        await ScheduleManager.initialize();
      } catch (e) {
        debugPrint('[DownloadProvider] ScheduleManager.initialize failed: $e');
      }
      // Re-register OS alarms for schedules that are still pending after a
      // restart (one-off Workmanager tasks may have been consumed).
      for (final task in _tasks) {
        if (task.status == DownloadStatus.paused &&
            !task.pausedByUser &&
            task.scheduledAt != null) {
          unawaited(ScheduleManager.scheduleAlarm(task.id, task.scheduledAt!));
        }
      }
      await _networkMonitor.ensureInitialConnectivity();
      // FIX(C-7): Start watching connectivity changes. Previously init() was
      // never invoked, so wifi-only / pause-on-cellular enforcement and
      // auto-resume on reconnect never ran. Skipped under FLUTTER_TEST to
      // avoid the real connectivity plugin in unit tests.
      if (!Platform.environment.containsKey('FLUTTER_TEST')) {
        _networkMonitor.init();
      }
      if (autoResume) {
        await _autoResumeIncomplete();
      }
      if (_settingsProvider.globalTorrentSeeding) {
        _autoResumeSeeding();
      }
      _startTorrentPollingTimer();
    } finally {
      _isLoadingTasks = false;
      _isReconciling = false;
      if (!_disposed) {
        safeNotify();
      }
    }
  }

  Future<void> _autoResumeIncomplete() async {
    for (final task in List<DownloadTask>.from(_tasks)) {
      if (task.isCancelled ||
          task.pausedByUser ||
          task.pauseReason == PauseReason.user) {
        continue;
      }
      if (task.status == DownloadStatus.downloading) {
        await resumeTask(task.id);
      } else if (task.status == DownloadStatus.paused) {
        final isWaitingWifi =
            task.errorMessage?.toLowerCase().contains('waiting for wifi') ==
                true;
        final isWaitingNet =
            task.errorMessage?.toLowerCase().contains('waiting for network') ==
                true;
        if (isWaitingWifi) {
          if (_networkMonitor.hasWifiOrEthernet) {
            await resumeTask(task.id);
          }
        } else if (isWaitingNet) {
          if (_networkMonitor.hasConnection) {
            await resumeTask(task.id);
          }
        } else if (_settingsProvider.autoStart) {
          await resumeTask(task.id);
        }
      }
    }
  }

  void _autoResumeSeeding() {
    for (final task in _tasks) {
      if (task.isTorrent &&
          task.status == DownloadStatus.completed &&
          task.seedingEnabled &&
          !task.isCancelled &&
          !task.pausedByUser &&
          task.pauseReason != PauseReason.user) {
        unawaited(startSeedingTorrent(task));
      }
    }
  }

  DownloadTask? _findTask(String id) => _taskIndex[id];

  @override
  DownloadTask? findTaskById(String id) => _taskIndex[id];
  DownloadTask? taskById(String id) => _taskIndex[id];
  bool isTaskOperationPending(String taskId) =>
      _pendingTaskOperations.contains(taskId);
  bool get isLoadingTasks => _isLoadingTasks;
  bool get isReconciling => _isReconciling;
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
          : files
              .where((f) => f['selected'] != false)
              .fold(0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0));

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
    if (!enableBackgroundTimers) return;
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

  // FIX P0-5: Guard _tasks mutation with _tasksLock to avoid data race
  // with UI/queue pump. Poll runs every 1s via Timer; without lock it
  // interleaves with _setTask/setTaskState. Notify outside lock to avoid deadlock.
  void _pollTorrentStatusAndSpeeds() {
    if (_disposed) {
      _stopTorrentPollingTimer();
      return;
    }
    if (_tasksLock.locked) return;
    unawaited(_pollUnderLock());
  }

  Future<void> _pollUnderLock() async {
    bool shouldNotify = false;
    bool shouldStop = false;
    await _tasksLock.synchronized(() async {
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
          tasksModified = true;
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

              final status = TorrentService.latestStats[torrentId];

              if (status != null) {
                final liveHash = status.infoHash.isNotEmpty
                    ? status.infoHash
                    : status.infoHashV1;
                final effectiveHash =
                    liveHash.isNotEmpty ? liveHash : task.infoHash;

                if (status.isChecking) {
                  var checkedFileSize = task.fileSize;
                  if (checkedFileSize <= 0 &&
                      status.hasMetadata &&
                      status.totalWanted > 0) {
                    checkedFileSize = status.totalWanted;
                  }
                  final checkingTask = task.copyWith(
                    torrentId: torrentId,
                    infoHash: effectiveHash,
                    fileSize: checkedFileSize,
                    speed: 0,
                    statusMessage: 'Checking files...',
                  );
                  if (checkingTask != task) {
                    _tasks[i] = checkingTask;
                    _taskIndex[task.id] = checkingTask;
                    task = checkingTask;
                    tasksModified = true;
                  }
                } else {
                  List<double>? updatedChunks;
                  final count = task.threadCount > 0 ? task.threadCount : 1;
                  if (status.piecesTotal > 0 && status.piecesHave >= 0) {
                    final overallRatio =
                        (status.piecesHave / status.piecesTotal)
                            .clamp(0.0, 1.0);
                    updatedChunks = List.filled(count, overallRatio);
                  }

                  List<Map<String, dynamic>>? updatedFiles;
                  int selectedFileDownloaded = 0;
                  int selectedFilesTotal = 0;
                  bool allSelectedLengthsKnown = false;
                  bool hasSelectedFileProgress = false;
                  if (task.torrentFiles != null &&
                      task.torrentFiles!.isNotEmpty) {
                    updatedFiles = List<Map<String, dynamic>>.from(
                      task.torrentFiles!
                          .map((f) => Map<String, dynamic>.from(f)),
                    );
                    allSelectedLengthsKnown = true;
                    var anySelected = false;
                    for (int fIdx = 0; fIdx < updatedFiles.length; fIdx++) {
                      final f = updatedFiles[fIdx];
                      final len = (f['length'] as num?)?.toInt() ??
                          (f['size'] as num?)?.toInt() ??
                          0;
                      int dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
                      if (fIdx < status.filePriorities.length &&
                          status.filePriorities[fIdx] >= 0) {
                        final prio = status.filePriorities[fIdx];
                        f['priority'] = prio;
                        f['selected'] = prio > 0;
                      }
                      final selected = (f['selected'] as bool?) ?? true;
                      final priority = (f['priority'] as num?)?.toInt() ?? 4;
                      final isSel = selected && priority > 0;
                      if (fIdx < status.fileProgress.length &&
                          status.fileProgress[fIdx] >= 0) {
                        dl = status.fileProgress[fIdx];
                        if (len > 0 && dl > len) dl = len;
                        f['downloadedBytes'] = dl;
                        f['progressEstimated'] = false;
                        if (isSel) {
                          selectedFileDownloaded += dl;
                          hasSelectedFileProgress = true;
                        }
                      }
                      final bool lengthKnown =
                          len > 0 || f['lengthKnown'] == true;
                      if (isSel) {
                        anySelected = true;
                        selectedFilesTotal += len;
                        if (!lengthKnown) {
                          allSelectedLengthsKnown = false;
                        }
                      }
                      final bool isComp = lengthKnown &&
                          ((dl >= len) || f['isComplete'] == true);
                      f['isComplete'] = isComp;
                      f['progress'] = len > 0
                          ? (dl / len).clamp(0.0, 1.0)
                          : (isComp ? 1.0 : 0.0);
                    }
                    if (!anySelected) {
                      allSelectedLengthsKnown = false;
                    }
                  }

                  final int newFileSize;
                  if (updatedFiles != null &&
                      updatedFiles.isNotEmpty &&
                      allSelectedLengthsKnown &&
                      selectedFilesTotal > 0) {
                    newFileSize = selectedFilesTotal;
                  } else if (status.hasMetadata && status.totalWanted > 0) {
                    newFileSize = status.totalWanted;
                  } else {
                    newFileSize = task.fileSize;
                  }

                  int resolvedDone;
                  if (isCompleted && newFileSize > 0) {
                    resolvedDone = newFileSize;
                  } else if (status.totalWantedDone > 0) {
                    resolvedDone = status.totalWantedDone;
                  } else if (hasSelectedFileProgress &&
                      selectedFileDownloaded > 0) {
                    resolvedDone = selectedFileDownloaded;
                  } else if (status.progress <= 0 && task.downloadedBytes > 0) {
                    resolvedDone = task.downloadedBytes;
                  } else {
                    resolvedDone = 0;
                  }
                  if (newFileSize > 0 && resolvedDone > newFileSize) {
                    resolvedDone = newFileSize;
                  }

                  final clearCheckMsg =
                      task.statusMessage == 'Checking files...';
                  final updatedTask = task.copyWith(
                    torrentId: torrentId,
                    infoHash: effectiveHash,
                    fileSize: newFileSize,
                    downloadedBytes: resolvedDone,
                    uploadedBytes: status.totalPayloadUpload > 0
                        ? status.totalPayloadUpload
                        : task.uploadedBytes,
                    speed: isDownloading
                        ? status.downloadRate.toDouble()
                        : (isSeeding
                            ? status.uploadRate.toDouble()
                            : task.speed),
                    completedPieces: status.piecesHave > 0
                        ? status.piecesHave
                        : task.completedPieces,
                    totalPieces: status.piecesTotal > 0
                        ? status.piecesTotal
                        : task.totalPieces,
                    chunks: updatedChunks ?? task.chunks,
                    torrentFiles: updatedFiles ?? task.torrentFiles,
                    clearStatusMessage: clearCheckMsg,
                  );

                  if (updatedTask != task) {
                    _tasks[i] = updatedTask;
                    _taskIndex[task.id] = updatedTask;
                    task = updatedTask;
                    tasksModified = true;
                  }
                }
              }

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

      if (tasksModified) filteredTasksDirty = true;
      shouldNotify = tasksModified;
      shouldStop = !hasActiveTorrents && !hasActiveDownloads;
    });
    if (shouldNotify) safeNotify();
    if (shouldStop) _stopTorrentPollingTimer();
  }

  // FIX-1.1: Lock all mutations in DownloadProvider
  Future<void> addTask(DownloadTask task) async {
    if (_disposed) return;
    await _setTask(task);
  }

  // FIX P0-5: Do not notify while holding _tasksLock — listeners may
  // re-enter the provider and deadlock. Notify after releasing lock.
  Future<void> _setTask(DownloadTask task) async {
    if (_executor.isTombstoned(task.id)) return;
    bool shouldNotify = false;
    await _tasksLock.synchronized(() async {
      if (_disposed || _executor.isTombstoned(task.id)) return;
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
      shouldNotify = true;
    });
    if (shouldNotify) safeNotify();
  }

  @override
  Future<void> setTaskState(DownloadTask task) async {
    if (_executor.isTombstoned(task.id)) return;
    bool shouldNotify = false;
    await _tasksLock.synchronized(() async {
      if (_disposed || _executor.isTombstoned(task.id)) return;
      final existing = _findTask(task.id);
      if (existing != null) {
        if (existing.pausedByUser &&
            task.status == DownloadStatus.downloading) {
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
      final hasMetadataTransition = existing != null &&
          (existing.fileSize != task.fileSize ||
              existing.fileName != task.fileName ||
              existing.infoHash != task.infoHash ||
              (existing.torrentFiles?.length ?? 0) !=
                  (task.torrentFiles?.length ?? 0));
      final isProgressOnly = existing != null &&
          !hasMetadataTransition &&
          existing.status == task.status &&
          existing.status == DownloadStatus.downloading &&
          existing.downloadedBytes != task.downloadedBytes;
      final idx = _tasks.indexWhere((t) => t.id == task.id);
      if (idx != -1) {
        _tasks[idx] = task;
      } else if (!_executor.isTombstoned(task.id)) {
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
      shouldNotify = true;
    });
    if (shouldNotify) safeNotify();
  }

  Future<void> updateTask(DownloadTask task) async {
    if (_disposed) return;
    await setTaskState(task);
  }

  Future<void> restoreTask(DownloadTask task) async {
    if (_disposed) return;
    await _setTask(task);
  }

  // FIX-1.1: Lock all mutations in DownloadProvider
  @override
  Future<void> updateTasksBulk(
    List<DownloadTask> updates, {
    DatabaseService? providerDatabaseService,
    bool Function()? getFilteredTasksDirty,
    void Function(bool)? setFilteredTasksDirty,
  }) =>
      _tasksLock.synchronized(() async {
        if (_disposed || updates.isEmpty) return;
        for (final t in updates) {
          final idx = _tasks.indexWhere((x) => x.id == t.id);
          if (idx != -1) _tasks[idx] = t;
          _taskIndex[t.id] = t;
        }
        filteredTasksDirty = true;
        setFilteredTasksDirty?.call(true);
        final db = providerDatabaseService ?? _databaseService;
        await db.saveTasks(updates);
        safeNotify();
      });

  // FIX-1.1: Lock all mutations in DownloadProvider.
  // FIX(seeding): mirror the DownloadTorrentMixin implementation (torrent
  // resume/pause lifecycle, upload-limit recompute, widget timer) while keeping
  // the lock and _taskIndex bookkeeping the old override relied on.
  @override
  Future<void> updateTaskSeeding(
    String taskId, {
    bool? enabled,
    bool? limited,
    int? limitKbps,
  }) =>
      _tasksLock.synchronized(() async {
        if (_disposed) return;
        final index = _tasks.indexWhere((t) => t.id == taskId);
        if (index == -1) return;

        final oldTask = _tasks[index];
        final newEnabled = enabled ?? oldTask.seedingEnabled;

        final updatedTask = oldTask.copyWith(
          seedingEnabled: newEnabled,
          seedingLimited: limited,
          seedingLimitKbps: limitKbps,
          speed: newEnabled ? oldTask.speed : 0,
        );
        _tasks[index] = updatedTask;
        _taskIndex[taskId] = updatedTask;
        filteredTasksDirty = true;
        await _databaseService.saveTask(updatedTask);

        if (oldTask.isTorrent) {
          final torrentId =
              TorrentIdResolver.resolve(oldTask, providerMap: _torrentIds);
          if (newEnabled) {
            if (torrentId != null) {
              TorrentService.resumeTorrent(torrentId);
            } else {
              unawaited(startSeedingTorrent(updatedTask));
            }
          } else {
            // Only pause the torrent session once the download has finished;
            // never remove the handle so seeding can be resumed later.
            if (torrentId != null &&
                oldTask.status == DownloadStatus.completed) {
              await TorrentService.pauseTorrent(torrentId);
            }
            final updatedIdx = _tasks.indexWhere((t) => t.id == taskId);
            if (updatedIdx != -1) {
              final t = _tasks[updatedIdx];
              if (t.status == DownloadStatus.completed &&
                  t.fileSize > 0 &&
                  t.downloadedBytes < t.fileSize) {
                final snapped = t.copyWith(
                  downloadedBytes: t.fileSize,
                  chunks: List<double>.filled(t.threadCount, 1.0),
                );
                _tasks[updatedIdx] = snapped;
                _taskIndex[taskId] = snapped;
                await _databaseService.saveTask(snapped);
              }
            }
          }
        }

        updateActualTorrentUploadLimit();
        safeNotify();
        providerStartWidgetTimer();
      });

  Future<void> _deleteFileSafely(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        return;
      }
      final dir = Directory(path);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
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
    return _tasksLock.synchronized(() async {
      if (_disposed) return;
      final task = _findTask(id);
      if (task == null) return;
      final fromState = DownloadStateMachine.fromStatus(task.status);
      DownloadStateMachine(taskId: id, initialState: fromState)
          .transition(toState, reason: reason ?? errorMessage);
      _executor.stateMachineFor(id, initialState: fromState).syncState(toState);
      await _snapshotStore.onTaskStateChanged(
        id,
        fromState,
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
        safeNotify();
      }
      pumpQueue();
    });
  }

  Future<void> markCompletedFileMissing(String taskId) => _applyStateChange(
        taskId,
        DomainDownloadState.failed,
        CancelTask(taskId),
        errorMessage: 'File missing',
      );

  Future<void> updateTaskThreadCount(String id, int threadCount) async {
    if (_disposed) return;
    final task = _findTask(id);
    if (task == null) return;
    final isZeroProgress = task.downloadedBytes == 0;
    if (!isZeroProgress) {
      await _deleteFileSafely(task.tempFilePath);
      await _deleteFileSafely('${task.tempFilePath}.dmxstate');
      await _deleteFileSafely(
          StateStore.pathFor(task.tempFilePath, taskId: task.id));
      await _deleteFileSafely('${task.tempFilePath}.journal');
    }
    await _setTask(task.copyWith(
      threadCount: threadCount,
      chunks: List<double>.filled(threadCount, 0.0),
      downloadedBytes: isZeroProgress ? task.downloadedBytes : 0,
      status: isZeroProgress ? task.status : DownloadStatus.paused,
    ));
  }

  Future<void> updateTaskSpeedLimit(String id, int limitKbps) async {
    if (_disposed) return;
    final task = _findTask(id);
    if (task != null) {
      await _setTask(task.copyWith(speedLimitKbps: limitKbps));
    }
  }

  // FIX P0-2: Remove outer non-reentrant lock — inner deleteTask/resumeTask/pauseTask
  // already hold _tasksLock. Outer synchronized caused deadlock (Lock not re-entrant).
  Future<void> deleteMultipleTasks(List<String> ids,
      {bool deleteFiles = false}) async {
    if (_disposed) return;
    for (final id in ids) {
      await deleteTask(id, deleteFiles: deleteFiles);
    }
  }

  Future<void> resumeMultipleTasks(List<String> ids) async {
    if (_disposed) return;
    for (final id in ids) {
      await resumeTask(id);
    }
  }

  Future<void> pauseMultipleTasks(List<String> ids) async {
    if (_disposed) return;
    for (final id in ids) {
      await pauseTask(id);
    }
  }

  Future<void> changeCategoryForMultipleTasks(
      List<String> ids, String category) async {
    if (_disposed) return;
    for (final id in ids) {
      final t = _findTask(id);
      if (t != null) await _setTask(t.copyWith(category: category));
    }
  }

  Future<String?> addDownload({
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
    String? customId,
    String? authUsername,
    String? authPassword,
    Map<String, String>? customHeaders,
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
    final rawName =
        name ?? (url.split('?').first.split('/').lastOrNull ?? 'download');
    final sanitizedName = sanitizeFileName(rawName);
    var uniqueName = sanitizedName;
    int counter = 1;
    final ext = p.extension(sanitizedName);
    final base = p.basenameWithoutExtension(sanitizedName);
    while (_tasks
        .any((t) => t.localFilePath == '$effectiveSavePath/$uniqueName')) {
      uniqueName = '$base ($counter)$ext';
      counter++;
    }

    final threads = threadCount ?? _settingsProvider.defaultThreadCount;
    String newTaskId = customId ?? const Uuid().v4();
    while (_tasks.any((t) => t.id == newTaskId) ||
        _reservedTaskIds.contains(newTaskId)) {
      newTaskId = const Uuid().v4();
    }
    _reservedTaskIds.add(newTaskId);
    final task = DownloadTask(
      id: newTaskId,
      fileName: uniqueName,
      url: url,
      fileSize: size ?? 0,
      downloadedBytes: 0,
      category: category ?? 'Other',
      status:
          scheduledAt != null ? DownloadStatus.paused : DownloadStatus.queued,
      savePath: effectiveSavePath,
      localFilePath: '$effectiveSavePath/$uniqueName',
      tempFilePath: '$effectiveSavePath/$uniqueName.dmxpart',
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
      authUsername: authUsername,
      authPassword: authPassword,
      customHeaders: customHeaders,
      pausedByUser: false,
    );
    await _setTask(task);
    if (scheduledAt != null) {
      // BG-09: mirror the schedule as an OS alarm so it fires when killed.
      unawaited(ScheduleManager.scheduleAlarm(newTaskId, scheduledAt));
    }
    if (scheduledAt == null) pumpQueue();
    return newTaskId;
  }

  Future<List<String>> addDownloadsBatch(List<DownloadAddSpec> specs) async {
    final ids = <String>[];
    for (final s in specs) {
      final id = await addDownload(
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
      if (id != null) ids.add(id);
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
        final id = await addDownload(
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
        if (id != null) ids.add(id);
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

  Future<void> startTask(String id) async {
    if (_disposed) return;
    final task = _findTask(id);
    if (task != null &&
        (task.status == DownloadStatus.paused ||
            task.status == DownloadStatus.failed)) {
      await resumeTask(id);
      return;
    }
    await _executor.dispatch(StartTask(id));
  }

  @override
  Future<void> pauseTask(
    String id, {
    PauseReason reason = PauseReason.userRequested,
  }) async {
    if (_disposed) return;
    final taskBeforePause = _findTask(id);
    final wasActive = taskBeforePause != null &&
        (taskBeforePause.status == DownloadStatus.downloading ||
            taskBeforePause.status == DownloadStatus.queued);

    // BUG-6 & BUG-16: Cancel the worker tokens and await the worker future
    // first so the worker isolate flushes buffers to disk and saves durable state.
    // BUG7: cancel any pending auto-retry timer so the pause takes effect
    // immediately and a manual retry inside the timer window isn't silently
    // swallowed by the queue pump's waiting-for-retry filter.
    _retryTimers.remove(id)?.cancel();

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

    await flushPendingProgress(id);
    final liveToPause = _findTask(id);
    if (liveToPause != null && liveToPause.status == DownloadStatus.completed) {
      if (liveToPause.isTorrent && liveToPause.seedingEnabled) {
        await updateTaskSeeding(id, enabled: false);
      }
      _executor.stateMachineFor(id).syncState(DomainDownloadState.completed);
      updateTelemetryWidget();
      return;
    }
    TransferState? durableState;
    if (liveToPause != null &&
        !liveToPause.isTorrent &&
        !liveToPause.hasMergedAudio &&
        liveToPause.tempFilePath.isNotEmpty) {
      durableState =
          await StateStore.load(liveToPause.tempFilePath, taskId: id);
      if (durableState == null &&
          !await File(liveToPause.tempFilePath).exists() &&
          liveToPause.localFilePath.isNotEmpty &&
          liveToPause.fileSize > 0) {
        final finalFile = File(liveToPause.localFilePath);
        if (await finalFile.exists()) {
          final finalLen = await finalFile.length();
          if (finalLen >= liveToPause.fileSize) {
            await setTaskState(liveToPause.copyWith(
              status: DownloadStatus.completed,
              fileSize: finalLen,
              downloadedBytes: finalLen,
              chunks: List<double>.filled(liveToPause.threadCount, 1.0),
              speed: 0,
              clearEta: true,
              clearError: true,
              clearStatusMessage: true,
              pausedByUser: false,
              isCancelled: false,
            ));
            _executor
                .stateMachineFor(id)
                .syncState(DomainDownloadState.completed);
            updateTelemetryWidget();
            return;
          }
        }
      }
    }

    if (liveToPause != null && (wasActive || durableState != null)) {
      await setTaskState(liveToPause.copyWith(
        status: DownloadStatus.paused,
        downloadedBytes:
            durableState?.downloadedBytes ?? liveToPause.downloadedBytes,
        fileSize: (durableState != null && durableState.totalSize > 0)
            ? durableState.totalSize
            : liveToPause.fileSize,
        chunks: (durableState != null && durableState.chunks.isNotEmpty)
            ? durableState.chunkRatios
            : liveToPause.chunks,
        speed: 0,
        clearEta: true,
        pausedByUser: reason == PauseReason.userRequested,
        pauseReason: reason,
        isCancelled: false,
      ));
      _executor.stateMachineFor(id).syncState(DomainDownloadState.paused);
    } else {
      await _applyStateChange(
        id,
        DomainDownloadState.paused,
        PauseTask(id,
            reason: reason.name,
            userInitiated: reason == PauseReason.userRequested),
        pausedByUser: reason == PauseReason.userRequested,
        pauseReason: reason.name,
        isCancelled: false,
      );
    }
    updateTelemetryWidget();
  }

  @override
  Future<void> resumeTask(String id) async {
    if (_disposed) return;
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
    // BUG-14 & BUG-6: verify state file or temp file before queueing
    TransferState? durableState;
    if (!isTorrent && task.tempFilePath.isNotEmpty) {
      if (!task.hasMergedAudio) {
        durableState = await StateStore.load(task.tempFilePath, taskId: id);
      }
      final stateFile =
          File(StateStore.pathFor(task.tempFilePath, taskId: task.id));
      final legacyState = File('${task.tempFilePath}.dmxstate');
      final tempFile = File(task.tempFilePath);
      if (task.downloadedBytes > 0 &&
          !stateFile.existsSync() &&
          !legacyState.existsSync() &&
          !tempFile.existsSync()) {
        debugPrint(
          '[DMX] State file and temp file missing for task $id on resume. Download will restart from 0.',
        );
      }
    }
    if (durableState != null ||
        task.failureCategory != null ||
        task.recoveryHint != null) {
      await _setTask(task.copyWith(
        downloadedBytes: durableState?.downloadedBytes ?? task.downloadedBytes,
        fileSize: (durableState != null && durableState.totalSize > 0)
            ? durableState.totalSize
            : task.fileSize,
        chunks: (durableState != null && durableState.chunks.isNotEmpty)
            ? durableState.chunkRatios
            : task.chunks,
        clearError: true,
        clearFailureCategory: true,
        clearRecoveryHint: true,
        clearStatusMessage: true,
        pausedByUser: false,
        isCancelled: false,
      ));
    }
    await _applyStateChange(
      id,
      DomainDownloadState.queued,
      ResumeTask(id),
      pausedByUser: false,
      pauseReason: '',
      isCancelled: false,
    );
    _startTorrentPollingTimer();
    updateTelemetryWidget();
  }

  Future<void> stopTask(String id, {bool deletePartialFiles = false}) async {
    if (_disposed) return;
    _retryTimers.remove(id)?.cancel();
    _retryCounts.remove(id);
    _pendingProgressUpdates.remove(id);

    final token = _cancelTokens.remove(id);
    if (token != null && !token.isCancelled) {
      token.cancel('stopped');
    }
    final orchTokens = _orchestratorTokens.remove(id);
    if (orchTokens != null) {
      if (!orchTokens.video.isCancelled) {
        orchTokens.video.cancel('stopped');
      }
      if (!orchTokens.audio.isCancelled) {
        orchTokens.audio.cancel('stopped');
      }
    }
    final future = _activeFutures.remove(id);
    if (future != null) {
      try {
        await future.timeout(const Duration(seconds: 5), onTimeout: () {});
      } catch (_) {}
    }

    _notifications.cancelForTask(id);
    unawaited(ScheduleManager.cancelAlarm(id));
    _orchestrator.cleanupTaskState(id);

    final live = _findTask(id);
    if (live == null) return;
    if (live.isTorrent) {
      final tid = _torrentIds.remove(id) ?? live.torrentId;
      var latestBytes = live.downloadedBytes;
      var latestSize = live.fileSize;
      final latestFiles = live.torrentFiles;

      if (deletePartialFiles) {
        if (tid != null && tid >= 0 && TorrentService.isTorrentAlive(tid)) {
          try {
            TorrentService.removeTorrent(
              tid,
              deleteFiles: true,
              deleteResumeData: true,
            );
          } catch (_) {}
        } else if (live.savePath.isNotEmpty) {
          // Safely remove only known payload files/root folder, never the parent savePath.
          if (live.torrentFiles != null && live.torrentFiles!.isNotEmpty) {
            for (final f in live.torrentFiles!) {
              final rel = (f['name'] as String?) ?? '';
              if (rel.isEmpty) continue;
              final normalizedRel = rel.replaceAll('/', Platform.pathSeparator);
              await _deleteFileSafely(
                '${live.savePath}${Platform.pathSeparator}$normalizedRel',
              );
              if (live.fileName.isNotEmpty) {
                await _deleteFileSafely(
                  '${live.savePath}${Platform.pathSeparator}${live.fileName}${Platform.pathSeparator}$normalizedRel',
                );
              }
            }
          } else if (live.localFilePath.isNotEmpty &&
              live.localFilePath != live.savePath) {
            await _deleteFileSafely(live.localFilePath);
          }
          if (live.fileName.isNotEmpty &&
              live.torrentFiles != null &&
              live.torrentFiles!.length > 1) {
            try {
              final rootDir = Directory(
                '${live.savePath}${Platform.pathSeparator}${live.fileName}',
              );
              if (await rootDir.exists()) {
                await rootDir.delete(recursive: true);
              }
            } catch (_) {}
          }
        }
        await TorrentResumeStore.deleteResumeDataForSource(
          live.url,
          infoHash: live.infoHash,
        );
        final resetFiles = live.torrentFiles
            ?.map((f) => {
                  ...f,
                  'downloadedBytes': 0,
                  'progress': 0.0,
                  'isComplete': false,
                })
            .toList();
        await _setTask(live.copyWith(
          status: DownloadStatus.paused,
          downloadedBytes: 0,
          torrentFiles: resetFiles,
          chunks: List<double>.filled(
            live.threadCount > 0 ? live.threadCount : 1,
            0.0,
          ),
          clearTorrentId: true,
          resumeDataSaved: false,
          pausedByUser: true,
          pauseReason: PauseReason.userRequested,
          isCancelled: false,
          speed: 0,
          clearEta: true,
          clearError: true,
          clearStatusMessage: true,
        ));
      } else {
        if (tid != null && tid >= 0 && TorrentService.isTorrentAlive(tid)) {
          try {
            await TorrentService.pauseTorrent(tid);
          } catch (_) {}
          try {
            await TorrentService.saveResumeData(tid);
          } catch (_) {}
          final st = TorrentService.latestStats[tid];
          if (st != null && !st.isChecking) {
            if (st.hasMetadata && st.totalWanted > 0) {
              latestSize = st.totalWanted;
            }
            if (st.totalWantedDone > 0) {
              latestBytes = latestSize > 0
                  ? st.totalWantedDone.clamp(0, latestSize)
                  : st.totalWantedDone;
            }
          }
          try {
            TorrentService.removeTorrent(
              tid,
              deleteFiles: false,
              deleteResumeData: false,
            );
          } catch (_) {}
        }
        await _setTask(live.copyWith(
          status: DownloadStatus.paused,
          downloadedBytes: latestBytes,
          fileSize: latestSize,
          torrentFiles: latestFiles,
          clearTorrentId: true,
          resumeDataSaved: true,
          pausedByUser: true,
          pauseReason: PauseReason.userRequested,
          isCancelled: false,
          speed: 0,
          clearEta: true,
          clearStatusMessage: true,
        ));
      }
      _executor.stateMachineFor(id).syncState(DomainDownloadState.paused);
      pumpQueue();
      updateTelemetryWidget();
      return;
    }
    if (!deletePartialFiles &&
        !live.isTorrent &&
        live.status == DownloadStatus.completed) {
      _executor.stateMachineFor(id).syncState(DomainDownloadState.completed);
      pumpQueue();
      updateTelemetryWidget();
      return;
    }

    if (deletePartialFiles) {
      await _deleteFileSafely(live.tempFilePath);
      await _deleteFileSafely(
          StateStore.pathFor(live.tempFilePath, taskId: id));
      await _deleteFileSafely('${live.tempFilePath}.dmxstate');
      await _deleteFileSafely('${live.tempFilePath}.journal');
      await _deleteFileSafely(
          StateStore.journalPathFor(live.tempFilePath, taskId: id));
      await _deleteFileSafely('${live.tempFilePath}.audio');
      await _deleteFileSafely(
          StateStore.pathFor('${live.tempFilePath}.audio', taskId: id));
      await _deleteFileSafely('${live.tempFilePath}.audio.dmxstate');
      await _deleteFileSafely('${live.tempFilePath}.audio.journal');
      await _setTask(live.copyWith(
        status: DownloadStatus.paused,
        downloadedBytes: 0,
        chunks: List<double>.filled(live.threadCount, 0.0),
        pausedByUser: true,
        pauseReason: PauseReason.userRequested,
        isCancelled: false,
        speed: 0,
        clearEta: true,
        clearError: true,
        clearStatusMessage: true,
      ));
    } else {
      TransferState? durableState;
      if (!live.isTorrent &&
          !live.hasMergedAudio &&
          live.tempFilePath.isNotEmpty) {
        durableState = await StateStore.load(live.tempFilePath, taskId: id);
      }
      await _setTask(live.copyWith(
        status: DownloadStatus.paused,
        downloadedBytes: durableState?.downloadedBytes ?? live.downloadedBytes,
        fileSize: (durableState != null && durableState.totalSize > 0)
            ? durableState.totalSize
            : live.fileSize,
        chunks: (durableState != null && durableState.chunks.isNotEmpty)
            ? durableState.chunkRatios
            : live.chunks,
        pausedByUser: true,
        pauseReason: PauseReason.userRequested,
        isCancelled: false,
        speed: 0,
        clearEta: true,
        clearStatusMessage: true,
      ));
    }
    _executor.stateMachineFor(id).syncState(DomainDownloadState.paused);
    pumpQueue();
    updateTelemetryWidget();
  }

  Future<void> cancelTask(String id) async {
    if (_disposed) return;
    // BUG7: cancel any pending auto-retry timer so a manual retry issued
    // right after a cancel isn't silently swallowed by the queue pump's
    // waiting-for-retry filter.
    _retryTimers.remove(id)?.cancel();
    _retryCounts.remove(id);
    _pendingProgressUpdates.remove(id);
    final token = _cancelTokens.remove(id);
    if (token != null && !token.isCancelled) {
      token.cancel('cancelled');
    }
    final orchTokens = _orchestratorTokens.remove(id);
    if (orchTokens != null) {
      if (!orchTokens.video.isCancelled) {
        orchTokens.video.cancel('cancelled');
      }
      if (!orchTokens.audio.isCancelled) {
        orchTokens.audio.cancel('cancelled');
      }
    }
    final future = _activeFutures.remove(id);
    if (future != null) {
      try {
        await future.timeout(const Duration(seconds: 5), onTimeout: () {});
      } catch (_) {}
    }
    _notifications.cancelForTask(id);
    // BG-09: a cancelled task must not leave a pending OS schedule alarm.
    unawaited(ScheduleManager.cancelAlarm(id));
    final live = _findTask(id);
    if (live != null &&
        !live.isTorrent &&
        !live.hasMergedAudio &&
        live.tempFilePath.isNotEmpty) {
      final durableState = await StateStore.load(live.tempFilePath, taskId: id);
      if (durableState != null) {
        await _setTask(live.copyWith(
          downloadedBytes: durableState.downloadedBytes,
          fileSize: durableState.totalSize > 0
              ? durableState.totalSize
              : live.fileSize,
          chunks: durableState.chunks.isNotEmpty
              ? durableState.chunkRatios
              : live.chunks,
          speed: 0,
          clearEta: true,
        ));
      }
    }
    await _applyStateChange(
      id,
      DomainDownloadState.failed,
      CancelTask(id),
      reason: 'Transfer cancelled.',
      errorMessage: 'Transfer cancelled.',
      pausedByUser: true,
      isCancelled: true,
    );
    _orchestrator.cleanupTaskState(id);
    updateTelemetryWidget();
  }

  Future<void> cancelDownload(String taskId) => cancelTask(taskId);

  final Set<String> _deletingTaskIds = {};

  Future<bool> deleteTask(String id, {bool deleteFiles = false}) async {
    return _tasksLock.synchronized(() async {
      if (_disposed) return false;
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
          forgetTorrentSwarm(id);
          final duo = _orchestratorTokens.remove(id);
          duo?.video.cancel('deleted');
          duo?.audio.cancel('deleted');
          _cancelTokens.remove(id)?.cancel('deleted');
          _retryTimers.remove(id)?.cancel();
          final activeFuture = _activeFutures.remove(id);
          if (activeFuture != null) {
            try {
              await activeFuture.timeout(const Duration(seconds: 3));
            } catch (_) {}
          }
          _notifications.cancelForTask(id);
          // BG-09: drop any pending OS schedule alarm for the deleted task.
          unawaited(ScheduleManager.cancelAlarm(id));
          if (deleteFiles) {
            await _deleteFileSafely(task.localFilePath);
            final tempPath = task.tempFilePath;
            if (tempPath.isNotEmpty) {
              await _deleteFileSafely(tempPath);
              await _deleteFileSafely('$tempPath.dmx_journal');
              await _deleteFileSafely('$tempPath.dmx_meta');
              await _deleteFileSafely('$tempPath.parts');
              await _deleteFileSafely('$tempPath.journal');
              await _deleteFileSafely(
                  StateStore.pathFor(tempPath, taskId: task.id));
              await _deleteFileSafely('$tempPath.dmxstate');
              await _deleteFileSafely('$tempPath.audio');
              await _deleteFileSafely('$tempPath.audio.journal');
              await _deleteFileSafely(
                  StateStore.pathFor('$tempPath.audio', taskId: task.id));
              await _deleteFileSafely('$tempPath.audio.dmxstate');
              await deleteDownloadParts(tempPath);
              await DownloadJournal.deleteJournalFor(tempPath);
            }
            if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
              for (final f in task.torrentFiles!) {
                final relPath = f['path']?.toString();
                if (relPath != null && relPath.isNotEmpty) {
                  final fullPath = p.join(task.savePath, relPath);
                  await _deleteFileSafely(fullPath);
                }
              }
            }
          }
          await _databaseService.deleteTask(id);
          _tasks.removeWhere((t) => t.id == id);
          _taskIndex.remove(id);
          _retryCounts.remove(id);
          _speedHistories.remove(id);
          _uploadSpeedHistories.remove(id);
          _lastProgressUpdateTimes.remove(id);
          _lastTorrentFileDiskSync.remove(id);
          _pendingProgressUpdates.remove(id);
          _ytLowSpeedCounts.remove(id);
          _ytThrottlingRefreshing.remove(id);
          effectiveThreadOverrides.remove(id);
          _resumeRejectionRestarts.remove(id);
          _downloadMetrics.remove(id);
          _reservedTaskIds.remove(id);
          disposeTaskNotifier(id);
          _orchestrator.cleanupTaskState(id);
          filteredTasksDirty = true;
          safeNotify();
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
    });
  }

  Future<void> retryTask(String id) async {
    if (_disposed) return;
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
      await _deleteFileSafely(
          StateStore.pathFor(task.tempFilePath, taskId: task.id));
      await _deleteFileSafely('${task.tempFilePath}.dmxstate');
      await _deleteFileSafely('${task.tempFilePath}.journal');
      await _deleteFileSafely('${task.tempFilePath}.audio');
      await _deleteFileSafely(
          StateStore.pathFor('${task.tempFilePath}.audio', taskId: task.id));
      await _deleteFileSafely('${task.tempFilePath}.audio.dmxstate');
      await _deleteFileSafely('${task.tempFilePath}.audio.journal');
    } else {
      final state = await StateStore.load(task.tempFilePath, taskId: task.id);
      if (state != null) {
        downloadedBytes = state.downloadedBytes;
      }
    }
    await _applyStateChange(id, DomainDownloadState.queued, RetryTask(id),
        pausedByUser: false, pauseReason: '', isCancelled: false);
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
    if (_disposed) return;
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
    if (_disposed) return;
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

  Future<void> pauseAllTasks() async {
    if (_disposed) return;
    await mixinPauseAllTasks(notifyListeners);
  }

  Future<void> resumeAllTasks() async {
    if (_disposed) return;
    await mixinResumeAllTasks(notifyListeners);
  }

  Future<void> toggleStartStopAll() async {
    if (_disposed) return;
    await mixinToggleStartStopAll(notifyListeners);
  }

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
  int effectiveSpeedLimit() =>
      _settingsProvider.effectiveSpeedLimitBytesPerSecond;
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
    final cleanUrl = url.trim();
    if (_disposed || cleanUrl.isEmpty) return;
    final task = _findTask(id);
    if (task == null) return;

    if (task.isTorrent) {
      final oldHash = TorrentResumeStore.extractCanonicalInfoHash(
        task.url,
        infoHash: task.infoHash,
      );
      final newHash = TorrentResumeStore.extractCanonicalInfoHash(cleanUrl);
      if (oldHash != null &&
          oldHash.isNotEmpty &&
          newHash != null &&
          newHash.isNotEmpty &&
          oldHash != newHash) {
        await _setTask(task.copyWith(
          errorMessage:
              'Updated link belongs to a different torrent (info-hash mismatch). Existing partial data was preserved.',
          updatedAt: DateTime.now(),
        ));
        return;
      }

      final effectiveHash = newHash ?? oldHash;
      await TorrentResumeStore.migrateSourceKey(
        task.url,
        cleanUrl,
        infoHash: effectiveHash,
      );

      final liveTid = _torrentIds[id] ?? task.torrentId;
      if (liveTid != null &&
          liveTid >= 0 &&
          TorrentService.isTorrentAlive(liveTid)) {
        TorrentService.updateTorrentSource(liveTid, cleanUrl);
        final updated = task.copyWith(
          url: cleanUrl,
          infoHash: effectiveHash ?? task.infoHash,
          updatedAt: DateTime.now(),
          clearError: true,
          clearFailureCategory: true,
          clearRecoveryHint: true,
          clearStatusMessage: true,
          pausedByUser: false,
          isCancelled: false,
        );
        await _setTask(updated);
        if (task.status != DownloadStatus.downloading &&
            task.status != DownloadStatus.completed) {
          await resumeTask(id);
        }
        return;
      }

      final wasOrchestrated = _cancelTokens.containsKey(id) ||
          _orchestratorTokens.containsKey(id) ||
          _activeFutures.containsKey(id);
      if (wasOrchestrated) {
        await pauseTask(id, reason: PauseReason.userRequested);
      }
      final current = _findTask(id) ?? task;
      await _setTask(current.copyWith(
        url: cleanUrl,
        infoHash: effectiveHash ?? current.infoHash,
        updatedAt: DateTime.now(),
        clearError: true,
        clearFailureCategory: true,
        clearRecoveryHint: true,
        clearStatusMessage: true,
        pausedByUser: false,
        isCancelled: false,
      ));
      await resumeTask(id);
      return;
    }

    final isRunning = task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued ||
        _cancelTokens.containsKey(id) ||
        _orchestratorTokens.containsKey(id) ||
        _activeFutures.containsKey(id);
    if (isRunning) {
      await pauseTask(id, reason: PauseReason.userRequested);
    }
    final current = _findTask(id) ?? task;
    HttpTransferJob.invalidateIdentityCacheForUrl(current.url);
    HttpTransferJob.invalidateIdentityCacheForUrl(cleanUrl);
    TransferState? durableState;
    if (!current.hasMergedAudio && current.tempFilePath.isNotEmpty) {
      durableState = await StateStore.load(current.tempFilePath, taskId: id);
    }
    final updated = current.copyWith(
      url: cleanUrl,
      mergedAudioUrl: newAudioUrl ?? current.mergedAudioUrl,
      downloadedBytes: durableState?.downloadedBytes ?? current.downloadedBytes,
      fileSize: (durableState != null && durableState.totalSize > 0)
          ? durableState.totalSize
          : current.fileSize,
      chunks: (durableState != null && durableState.chunks.isNotEmpty)
          ? durableState.chunkRatios
          : current.chunks,
      updatedAt: DateTime.now(),
      clearError: true,
      clearFailureCategory: true,
      clearRecoveryHint: true,
      clearStatusMessage: true,
      pausedByUser: false,
      isCancelled: false,
    );
    await _setTask(updated);
    await resumeTask(id);
  }

  Future<void> updateTaskUrl(String id, String url, {String? newAudioUrl}) =>
      updateTaskUrlAndResume(id, url, newAudioUrl: newAudioUrl);
  @override
  void updateTelemetryWidget() {
    // Debounce: coalesce bursts of state changes into one widget push; the
    // WidgetDataBridge throttles (and dedupes payloads) further on its side.
    // Disabled with background timers (incl. FLUTTER_TEST) like the other
    // periodic timers.
    if (_disposed || !enableBackgroundTimers) return;
    _widgetUpdateTimer ??= Timer(const Duration(seconds: 2), () {
      _widgetUpdateTimer = null;
      unawaited(_widgetSync.syncDashboard(
        allTasks: List.unmodifiable(_tasks),
        speedHistories: _speedHistories,
        isOnWifi: _networkMonitor.hasWifiOrEthernet,
      ));
    });
  }

  @override
  void providerStartWidgetTimer() {
    _startTorrentPollingTimer();
  }

  @override
  void providerStopWidgetTimer() {
    _stopTorrentPollingTimer();
  }

  @override
  void updateProgressTask(DownloadTask updated) {
    if (_executor.isTombstoned(updated.id)) return;
    final idx = _tasks.indexWhere((t) => t.id == updated.id);
    if (idx != -1) {
      _tasks[idx] = updated;
    }
    _taskIndex[updated.id] = updated;
    filteredTasksDirty = true;
  }

  @override
  void safeNotify() {
    if (_disposed) return;
    if (DownloadEngine.isInBackground && PowerMonitor.screenOff) return;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void providerNotifyListeners() => safeNotify();
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
    if (_disposed) return;
    final t = _findTask(id);
    if (t == null) return;
    final isRunning = t.status == DownloadStatus.downloading ||
        t.status == DownloadStatus.queued ||
        _cancelTokens.containsKey(id);
    if (isRunning) {
      await pauseTask(id, reason: PauseReason.userRequested);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final taskNow = _findTask(id) ?? t;
    if (deleteTempFiles) {
      await _deleteFileSafely(taskNow.tempFilePath);
      await _deleteFileSafely(
          StateStore.pathFor(taskNow.tempFilePath, taskId: taskNow.id));
      await _deleteFileSafely('${taskNow.tempFilePath}.dmxstate');
      await _deleteFileSafely('${taskNow.tempFilePath}.journal');
      await _deleteFileSafely('${taskNow.tempFilePath}.audio');
      await _deleteFileSafely(StateStore.pathFor(
          '${taskNow.tempFilePath}.audio',
          taskId: taskNow.id));
      await _deleteFileSafely('${taskNow.tempFilePath}.audio.dmxstate');
      await _deleteFileSafely('${taskNow.tempFilePath}.audio.journal');
    }
    final updated = taskNow.copyWith(
      url: url,
      mergedAudioUrl:
          clearAudioUrl ? null : (newAudioUrl ?? taskNow.mergedAudioUrl),
      fileSize: newFileSize ?? (deleteTempFiles ? 0 : taskNow.fileSize),
      audioSize: newAudioSize ?? (deleteTempFiles ? 0 : taskNow.audioSize),
      downloadedBytes: deleteTempFiles ? 0 : taskNow.downloadedBytes,
      audioDownloadedBytes: deleteTempFiles ? 0 : taskNow.audioDownloadedBytes,
      audioProgress: deleteTempFiles ? 0.0 : taskNow.audioProgress,
      chunks: deleteTempFiles
          ? List.filled(taskNow.threadCount, 0.0)
          : taskNow.chunks,
      status: DownloadStatus.queued,
      errorMessage: null,
      updatedAt: DateTime.now(),
    );
    await _setTask(updated);
    await resumeTask(id);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _settingsProvider.removeListener(_onSettingsChanged);
    PowerMonitor.isChargingNotifier.removeListener(_onChargingChanged);
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _widgetUpdateTimer?.cancel();
    _widgetUpdateTimer = null;
    _torrentPollingTimer?.cancel();
    _torrentPollingTimer = null;
    for (final t in _retryTimers.values) {
      t.cancel();
    }
    _retryTimers.clear();
    _retryCounts.clear();
    _pendingProgressUpdates.clear();
    effectiveThreadOverrides.clear();
    _resumeRejectionRestarts.clear();
    _downloadMetrics.clear();
    _reservedTaskIds.clear();
    _notifications.dispose();
    _scheduleManager.dispose();
    _networkMonitor.dispose();
    _orchestrator.dispose();
    _executor.dispose();
    _taskIndex.clear();
    _ytLowSpeedCounts.clear();
    _ytThrottlingRefreshing.clear();
    _speedHistories.clear();
    _uploadSpeedHistories.clear();
    _lastProgressUpdateTimes.clear();
    _lastTorrentFileDiskSync.clear();
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
