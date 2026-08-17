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
import 'package:synchronized/synchronized.dart';

import '../../../core/di/injection.dart';
import '../../../core/services/app_lifecycle_coordinator.dart';
import '../../../core/services/background_gate.dart';
import '../../../core/services/background_service.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/diagnostic_service.dart';
import '../../../core/services/download_engine.dart';
import '../../../core/services/download_journal.dart';
import '../../../core/services/download_metrics.dart';
import '../../../core/services/engine/engine_utils.dart';
import '../../../core/services/engine/torrent_download_handler.dart';
import '../../../core/services/error_taxonomy.dart';
import '../../../core/services/frame_watchdog.dart';
import '../../../core/services/ios_background_capability.dart';
import '../../../core/services/logging_service.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/power_monitor.dart';
import '../../../core/services/site_intelligence/site_intelligence_service.dart';
import '../../../core/services/torrent_resume_store.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/services/update_service.dart';
import '../../../core/services/widget_data_bridge.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/url_utils.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_state_machine.dart';
import '../models/download_task.dart';
import '../services/download_execution_service.dart';
import '../services/download_notification_bridge.dart';
import '../services/download_queue_service.dart';
import '../services/download_task_repository.dart';
import '../services/download_widget_sync.dart';
import '../services/torrent_session_manager.dart';
import 'download_orchestrator.dart';
import 'mixins/download_backup_mixin.dart';
import 'mixins/download_filter_mixin.dart';
import 'mixins/download_queue_mixin.dart';
import 'mixins/download_torrent_mixin.dart';
import 'network_monitor.dart';
import 'notification_coordinator.dart';
import 'schedule_manager.dart';
import 'torrent_provider.dart';

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
    implements
        DownloadOrchestratorHost,
        DownloadQueueHost,
        DownloadExecutionHost {
  DownloadProvider({
    required DatabaseService databaseService,
    required SettingsProvider settingsProvider,
    DownloadEngine? downloadEngine,
    PermissionService? permissionService,
    NotificationService? notificationService,
    bool enableBackgroundTimers = true,
  })  : _databaseService = databaseService,
        _settingsProvider = settingsProvider,
        enableBackgroundTimers = enableBackgroundTimers &&
            !Platform.environment.containsKey('FLUTTER_TEST'),
        _downloadEngine = downloadEngine ??
            DownloadEngine(
              enableCleanupTimer: enableBackgroundTimers &&
                  !Platform.environment.containsKey('FLUTTER_TEST'),
            ),
        _permissionService = permissionService ?? PermissionService(),
        _notificationService = notificationService ?? NotificationService() {
    _settingsProvider.addListener(_onSettingsChanged);

    _networkMonitor = NetworkMonitor(
      tasks: () => _tasks,
      torrentIds: () => _torrentIds,
      cancelTokens: () => _cancelTokens,
      activeFutures: () => _activeFutures,
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
      onStopAll: pauseAllTasks, // Stop All = pause every active task
      onStartAll: resumeAllTasks, // Start All = resume every paused task
      onExitApp: exitApp,
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

    // Initialize modular split services
    _taskRepository = DownloadTaskRepository(databaseService: _databaseService);
    _torrentSessionManager = TorrentSessionManager();
    _notificationBridge =
        DownloadNotificationBridge(coordinator: _notifications);
    _downloadWidgetSync = DownloadWidgetSync();
    _queueService = DownloadQueueService(host: this);
    _executionService = DownloadExecutionService(host: this);

    // Subscribe lazily — torrent engine may not be initialized yet.
    if (enableBackgroundTimers) {
      _initTorrentSubscription();
    }

    AppLifecycleCoordinator.addOnResumedCallback(forceEmitAllProgress);
    BackgroundService.setActiveDownloadCountQuery(
      () => downloadingTasksCount + seedingTasksCount,
    );
  }

  /// Forces immediate emission of the latest progress for all active downloads,
  /// bypassing any background throttling intervals upon app foreground/resume.
  void forceEmitAllProgress() {
    _lastProgressUpdateTimes.clear();
    for (final task in _tasks) {
      if (task.status == DownloadStatus.downloading) {
        pushProgressTick(task.id, task.progress, task.speed);
      }
    }
    notifyListeners();
  }

  late final DownloadTaskRepository _taskRepository;
  late final TorrentSessionManager _torrentSessionManager;
  late final DownloadNotificationBridge _notificationBridge;
  late final DownloadWidgetSync _downloadWidgetSync;
  late final DownloadQueueService _queueService;
  late final DownloadExecutionService _executionService;

  DownloadTaskRepository get taskRepository => _taskRepository;
  TorrentSessionManager get torrentSessionManager => _torrentSessionManager;
  DownloadNotificationBridge get notificationBridge => _notificationBridge;
  DownloadWidgetSync get downloadWidgetSync => _downloadWidgetSync;
  DownloadQueueService get queueService => _queueService;
  DownloadExecutionService get executionService => _executionService;

  @override
  int get maxConcurrentDownloads => _settingsProvider.maxDownloads;

  @override
  bool isTaskStarting(String taskId) =>
      _orchestrator.isTaskPendingStart(taskId);

  @override
  Future<void> executeTask(String taskId) => resumeTask(taskId);

  @override
  Future<void> updateTaskOrder(List<DownloadTask> orderedTasks) async {
    _tasks.clear();
    _tasks.addAll(orderedTasks);
    await _databaseService.saveTasks(orderedTasks);
    notifyListeners();
  }

  @override
  Future<void> executeDownload(String taskId, {bool isAutoRetry = false}) =>
      resumeTask(taskId);

  @override
  Future<void> pauseDownload(String taskId) => pauseTask(taskId);

  @override
  Future<void> resumeDownload(String taskId) => resumeTask(taskId);

  @override
  Future<void> retryDownload(String taskId) => retryTask(taskId);

  @override
  Future<void> cancelDownload(String taskId) => cancelTask(taskId);

  Timer? _torrentInitTimer;

  bool _isLoadingTasks = false;
  bool get isLoadingTasks => _isLoadingTasks;

  int _revision = 0;
  int get revision => _revision;

  final Map<String, Future<void>> _inFlightTaskOps = {};
  final Map<String, DateTime> _lastTaskOpTimes = {};
  final Map<String, bool> _taskOpInProgress = {};

  // FIX-P0-01: Synchronization locks for task state mutations
  final Map<String, Lock> _taskLocks = {};
  Lock _lockFor(String id) => _taskLocks.putIfAbsent(id, () => Lock());

  // FIX-PERF-03: Frame-batched listener notification with safety against disposed bindings
  bool _notifyScheduled = false;
  void scheduleNotify() {
    if (_disposed) return;
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    try {
      final binding = WidgetsBinding.instance;
      binding.addPostFrameCallback((_) {
        _notifyScheduled = false;
        if (!_disposed) {
          try {
            notifyListeners();
          } catch (e) {
            debugPrint('[DownloadProvider] notifyListeners failed: $e');
          }
        }
      });
    } catch (e) {
      _notifyScheduled = false;
      if (!_disposed) {
        try {
          notifyListeners();
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
      }
    }
  }

  /// Returns true if a pause, resume, or retry operation is currently executing for [taskId].
  bool isTaskOperationPending(String taskId) =>
      _inFlightTaskOps.containsKey(taskId);

  Future<void> _runGuardedTaskOperation(
    String id,
    String opName,
    Future<void> Function() body,
  ) async {
    if (id.isEmpty) return;

    // Return existing in-flight future if operation is already running for this task
    final existingFuture = _inFlightTaskOps[id];
    if (existingFuture != null) {
      debugPrint(
          '[DMX Guard] $opName for $id ignored — operation already in flight.');
      return existingFuture;
    }

    // Debounce rapid calls (350ms window)
    final lastTime = _lastTaskOpTimes[id];
    if (lastTime != null &&
        DateTime.now().difference(lastTime) <
            const Duration(milliseconds: 350)) {
      debugPrint('[DMX Guard] $opName for $id ignored — debounced.');
      return;
    }

    final completer = Completer<void>();
    _inFlightTaskOps[id] = completer.future;
    _lastTaskOpTimes[id] = DateTime.now();
    scheduleNotify();

    try {
      await _lockFor(id).synchronized(() async {
        final task = _findTask(id);
        if (task == null && opName != 'delete') {
          debugPrint(
              '[DMX Guard] $opName for $id aborted — task no longer exists.');
          return;
        }
        await body();
      });
      completer.complete();
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _inFlightTaskOps.remove(id);
      scheduleNotify();
    }
  }

  int _torrentInitRetries = 0;
  static const int _maxTorrentInitRetries = 15;

  void _initTorrentSubscription() {
    if (_torrentUpdatesSubscription != null) return;
    if (!TorrentService.isInitialized) {
      if (!enableBackgroundTimers) return;
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
      (torrents) async {
        // FIX-STATS-1: Merge incoming stats into the existing map instead of
        // replacing the reference. Replacing drops entries that haven't been
        // re-emitted yet in this tick, which makes getTorrentSeeds/Peers return
        // 0 until the next broadcast even though data is available.
        _latestTorrentStats
          ..removeWhere((id, _) => !torrents.containsKey(id))
          ..addAll(torrents);
        checkTorrentRatioLimits();
        enforceTorrentQueue();

        // 1. Reconciliation safety-net & forced pause handling
        for (final task in List<DownloadTask>.from(_tasks)) {
          final tid = _torrentIds[task.id];
          if (tid == null) continue;

          // FIX-E: Keep the coordinator TorrentProvider mapping in sync so
          // Pause/Delete use cases can resolve the native handle.
          final torrentProvider = getIt.isRegistered<TorrentProvider>()
              ? getIt<TorrentProvider>()
              : null;
          if (torrentProvider != null &&
              torrentProvider.torrentIds[task.id] != tid) {
            torrentProvider.registerTorrentId(task.id, tid);
          }

          // Check if we need to force-pause a newly registered torrent
          if (_needsForcedPauseOnRegister.contains(task.id)) {
            _needsForcedPauseOnRegister.remove(task.id);
            _log.info(
                'Forcing pause on registered torrent ${task.id} (handle $tid)');
            try {
              if (TorrentService.isTorrentAlive(tid)) {
                await TorrentService.pauseTorrent(tid);
              }
            } catch (e) {
              _log.warning('Failed to pause newly registered torrent: $e');
            }
            await _setTask(task.copyWith(
              status: DownloadStatus.paused,
              speed: 0,
              clearEta: true,
              pausedByUser: true,
            ));
            continue;
          }

          // Safety-net: task is paused in DB but native handle is alive and transmitting data
          if (task.status == DownloadStatus.paused) {
            final stats = torrents[tid];
            if (stats != null &&
                (stats.downloadRate > 0 || stats.uploadRate > 0) &&
                TorrentService.isTorrentAlive(tid)) {
              _log.warning(
                'Safety-net: Found running/transmitting torrent task ${task.id} (handle $tid) '
                'which is marked as PAUSED. Force-calling pauseTorrent.',
              );
              try {
                await TorrentService.pauseTorrent(tid);
              } catch (e) {
                _log.warning('Failed to force-pause orphaned torrent: $e');
              }
            }
          }
        }

        // Transition torrents in native error state to DownloadStatus.failed
        for (final entry in torrents.entries) {
          final tid = entry.key;
          final info = entry.value;

          var taskId = _torrentIds.entries
              .where((e) => e.value == tid)
              .map((e) => e.key)
              .firstOrNull;
          if (taskId == null) {
            final candidate = _tasks
                .where((t) =>
                    t.isTorrent &&
                    (t.status == DownloadStatus.downloading ||
                        t.status == DownloadStatus.merging))
                .firstOrNull;
            if (candidate != null && !_torrentIds.containsKey(candidate.id)) {
              taskId = candidate.id;
              _torrentIds[taskId] = tid;
            }
          }
          if (taskId != null) {
            final downloadQueue = _speedHistories[taskId] ??= Queue<double>();
            downloadQueue.add(info.downloadRate.toDouble());
            if (downloadQueue.length > 20) downloadQueue.removeFirst();

            final uploadQueue =
                _uploadSpeedHistories[taskId] ??= Queue<double>();
            uploadQueue.add(info.uploadRate.toDouble());
            if (uploadQueue.length > 20) uploadQueue.removeFirst();

            // FIX v2.0.0: Push live metrics AND torrentFiles onto the task.
            // Previously torrentFiles was never synced here, so the details
            // screen showed no files until the orchestrator's onProgress fired.
            final taskIdx = _tasks.indexWhere((t) => t.id == taskId);
            if (taskIdx != -1) {
              final task = _tasks[taskIdx];
              final liveDone = info.totalWantedDone > 0
                  ? info.totalWantedDone
                  : (info.totalDone > 0
                      ? info.totalDone
                      : task.downloadedBytes);

              // FIX v2.0.0: Sync torrentFiles from the engine whenever metadata is available.
              List<Map<String, dynamic>>? syncedFiles = task.torrentFiles;
              if (info.hasMetadata) {
                try {
                  final nativeFiles = TorrentService.getFiles(tid);
                  if (nativeFiles.isNotEmpty) {
                    final newSynced = nativeFiles.map((f) {
                      final dl = f.safeDownloadedBytes;
                      return <String, dynamic>{
                        'name': f.name,
                        'length': f.size,
                        'downloadedBytes': dl >= 0 ? dl : 0,
                        'selected': f.selected,
                        'priority': f.priority,
                        'progress':
                            f.size > 0 ? (dl.clamp(0, f.size) / f.size) : 1.0,
                        'isComplete': f.size == 0 || dl >= f.size,
                        'progressEstimated': dl < 0,
                      };
                    }).toList();
                    // Only update if the list has changed to avoid unnecessary rebuilds.
                    if (_fileListsDiffer(syncedFiles, newSynced)) {
                      syncedFiles = newSynced;
                    }
                  }
                } catch (e) {
                  _log.fine('Failed to sync torrent files for $taskId: $e');
                }
              }

              final filesSum = syncedFiles
                      ?.where((f) => (f['selected'] as bool?) ?? true)
                      .fold<int>(
                          0,
                          (s, f) =>
                              s + ((f['length'] as num?)?.toInt() ?? 0)) ??
                  0;
              // FIX: Always use info.totalWanted as authoritative fileSize when available, or sum of files.
              final newSize = (info.totalWanted > 0)
                  ? info.totalWanted
                  : (filesSum > 0 ? filesSum : task.fileSize);
              final newSpeed = (task.status == DownloadStatus.downloading ||
                      task.status == DownloadStatus.merging)
                  ? info.downloadRate.toDouble()
                  : (task.status == DownloadStatus.completed &&
                          task.seedingEnabled
                      ? info.uploadRate.toDouble()
                      : task.speed);
              final newCycleState = CycleState.fromLibtorrent(
                info.stateLabel,
                seedingEnabled: task.seedingEnabled,
              );

              final filesChanged =
                  _fileListsDiffer(task.torrentFiles, syncedFiles);

              if (task.downloadedBytes != liveDone ||
                  task.fileSize != newSize ||
                  task.speed != newSpeed ||
                  task.cycleState != newCycleState ||
                  filesChanged) {
                _tasks[taskIdx] = task.copyWith(
                  downloadedBytes: liveDone,
                  fileSize: newSize,
                  speed: newSpeed,
                  cycleState: newCycleState,
                  torrentFiles: syncedFiles,
                );
                notifyListeners();
              }
            }
          }

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
            if (taskId != null) {
              final task = _findTask(taskId);
              if (task != null && task.status == DownloadStatus.downloading) {
                unawaited(_setTask(task.copyWith(
                  status: DownloadStatus.failed,
                  errorMessage: 'Torrent engine error: ${info.stateLabel}',
                  speed: 0,
                  clearEta: true,
                )).catchError((e) => _log.warning(
                    'Failed to set task state from torrent error', e)));
              }
            }
          }
        }
      },
    );

    // FIX-STATS-7: Also start the TorrentProvider stream so providerLatestTorrentStats
    // is populated through the coordinator path as a fallback. This covers the
    // window where the orchestrator's onProgress fires before this subscription
    // processes its first tick.
    final tp =
        getIt.isRegistered<TorrentProvider>() ? getIt<TorrentProvider>() : null;
    tp?.startListening();
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
  final Map<String, ({CancelToken video, CancelToken audio})>
      _orchestratorTokens = {};
  final List<Future<void>> _pendingDeleteCleanups = [];
  final Map<String, bool> _resumeRejectionRestarts = {};
  final Map<String, Queue<double>> _speedHistories = {};
  final Map<String, Queue<double>> _uploadSpeedHistories = {};
  // FIX-M7: Periodic timer for cleaning up inactive speed histories
  Timer? _speedHistoryCleanupTimer;
  final Map<String, Future<void>> _dbSaveQueues = {};

  /// Resolves the engine torrent ID for a task.
  /// Priority: 1) cached map  2) info-hash match  3) name/tracker fallback.
  int? _resolveTorrentId(DownloadTask task) {
    // 1. Cached mapping
    final mapped = _torrentIds[task.id];
    if (mapped != null) return mapped;

    // 2. Info-hash match for magnets (most reliable)
    if (task.url.startsWith('magnet:')) {
      try {
        final parsed = parseMagnetUrl(task.url);
        final infoHash = parsed['infoHash']?.toString().toLowerCase();
        if (infoHash != null) {
          for (final tid in TorrentService.activeTorrentIds) {
            final stats = TorrentService.latestStats[tid];
            if (stats?.infoHash?.toLowerCase() == infoHash) {
              _torrentIds[task.id] = tid; // cache for future calls
              return tid;
            }
          }
        }
      } catch (e) {
        _log.warning('Info-hash resolution failed for ${task.id}: $e');
      }
    }

    // 3. Name/tracker fallback (log a warning since it's ambiguous)
    _log.warning(
      'Using name-match fallback for torrent ID resolution on ${task.id}. '
      'This may match the wrong torrent if names collide.',
    );
    return TorrentService.activeTorrentIds.cast<int?>().firstWhere(
          (tid) =>
              tid != null &&
              (TorrentService.latestStats[tid]?.name == task.fileName ||
                  TorrentService.latestStats[tid]?.currentTracker == task.url),
          orElse: () => null,
        );
  }

  void _cleanupInactiveSpeedHistories([String? completedTaskId]) {
    if (completedTaskId != null) {
      _speedHistories.remove(completedTaskId);
      _uploadSpeedHistories.remove(completedTaskId);
    }
    final allTaskIds = _tasks.map((t) => t.id).toSet();
    _speedHistories.removeWhere((id, _) => !allTaskIds.contains(id));
    _uploadSpeedHistories.removeWhere((id, _) => !allTaskIds.contains(id));

    final activeIds = _tasks
        .where((t) =>
            t.status == DownloadStatus.downloading ||
            (t.status == DownloadStatus.completed &&
                t.isTorrent &&
                t.seedingEnabled))
        .map((t) => t.id)
        .toSet();
    _speedHistories.removeWhere((id, _) => !activeIds.contains(id));
    _uploadSpeedHistories.removeWhere((id, _) => !activeIds.contains(id));

    // Cap Queue length at 5 for non-downloading tasks, 20 for active
    for (final entry in _speedHistories.entries) {
      final task = _findTask(entry.key);
      final maxLen = task?.status == DownloadStatus.downloading ? 20 : 5;
      while (entry.value.length > maxLen) {
        entry.value.removeFirst();
      }
    }
    for (final entry in _uploadSpeedHistories.entries) {
      final task = _findTask(entry.key);
      final isSeeding = task?.isTorrent == true && task?.seedingEnabled == true;
      final maxLen =
          (task?.status == DownloadStatus.downloading || isSeeding) ? 20 : 5;
      while (entry.value.length > maxLen) {
        entry.value.removeFirst();
      }
    }

    // Enforce max cap of 50 total entries in speed histories map
    while (_speedHistories.length > 50) {
      _speedHistories.remove(_speedHistories.keys.first);
    }
    while (_uploadSpeedHistories.length > 50) {
      _uploadSpeedHistories.remove(_uploadSpeedHistories.keys.first);
    }
  }

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

  /// Monotonically increasing revision number updated on progress ticks.
  /// Isolates high-frequency progress rebuilds from structural notifyListeners().
  final ValueNotifier<int> progressRevision = ValueNotifier<int>(0);

  /// Disposes and removes progress and speed ValueNotifiers for [taskId] (NEW-01).
  void disposeTaskNotifier(String taskId) {
    _progressNotifiers.remove(taskId)?.dispose();
    _speedNotifiers.remove(taskId)?.dispose();
  }

  @visibleForTesting
  int get taskNotifierCount =>
      _progressNotifiers.length + _speedNotifiers.length;

  void _pushTick(String taskId, double progress, double speed) {
    if (!DownloadEngine.appInForeground || PowerMonitor.screenOff) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final lastPush = _lastUiPushTimes[taskId] ?? 0;
    final throttleMs = PowerMonitor.screenOff
        ? 30000
        : DownloadEngine.isInBackground
            ? 5000
            : 1000; // was 250ms

    if (now - lastPush < throttleMs) return;
    _lastUiPushTimes[taskId] = now;

    progressRevision.value++;
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
  final Map<String, int> _lastUiPushTimes = {};
  final Map<String, int> _lastDbSaveTimes = {};
  final Map<String, int> _lastDbSaveBytes = {};
  final Map<String, int> _lastTorrentFileDiskSync = {};

  /// ERR-RESILIENCE-2.3: timestamp (ms) of the last periodic .dmxstate
  /// integrity sweep, used to throttle it to ~once per minute.
  int _lastIntegrityCheckMs = 0;

  final Set<String> _pendingProgressUpdates = {};
  final Map<String, int> _torrentIds = {};
  final Set<String> _needsForcedPauseOnRegister = {};

  late final NotificationCoordinator _notifications;
  late final DownloadOrchestrator _orchestrator;

  int _generation = 0;
  bool _disposed = false;

  @override
  final bool enableBackgroundTimers;

  final Map<String, int> _retryCounts = {};
  final Map<String, int> _dbRetryCounts = {};
  final Map<int, TorrentUpdateInfo> _latestTorrentStats = {};

  List<double> getSpeedHistory(String id) =>
      _speedHistories[id]?.toList() ?? const [];

  List<double> getUploadSpeedHistory(String id) =>
      _uploadSpeedHistories[id]?.toList() ?? const [];

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
  void pushProgressTick(String taskId, double progress, double speed) {
    final task = _findTask(taskId);
    if (task != null && task.hasMergedAudio && task.resolvedFileSize > 0) {
      final combined = task.combinedDownloadedBytes.clamp(
        0,
        task.resolvedFileSize,
      );
      final combinedProgress =
          (combined / task.resolvedFileSize).clamp(0.0, 1.0);
      _pushTick(taskId, combinedProgress, speed);
      return;
    }
    _pushTick(taskId, progress, speed);
  }

  @override
  void providerStartWidgetTimer() => _startWidgetTimer();

  @override
  bool get providerIsOnWifi => _networkMonitor.hasWifiOrEthernet;

  @override
  bool get providerIsCharging => PowerMonitor.isCharging;

  // ---------------------------------------------------------------------------
  // DownloadOrchestratorHost contract implementations
  // ---------------------------------------------------------------------------

  @override
  Map<String, CancelToken> get cancelTokens => _cancelTokens;

  @override
  Map<String, ({CancelToken video, CancelToken audio})>
      get orchestratorTokens => _orchestratorTokens;

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

  @override
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  DownloadMetrics? getMetrics(String taskId) => _downloadMetrics[taskId];

  Future<List<Map<String, dynamic>>?> loadTorrentFiles(String taskId) async {
    final task = findTaskById(taskId);
    if (task != null &&
        task.torrentFiles != null &&
        task.torrentFiles!.isNotEmpty) {
      return task.torrentFiles;
    }
    final dbTask = await _databaseService.getTask(taskId);
    return dbTask?.torrentFiles;
  }

  DateTime _lastNotifyTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const _minNotifyInterval = Duration(milliseconds: 250);

  @override
  void notifyListeners() {
    _revision++;
    if (isBatchMode) {
      markBatchDirty();
      return;
    }
    if (PowerMonitor.screenOff) return;
    final now = DateTime.now();
    if (now.difference(_lastNotifyTime) < _minNotifyInterval) return;
    _lastNotifyTime = now;
    super.notifyListeners();
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
    final count = threadCount > 0 ? threadCount : 1;
    if (fileSize <= 0) return List.filled(count, 0.0);
    final overallFraction = (actualBytesOnDisk / fileSize).clamp(0.0, 1.0);

    if (stateChunks == null ||
        stateChunks.isEmpty ||
        stateChunks.length != count) {
      return List.filled(count, overallFraction);
    }

    // Scale existing chunks to match actual bytes
    final chunkSum = stateChunks.fold<double>(0.0, (s, c) => s + c);
    if (chunkSum <= 0) return List.filled(count, overallFraction);

    final scale = (overallFraction * count) / chunkSum;
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
          } catch (e, st) {
            LoggingService.logger('DownloadProvider')
                .warning('Operation failed', e, st);
          }
        }
        return task.copyWith(audioProgress: 0.0, audioDownloadedBytes: 0);
      }
    }
    if (oldItag != null) {
      try {
        await itagFile.writeAsString(oldItag);
      } catch (e, st) {
        LoggingService.logger('DownloadProvider')
            .warning('Operation failed', e, st);
      }
    }

    if (await audioStateFile.exists()) {
      try {
        final content = await audioStateFile.readAsString();
        jsonDecode(content);
      } catch (e) {
        debugPrint('[DMX] Corrupt .audio.dmxstate detected, deleting.');
        try {
          await audioStateFile.delete();
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
      }
    }

    if (!await audioFile.exists()) {
      if (await audioStateFile.exists()) {
        try {
          await audioStateFile.delete();
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
      }
      return task.copyWith(audioProgress: 0.0, audioDownloadedBytes: 0);
    }

    int audioThreads = task.audioThreadCount > 0 ? task.audioThreadCount : 1;
    if (await audioStateFile.exists()) {
      try {
        final content = await audioStateFile.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is Map && decoded['threadCount'] is int) {
          audioThreads = decoded['threadCount'] as int;
        }
      } catch (e, st) {
        LoggingService.logger('DownloadProvider')
            .warning('Operation failed', e, st);
      }
    }
    final audioBytes = await actualDownloadedBytes(
      audioFile.path,
      threadCount: audioThreads,
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
          } catch (e, st) {
            LoggingService.logger('DownloadProvider')
                .warning('Operation failed', e, st);
          }
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

    // FIX-YT-RECONCILE: Do NOT fold audio bytes into the return value.
    // downloadedBytes must hold ONLY video bytes. Audio is tracked separately
    // via audioDownloadedBytes / audioProgress. Combining them here causes:
    //   1. resumeTask to skip video chunks (inflated video start offset).
    //   2. combinedDownloadedBytes to double-count audio → progress > 100%.
    return videoBytes;
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

    final actualVideoBytes = await _actualPartialBytes(task);
    if (actualVideoBytes == null) return task;

    // FIX-YT-RECONCILE: For YouTube tasks with merged audio, also reconcile
    // the audio sidecar bytes separately — never mixed into downloadedBytes.
    DownloadTask reconciled = task;
    if (task.hasMergedAudio) {
      final audioPath = '${task.tempFilePath}.audio';
      final audioBytes = await actualDownloadedBytes(
        audioPath,
        threadCount: task.audioThreadCount > 0 ? task.audioThreadCount : 1,
      );
      if (audioBytes != task.audioDownloadedBytes) {
        reconciled = reconciled.copyWith(
          audioDownloadedBytes: audioBytes,
          audioProgress: task.audioSize > 0
              ? (audioBytes / task.audioSize).clamp(0.0, 1.0)
              : task.audioProgress,
        );
      }
    }

    if (actualVideoBytes == task.downloadedBytes) return reconciled;

    // Use fileSize for clamping when available; for YouTube with separate
    // audio size, clamp to video-only size so bytes can't exceed the video part.
    final videoOnlySize = task.hasMergedAudio && task.videoStreamSize > 0
        ? task.videoStreamSize
        : (task.hasMergedAudio &&
                task.audioSize > 0 &&
                task.fileSize > task.audioSize
            ? task.fileSize - task.audioSize
            : task.fileSize);
    final bytes = videoOnlySize > 0
        ? actualVideoBytes.clamp(0, videoOnlySize)
        : actualVideoBytes;

    return reconciled.copyWith(
      downloadedBytes: bytes,
      chunks: _buildChunks(task.threadCount, videoOnlySize, bytes),
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
      unawaited(_databaseService.saveTask(_tasks[i]).catchError((e) {
        _log.warning('Failed to save torrent task failure state', e);
      }));
      changed = true;
    }
    if (changed) {
      filteredTasksDirty = true;
      notifyListeners();
    }
  }

  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;

  /// [pauseOrphanDownloads] should be true only on initial app startup, when
  /// in-flight downloads (from a previous run) cannot be resumed safely.
  /// On user-triggered reload, we must preserve currently active downloads.
  Future<void> load({bool pauseOrphanDownloads = true}) async {
    // FIX MISC-2: Guard against concurrent in-flight loads
    if (_isLoadingTasks) return;
    _isLoadingTasks = true;
    _generation++;

    try {
      // Cancel stale notifications from previous sessions
      await _notifications.cancelAll();

      final cleanupDays = _settingsProvider.cleanupDays;
      final now = DateTime.now();
      final toDelete = <DownloadTask>[];
      List<DownloadTask> dbTasks = [];
      try {
        dbTasks = await _databaseService.loadTasks();
      } catch (e, st) {
        _log.severe(
          'Failed to load tasks from database, falling back to empty list: $e',
          e,
          st,
        );
        dbTasks = [];
      }

      final loaded = dbTasks.map((t) {
        // FIX-AUDIT-4: Clamp downloadedBytes to fileSize and chunks to [0.0, 1.0] to prevent >100% display.
        int clampedBytes = t.downloadedBytes;
        if (t.fileSize > 0 && clampedBytes > t.fileSize) {
          clampedBytes = t.fileSize;
        }
        final clampedChunks = t.chunks.map((c) => c.clamp(0.0, 1.0)).toList();
        var task = t.copyWith(
          downloadedBytes: clampedBytes,
          chunks: clampedChunks,
        );

        // Torrent initial load file progress estimation:
        if (task.isTorrent &&
            task.torrentFiles != null &&
            task.torrentFiles!.isNotEmpty &&
            task.downloadedBytes > 0) {
          final hasZeroFiles = task.torrentFiles!.every(
              (f) => ((f['downloadedBytes'] as num?)?.toInt() ?? 0) == 0);
          if (hasZeroFiles) {
            final modifiableFiles = List<Map<String, dynamic>>.from(
                task.torrentFiles!.map((f) => Map<String, dynamic>.from(f)));
            TorrentDownloadHandler.distributeEstimatedBytes(
                modifiableFiles, task.downloadedBytes);
            task = task.copyWith(torrentFiles: modifiableFiles);
          }
        }

        // When the app starts, mark any non-completed and non-failed download (downloading, queued, merging) as paused/queued depending on autoStart.
        final hasActiveStream = _cancelTokens.containsKey(task.id);
        if (!hasActiveStream &&
            task.status != DownloadStatus.completed &&
            task.status != DownloadStatus.failed) {
          final wasAlreadyPaused = task.status == DownloadStatus.paused;
          if (!wasAlreadyPaused && _settingsProvider.autoStart) {
            return task.copyWith(
              status: DownloadStatus.queued,
              pausedByUser: false,
              speed: 0,
              clearEta: true,
              clearError: true,
            );
          }
          return task.copyWith(
            status: DownloadStatus.paused,
            pausedByUser: wasAlreadyPaused ? task.pausedByUser : true,
            speed: 0,
            clearEta: true,
            errorMessage: wasAlreadyPaused
                ? task.errorMessage
                : (task.status == DownloadStatus.merging
                    ? 'Merge was interrupted. Tap Resume/Retry to continue.'
                    : (task.isTorrent
                        ? 'App restarted — resume to continue'
                        : DownloadStatusMessages.pausedOrphaned)),
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
          final supported =
              await IosBackgroundCapability.instance.isSupported();
          if (supported) {
            _log.info(
              'iOS: $activeDownloads active download(s) scheduled with native BGTaskScheduler / URLSession.',
            );
            unawaited(
              BackgroundService.start().catchError((e) {
                _log.warning('BackgroundService.start failed: $e');
              }),
            );
          } else {
            _log.warning(
              'iOS: $activeDownloads download(s) were active but native background execution is unsupported. Pausing.',
            );
            // Mark them as paused so the UI reflects reality
            for (var i = 0; i < _tasks.length; i++) {
              if (_tasks[i].status == DownloadStatus.downloading) {
                _tasks[i] = _tasks[i].copyWith(
                  status: DownloadStatus.paused,
                  speed: 0,
                  clearEta: true,
                  errorMessage:
                      'Paused: iOS background execution is unsupported',
                );
              }
            }
          }
        }
      }

      // Automatically restart seeding for completed torrents with seeding enabled
      for (final task in _tasks) {
        if (task.isTorrent &&
            task.status == DownloadStatus.completed &&
            task.seedingEnabled) {
          unawaited(
            startSeedingTorrent(task).catchError((e) {
              _log.warning('startSeedingTorrent failed: $e');
            }),
          );
        }
      }

      // Reconcile torrent IDs after restart
      final savedMapping = await TorrentResumeStore.loadTaskMapping();
      for (final task in _tasks) {
        if (task.isTorrent && task.status != DownloadStatus.completed) {
          final savedId = savedMapping[task.id];
          if (savedId != null && TorrentService.isTorrentAlive(savedId)) {
            _torrentIds[task.id] = savedId;
          } else {
            // Try to match by name
            for (final tid in TorrentService.activeTorrentIds) {
              final stats = TorrentService.latestStats[tid];
              if (stats != null && stats.name == task.fileName) {
                _torrentIds[task.id] = tid;
                break;
              }
            }
          }
        }
      }
      await TorrentResumeStore.persistTaskMapping(_torrentIds);

      updateActualTorrentUploadLimit();

      _startWidgetTimer();
      filteredTasksDirty = true;
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

      unawaited(
        safePumpQueue().catchError((e) {
          _log.warning('safePumpQueue failed: $e');
        }),
      );

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
                debugPrint(
                    'Failed to reconcile partial file for ${task.id}: $e');
                return task;
              }
            }),
          );
          reconciled.addAll(batchResults);
        }

        for (final task in reconciled) {
          final idx = _tasks.indexWhere((t) => t.id == task.id);
          if (idx != -1) {
            // If the task was deleted or status in memory transitioned during the async gap, do NOT overwrite or recreate in DB!
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

      _isLoaded = true;
    } finally {
      _isLoadingTasks = false;
    }
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

    // 3. Aggregate disk space pre-check across batch before starting queue
    final totalBatchSize =
        safeTasks.fold<int>(0, (sum, t) => sum + t.combinedTotalSize);
    if (totalBatchSize > 0) {
      try {
        final hasSpace =
            await _downloadEngine.hasEnoughDiskSpace(savePath, totalBatchSize);
        if (!hasSpace) {
          _log.warning(
              '[Disk Check] Batch size ($totalBatchSize bytes) exceeds available space at $savePath');
          _lastError = 'Insufficient disk space for batch download.';
          return;
        }
      } catch (e) {
        debugPrint('[Disk Check] Batch disk space check failed: $e');
      }
    }

    // 4. Notify UI immediately so all cards appear at once.
    notifyListeners();

    // 5. Pump once with capped concurrency ceiling (max(maxDownloads, min(batch, 8))).
    final override = max(
      _settingsProvider.maxDownloads,
      min(safeTasks.length, 8),
    );
    pumpQueue(maxConcurrentOverride: override);
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

    if (url.trim().toLowerCase().startsWith('magnet:')) {
      try {
        final parsed = parseMagnetUrl(url.trim());
        final newHash = parsed['infoHash']?.toString().toLowerCase();
        if (newHash != null) {
          final duplicate = _tasks.any((t) {
            if (t.status == DownloadStatus.failed ||
                t.status == DownloadStatus.completed ||
                t.status == DownloadStatus.paused) {
              return false;
            }
            if (!t.url.startsWith('magnet:')) return false;
            try {
              final existingParsed = parseMagnetUrl(t.url);
              return existingParsed['infoHash']?.toString().toLowerCase() ==
                  newHash;
            } catch (_) {
              return false;
            }
          });
          if (duplicate && !isAppUpdate) {
            throw Exception(
                'This torrent (same info-hash) is already active in the queue.');
          }
        }
      } catch (e) {
        if (e is Exception && e.toString().contains('already active')) rethrow;
        _log.warning('Magnet dedup check failed: $e');
      }
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

    // FIX-COMBINED: Set combined fileSize (video + audio) and videoStreamSize
    final int finalFileSize;
    final int finalVideoStreamSize;
    if (mergedAudioUrl != null && mergedAudioUrl.isNotEmpty && audioSize > 0) {
      finalVideoStreamSize = size > 0 ? size : 0;
      finalFileSize =
          size > 0 ? (size + audioSize) : (fileSize > 0 ? fileSize : 0);
    } else {
      finalVideoStreamSize = 0;
      finalFileSize = fileSize;
    }

    final task = DownloadTask(
      id: '${now.microsecondsSinceEpoch}_${Random.secure().nextInt(1000000000)}',
      fileName: fileName,
      url: url.trim(),
      fileSize: finalFileSize,
      videoStreamSize: finalVideoStreamSize,
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
        // FIX: Do NOT scan the entire folder if we don't have the file list yet (e.g. magnets).
        // Scanning the whole folder could count unrelated files and falsely report 100% progress.
        return (total: 0, files: null);
      }

      return (total: 0, files: fileList);
    } catch (e) {
      debugPrint('[DMX] Torrent pre-scan failed for $rootPath: $e');
      return (total: 0, files: fileList);
    }
  }

  @override
  Future<void> pauseTask(String id,
      {PauseReason reason = PauseReason.userRequested}) async {
    // Guard task state mutations with synchronized lock
    return _lockFor(id).synchronized(() async {
      final task = _findTask(id);
      if (task == null) return;

      final isSeedingTorrent = task.status == DownloadStatus.completed &&
          task.isTorrent &&
          task.seedingEnabled;

      if (!isSeedingTorrent &&
          (task.status == DownloadStatus.paused ||
              task.status == DownloadStatus.completed)) {
        return;
      }

      final wasDownloading = task.status == DownloadStatus.downloading;

      // For seeding torrents, only disable seeding — do NOT change status yet.
      // _pauseTaskInternal will handle the engine pause and set status after.
      if (!isSeedingTorrent) {
        final updated = task.copyWith(
          status: DownloadStatus.paused,
          pausedByUser: reason == PauseReason.userRequested,
          pauseReason: reason,
          cycleState: CycleState.paused,
          speed: 0,
          clearEta: true,
        );
        await _setTask(updated);
      }

      // Fire-and-forget the engine pause/cancel execution in the background
      unawaited(
        _lockFor(id).synchronized(() async {
          try {
            await _pauseTaskInternal(id,
                wasDownloading: wasDownloading,
                wasSeeding: isSeedingTorrent,
                reason: reason);
          } catch (e, st) {
            _log.warning('Background engine pause failed for $id', e, st);
          }
        }),
      );
    });
  }

  Future<void> _pauseTaskInternal(
    String id, {
    required bool wasDownloading,
    required bool wasSeeding,
    PauseReason reason = PauseReason.userRequested,
  }) async {
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

    final isSeedingTorrent = wasSeeding;

    if (wasDownloading || isSeedingTorrent) {
      int? torrentId = _resolveTorrentId(task);

      if (task.isTorrent && torrentId == null) {
        // Poll briefly up to 1s for the torrentId to register
        final pollDeadline = DateTime.now().add(const Duration(seconds: 1));
        while (torrentId == null && DateTime.now().isBefore(pollDeadline)) {
          await Future.delayed(const Duration(milliseconds: 50));
          torrentId = _resolveTorrentId(task);
        }

        // If still null, set a flag so as soon as it registers, it gets paused.
        if (torrentId == null) {
          _log.info(
              'Torrent registration pending on pause; marking needsForcedPauseOnRegister for ${task.id}');
          _needsForcedPauseOnRegister.add(task.id);

          // FIX #6: Immediately pause ALL active torrents that match this task's
          // magnet URI to close the race window.
          if (task.url.startsWith('magnet:')) {
            try {
              final parsed = parseMagnetUrl(task.url);
              final infoHash = parsed['infoHash']?.toString().toLowerCase();
              if (infoHash != null) {
                for (final tid in TorrentService.activeTorrentIds) {
                  final stats = TorrentService.latestStats[tid];
                  if (stats?.infoHash?.toLowerCase() == infoHash) {
                    await TorrentService.pauseTorrent(tid);
                    _torrentIds[task.id] = tid; // cache it now
                    _needsForcedPauseOnRegister.remove(task.id);
                    torrentId = tid;
                    break;
                  }
                }
              }
            } catch (e) {
              _log.warning('Immediate magnet pause attempt failed: $e');
            }
          }

          if (torrentId == null) {
            // FIX-PAUSE-5: Cancel the CancelToken even in this early-return path.
            // Without this the orchestrator's onProgress keeps running and the
            // native torrent session is never told to stop.
            for (final suffix in ['::video', '::audio', '']) {
              final k = suffix.isEmpty ? id : '$id$suffix';
              try {
                _cancelTokens[k]?.cancel('paused:${reason.name}');
              } catch (e, st) {
                LoggingService.logger('DownloadProvider')
                    .warning('Operation failed', e, st);
              }
              _cancelTokens.remove(k);
            }
            final orchTokens = _orchestratorTokens.remove(id);
            if (orchTokens != null) {
              if (!orchTokens.video.isCancelled) {
                try {
                  orchTokens.video.cancel('paused:${reason.name}');
                } catch (_) {}
              }
              if (!orchTokens.audio.isCancelled) {
                try {
                  orchTokens.audio.cancel('paused:${reason.name}');
                } catch (_) {}
              }
            }

            // Set DB status to paused so the UI reflects it immediately
            await _setTask(task.copyWith(
              status: DownloadStatus.paused,
              speed: 0,
              clearEta: true,
              pausedByUser: reason == PauseReason.userRequested,
              pauseReason: reason,
              cycleState: CycleState.paused,
            ));
            _orchestrator.clearStartingFlag(id);
            _orchestrator.clearPushScheduled(id);
            _notifications.cancelForTask(id);
            pumpQueue();
            return;
          }
        }
      }

      // 1. For torrents, pause engine FIRST (immediate)
      if (torrentId != null && TorrentService.isTorrentAlive(torrentId)) {
        try {
          await TorrentService.pauseTorrent(torrentId);
        } catch (e) {
          _log.warning('Failed initial pauseTorrent for $torrentId: $e');
        }
      }

      // 2. Cancel tokens (stops orchestrator loops)
      if (wasDownloading) {
        // Flush progress BEFORE cancelling so no in-flight write is lost
        await _flushPendingProgress(id);

        for (final suffix in ['::video', '::audio', '']) {
          final k = suffix.isEmpty ? id : '$id$suffix';
          try {
            _cancelTokens[k]?.cancel('paused:${reason.name}');
          } catch (e, st) {
            LoggingService.logger('DownloadProvider')
                .warning('Operation failed', e, st);
          }
          _cancelTokens.remove(k);
        }
        final orchTokens = _orchestratorTokens.remove(id);
        if (orchTokens != null) {
          if (!orchTokens.video.isCancelled) {
            try {
              orchTokens.video.cancel('paused:${reason.name}');
            } catch (_) {}
          }
          if (!orchTokens.audio.isCancelled) {
            try {
              orchTokens.audio.cancel('paused:${reason.name}');
            } catch (_) {}
          }
        }

        final fut = _activeFutures[id];
        if (fut != null) {
          try {
            await fut.timeout(const Duration(seconds: 3));
          } on TimeoutException catch (e, st) {
            _log.warning(
                'Engine future timed out on pause (3s). Force-cancelling task $id.',
                e,
                st);
            _downloadEngine.forceCancelJob(id);
            final latest = _findTask(id) ?? task;
            await _databaseService.saveTask(
              latest.copyWith(
                status: DownloadStatus.paused,
                pausedByUser: reason == PauseReason.userRequested,
                pauseReason: reason,
                cycleState: CycleState.paused,
                speed: 0,
                clearEta: true,
              ),
            );
          } catch (e, st) {
            LoggingService.logger('DownloadProvider')
                .warning('Operation failed', e, st);
          }
        }

        _activeFutures.remove(id);

        // Validate engine state file after cancel completes
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
          } catch (e, st) {
            LoggingService.logger('DownloadProvider')
                .warning('Operation failed', e, st);
          }
        }
      }

      // 3. Confirm torrent pause with scaled timeout
      if (torrentId != null) {
        if (TorrentService.isTorrentAlive(torrentId)) {
          final taskSize =
              task.fileSize > 0 ? task.fileSize : 100 * 1024 * 1024;
          final timeoutSeconds = taskSize > 1024 * 1024 * 1024
              ? 5
              : taskSize > 100 * 1024 * 1024
                  ? 3
                  : 2;
          final pauseDeadline =
              DateTime.now().add(Duration(seconds: timeoutSeconds));
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
            // One more graceful attempt
            try {
              await TorrentService.pauseTorrent(torrentId);
              await Future.delayed(const Duration(milliseconds: 500));
              isPaused = !TorrentService.isTorrentAlive(torrentId) ||
                  _latestTorrentStats[torrentId]
                          ?.stateLabel
                          .toLowerCase()
                          .contains('paused') ==
                      true;
            } catch (_) {}

            if (!isPaused) {
              debugPrint(
                '[DMX] B4 FIX: Torrent $torrentId did not confirm pause within ${timeoutSeconds}s, force-stopping',
              );
              try {
                await TorrentService.forceStopTorrent(torrentId);
              } catch (e) {
                _log.warning(
                    'FIX-C: forceStopTorrent fallback failed on pause for $torrentId: $e');
              }
            }
          }

          // FIX-PAUSE-SUBS: Always dispose the registry entry on pause attempt.
          // Previously this was guarded by `isPaused`, so a torrent that failed
          // to confirm pause within the timeout kept its stream subscription
          // alive — meaning the whenCancel callback (which halts the native
          // session) would never fire, and downloading continued.
          try {
            TorrentSubscriptionRegistry.instance.dispose(torrentId);
          } catch (e) {
            _log.fine('No active subscription to dispose for $torrentId: $e');
          }

          // Snapshot per-file bytes AFTER engine has stopped
          try {
            final accurateFiles = await TorrentService.getAccurateFileProgress(
              torrentId,
              task.savePath,
            );
            if (accurateFiles.isNotEmpty && task.torrentFiles != null) {
              final accurateByIndex = {
                for (final af in accurateFiles) af.index: af
              };
              final accurateByName = {
                for (final af in accurateFiles) af.name: af
              };
              final updatedFiles = task.torrentFiles!.map((stored) {
                final idx = stored['index'] as int?;
                final accurate = (idx != null ? accurateByIndex[idx] : null) ??
                    accurateByName[stored['name'] as String? ?? ''];
                if (accurate != null) {
                  return {
                    ...stored,
                    'downloadedBytes': accurate.downloadedBytes,
                    'progressEstimated': false,
                  };
                }
                return stored;
              }).toList();
              task = task.copyWith(torrentFiles: updatedFiles);
            } else {
              final liveFiles = TorrentService.getFiles(torrentId);
              if (liveFiles.isNotEmpty && task.torrentFiles != null) {
                final liveByIndex = {for (final lf in liveFiles) lf.index: lf};
                final liveByName = {for (final lf in liveFiles) lf.name: lf};
                final updatedFiles = task.torrentFiles!.map((stored) {
                  final idx = stored['index'] as int?;
                  final live = (idx != null ? liveByIndex[idx] : null) ??
                      liveByName[stored['name'] as String? ?? ''];
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
          updateActualTorrentUploadLimit();
        } else {
          debugPrint(
              '[DMX] BUG-P1 FIX: Torrent handle $torrentId is stale/dead on pause.');
          _torrentIds.remove(id);
          task = task.copyWith(
            status: DownloadStatus.paused,
            speed: 0,
            clearEta: true,
            pausedByUser: reason == PauseReason.userRequested,
            pauseReason: reason,
            cycleState: CycleState.paused,
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
          status: DownloadStatus.paused,
          seedingEnabled: false,
          speed: 0,
          clearEta: true,
          clearError: true,
          clearStatusMessage: true,
          pausedByUser: reason == PauseReason.userRequested,
          pauseReason: reason,
          cycleState: CycleState.paused,
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
          pausedByUser: reason == PauseReason.userRequested,
          pauseReason: reason,
          cycleState: CycleState.paused,
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
      bool parseOk = false;
      try {
        final content = await stateFile.readAsString();
        jsonDecode(content); // throws on corrupt JSON
        parseOk = true;
      } catch (e) {
        // M1: Wait ~250ms and retry parsing once in case of a mid-write race during pause timeout
        await Future.delayed(const Duration(milliseconds: 250));
        try {
          if (await stateFile.exists()) {
            final retryContent = await stateFile.readAsString();
            jsonDecode(retryContent);
            parseOk = true;
            debugPrint('[DMX] M1: 250ms retry recovered valid .dmxstate parse');
          }
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
      }

      if (!parseOk) {
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
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }

        if (!recoveredFromJournal) {
          try {
            await stateFile.delete();
          } catch (e, st) {
            LoggingService.logger('DownloadProvider')
                .warning('Operation failed', e, st);
          }
          debugPrint(
              '[DMX] pauseTask: deleted corrupt .dmxstate (no journal fallback)');
        }
      }
    }

    var stateBytes = await _readDmxStateBytes(latest.tempFilePath,
        threadCount: latest.threadCount);
    if (stateBytes == 0 && latest.downloadedBytes > 0) {
      // Engine saves state via scheduleMicrotask; under background mode
      // the save interval is 120s. Retry up to 3×300ms before falling
      // back to the last in-memory value.
      for (var attempt = 0; attempt < 3 && stateBytes == 0; attempt++) {
        await Future.delayed(const Duration(milliseconds: 300));
        stateBytes = await _readDmxStateBytes(latest.tempFilePath,
            threadCount: latest.threadCount);
      }
      if (stateBytes == 0) {
        stateBytes = latest.downloadedBytes;
        debugPrint('[DMX] FIX-5: state file empty after 3 retries; '
            'falling back to in-memory bytes ($stateBytes)');
      }
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
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
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
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
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
        pausedByUser: reason == PauseReason.userRequested,
        pauseReason: reason,
        cycleState: CycleState.paused,
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
    if (_taskOpInProgress[id] == true) return;
    _taskOpInProgress[id] = true;
    try {
      final rawTask = _findTask(id);
      if (rawTask == null) return;
      final isStoppedSeedingTorrent =
          rawTask.status == DownloadStatus.completed &&
              rawTask.isTorrent &&
              !rawTask.seedingEnabled;
      if (rawTask.status == DownloadStatus.downloading ||
          rawTask.status == DownloadStatus.queued ||
          (rawTask.status == DownloadStatus.completed &&
              !isStoppedSeedingTorrent)) {
        return;
      }
      return await _runGuardedTaskOperation(id, 'resumeTask', () async {
        // Pre-flight: refresh YT stream URL if it may have expired
        final task = _findTask(id);
        if (task != null &&
            task.youtubeQualityPreset != null &&
            task.downloadPageUrl != null &&
            task.downloadPageUrl!.isNotEmpty) {
          try {
            final fresh = await YoutubeService.getFreshStreams(
              task.downloadPageUrl!,
              preferredType: task.youtubePreferredType,
            );
            if (fresh != null && fresh['url'] != null) {
              final newUrl = fresh['url'] as String;
              final identityChanged =
                  DownloadProvider.youtubeStreamIdentityChanged(
                      task.url, newUrl);
              DownloadTask updated;
              if (identityChanged) {
                // Stream identity changed → ALL partial data is invalid.
                // Delete video + audio artifacts and reset both progress tracks.
                for (final path in [
                  task.tempFilePath,
                  '${task.tempFilePath}.dmxstate',
                  '${task.tempFilePath}.dmxstate.tmp',
                  '${task.tempFilePath}.journal',
                  '${task.tempFilePath}.audio',
                  '${task.tempFilePath}.audio.dmxstate',
                  '${task.tempFilePath}.audio.journal',
                  '${task.tempFilePath}.audio.itag',
                ]) {
                  try {
                    final f = File(path);
                    if (await f.exists()) await f.delete();
                  } catch (e) {
                    debugPrint('[DMX] Resume identity-reset cleanup failed '
                        'for $path: $e');
                  }
                }
                updated = task.copyWith(
                  url: newUrl,
                  mergedAudioUrl: fresh['audioUrl'] ?? task.mergedAudioUrl,
                  downloadedBytes: 0,
                  chunks: List<double>.filled(
                      task.threadCount > 0 ? task.threadCount : 1, 0.0),
                  audioProgress: 0.0,
                  audioDownloadedBytes: 0,
                  videoStreamSize: 0,
                );
              } else {
                updated = task.copyWith(
                  url: newUrl,
                  mergedAudioUrl: fresh['audioUrl'] ?? task.mergedAudioUrl,
                );
              }
              await _setTask(updated);
              await _databaseService.saveTask(updated);
            }
          } catch (e) {
            debugPrint('[DMX] YT pre-flight refresh on resume failed: $e');
          }
        }
        await _resumeTaskInternal(id);
      });
    } finally {
      _taskOpInProgress[id] = false;
    }
  }

  Future<void> _resumeTaskInternal(String id) async {
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
      if (torrentId != null) {
        // Check if engine still knows about it
        final engineIds = TorrentService.activeTorrentIds;
        if (!engineIds.contains(torrentId)) {
          _torrentIds.remove(task.id);
          // Try to find by name match
          for (final tid in engineIds) {
            final stats = TorrentService.latestStats[tid];
            if (stats?.name == task.fileName) {
              _torrentIds[task.id] = tid;
              break;
            }
          }
        }
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

    // Proceed directly with existing download stream URL without auto-updating

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
                  final prevBytes =
                      (f['downloadedBytes'] as num?)?.toInt() ?? 0;
                  final resolvedBytes = match.downloadedBytes >= 0
                      ? match.downloadedBytes
                      : prevBytes;
                  return {...f, 'downloadedBytes': resolvedBytes};
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

      if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
        final scan = scanExistingTorrentData(task.savePath, task.torrentFiles);
        if (scan.total < task.downloadedBytes * 0.9) {
          // Disk has significantly less data than recorded — reset
          task = task.copyWith(
            downloadedBytes: scan.total,
            torrentFiles: scan.files,
          );
          videoBytesOnly = scan.total;
        }
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
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
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
      clearPauseReason: true,
      clearCycleState: true,
    );
    validatedTask = await validateAudioProgress(validatedTask);

    for (final suffix in ['::video', '::audio', '']) {
      _cancelTokens.remove('$id$suffix');
    }

    await _setTask(validatedTask);
    await _databaseService.saveTask(validatedTask);

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

  /// Pauses all active downloads, stops the background service and exits the
  /// process. Triggered from the "Exit App" action on the service notification.
  Future<void> exitApp() async {
    try {
      for (final task in _tasks) {
        await _flushPendingProgress(task.id);
      }
      // Pause every active download so state is saved cleanly.
      await pauseAllTasks();
    } catch (e, st) {
      LoggingService.logger('DownloadProvider')
          .warning('Operation failed', e, st);
    }
    try {
      await BackgroundService.releaseWakeLock();
      await BackgroundService.stop();
    } catch (e, st) {
      LoggingService.logger('DownloadProvider')
          .warning('Operation failed', e, st);
    }
    // Give the service a moment to clean up, then hard-exit.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    exit(0);
  }

  Future<void> cancelTask(String id) async {
    // FIX-P0-01: Guard task state mutations with synchronized lock
    return _lockFor(id).synchronized(() async {
      final task = _findTask(id);
      if (task == null) return;

      // Flush any pending throttled progress and drop tracking state.
      await _flushPendingProgress(id);

      _cleanupTaskState(id);

      // Cancel both leg tokens - removing them allows future resumes.
      for (final suffix in ['::video', '::audio', '']) {
        final k = suffix.isEmpty ? id : '$id$suffix';
        try {
          _cancelTokens[k]?.cancel('cancelled');
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
        _cancelTokens.remove(k);
      }

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
          // FIX-2: Set isCancelled: true so auto-resume skips cancelled tasks
          isCancelled: true,
          pausedByUser: true,
        ),
      );

      pumpQueue();

      if (activeOrSeedingCount == 0) {
        _stopWidgetTimer();
      }

      _updateTelemetryWidget(force: true);
    });
  }

  Future<void> retryTask(String id) async {
    final rawTask = _findTask(id);
    if (rawTask == null || rawTask.status == DownloadStatus.completed) return;
    if (rawTask.status == DownloadStatus.downloading ||
        rawTask.status == DownloadStatus.queued) {
      return;
    }

    return _runGuardedTaskOperation(
        id, 'retryTask', () => _retryTaskInternal(id));
  }

  Future<void> _retryTaskInternal(String id) async {
    final rawTask = _findTask(id);
    if (rawTask == null || rawTask.status == DownloadStatus.completed) return;
    if (rawTask.status == DownloadStatus.downloading) {
      return;
    }
    var task = rawTask;
    final isMergeFailure = task.statusMessage == 'MERGE_FAILED' ||
        (task.errorMessage != null &&
            task.errorMessage!.contains('FFmpeg merge failed'));

    // Refresh YouTube stream URL before retrying — signed URLs expire
    if (task.youtubeQualityPreset != null &&
        task.downloadPageUrl != null &&
        task.downloadPageUrl!.isNotEmpty &&
        !isMergeFailure) {
      try {
        final fresh = await YoutubeService.getFreshStreams(
          task.downloadPageUrl!,
          preferredType: task.youtubePreferredType,
        );
        if (fresh != null && fresh['url'] != null) {
          final newUrl = fresh['url'] as String;
          final newAudioUrl = fresh['audioUrl'];
          final identityChanged =
              DownloadProvider.youtubeStreamIdentityChanged(task.url, newUrl);
          if (identityChanged) {
            try {
              for (final p in [
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
                final f = File(p);
                if (await f.exists()) await f.delete();
              }
            } catch (e, st) {
              LoggingService.logger('DownloadProvider')
                  .warning('Operation failed', e, st);
            }
            task = task.copyWith(
              url: newUrl,
              mergedAudioUrl: newAudioUrl,
              downloadedBytes: 0,
              audioProgress: 0.0,
              audioDownloadedBytes: 0,
              chunks: List<double>.filled(
                  task.threadCount > 0 ? task.threadCount : 1, 0.0),
            );
          } else {
            task = task.copyWith(
              url: newUrl,
              mergedAudioUrl: newAudioUrl ?? task.mergedAudioUrl,
            );
          }
          await _setTask(task);
          await _databaseService.saveTask(task);
        }
      } catch (e) {
        debugPrint('[DMX] YT stream refresh before retry failed: $e');
      }
    }
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
      }
    }

    // FIX YT-4: If video exists and is complete but audio is missing/failed,
    // re-download audio only without wiping the video stream.
    if (videoExists &&
        !audioExists &&
        task.mergedAudioUrl != null &&
        task.mergedAudioUrl!.isNotEmpty) {
      debugPrint(
          '[DMX] FIX YT-4: Video leg intact; retrying audio stream only for task ${task.id}');
      task = task.copyWith(
        audioProgress: 0.0,
        audioDownloadedBytes: 0,
        statusMessage: 'Re-downloading audio stream...',
        clearError: true,
      );
      await _setTask(task);
      await _resumeTaskInternal(id);
      return;
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
        errMsg.contains('missing') ||
        errMsg.contains('merge_failed') ||
        errMsg.contains('MERGE_FAILED') ||
        errMsg.contains('ffmpeg');

    // When retrying a MERGE_FAILED task, only re-download the missing leg:
    if (task.statusMessage == 'MERGE_FAILED' ||
        errMsg.contains('merge_failed') ||
        errMsg.contains('MERGE_FAILED') ||
        errMsg.contains('ffmpeg')) {
      if (videoExists && !audioExists) {
        task = task.copyWith(audioProgress: 0.0, audioDownloadedBytes: 0);
      } else if (!videoExists && audioExists) {
        task = task.copyWith(
          downloadedBytes: 0,
          chunks: List.filled(task.threadCount > 0 ? task.threadCount : 1, 0.0),
        );
      }
    }

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

    final isMergeLegPartial = (task.statusMessage == 'MERGE_FAILED' ||
            errMsg.contains('merge_failed') ||
            errMsg.contains('MERGE_FAILED') ||
            errMsg.contains('ffmpeg')) &&
        (videoExists ^ audioExists);

    final shouldResetAllProgressMetadata =
        (shouldClearState || isUnrecoverable) && !isMergeLegPartial;

    if (shouldResetAllProgressMetadata) {
      debugPrint(
        '[DMX] S1 FIX: Unrecoverable/expired error detected. '
        'Clearing state for fresh retry.',
      );
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
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
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

      // FIX-C3: Verify main video/payload file on disk for non-torrents
      if (!task.isTorrent && task.tempFilePath.isNotEmpty) {
        final videoFile = File(task.tempFilePath);
        final localFile = File(task.localFilePath);
        if (!await videoFile.exists() && !await localFile.exists()) {
          task = task.copyWith(
            downloadedBytes: 0,
            chunks: List<double>.filled(
              task.threadCount > 0 ? task.threadCount : 1,
              0.0,
            ),
          );
        } else {
          // Validate .dmxstate JSON integrity; if corrupted, wipe state
          final statePath = '${task.tempFilePath}.dmxstate';
          final stateFile = File(statePath);
          if (await stateFile.exists()) {
            bool isValid = false;
            try {
              final jsonStr = await stateFile.readAsString();
              final decoded = jsonDecode(jsonStr);
              if (decoded is Map<String, dynamic> &&
                  decoded['downloadedBytes'] != null) {
                isValid = true;
              }
            } catch (_) {
              isValid = false;
            }
            if (!isValid) {
              try {
                await stateFile.delete();
                final tmpState = File('$statePath.tmp');
                if (await tmpState.exists()) await tmpState.delete();
              } catch (e, st) {
                LoggingService.logger('DownloadProvider')
                    .fine('Failed to delete corrupt state file: $e', e, st);
              }
              task = task.copyWith(
                downloadedBytes: 0,
                chunks: List<double>.filled(
                  task.threadCount > 0 ? task.threadCount : 1,
                  0.0,
                ),
              );
            }
          }
        }
      }

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
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
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
            } catch (e, st) {
              LoggingService.logger('DownloadProvider')
                  .warning('Operation failed', e, st);
            }
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
          } catch (e, st) {
            LoggingService.logger('DownloadProvider')
                .warning('Operation failed', e, st);
          }
        }
      }

      if (task.isTorrent) {
        // FIX-TORR-RETRY: also remove the stale native handle from _torrentIds
        // so the next resume does not attempt to reuse a dead torrent handle.
        final staleTorrentId = _torrentIds.remove(task.id);
        if (staleTorrentId != null) {
          _latestTorrentStats.remove(staleTorrentId);
          try {
            TorrentService.pauseTorrent(staleTorrentId);
            TorrentService.removeTorrent(staleTorrentId, deleteFiles: false);
          } catch (e, st) {
            LoggingService.logger('DownloadProvider')
                .warning('Operation failed', e, st);
          }
        }
        unawaited(TorrentResumeStore.deleteResumeDataForSource(task.url)
            .catchError((e) {
          _log.warning('Failed to delete resume data for torrent source', e);
        }));
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
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
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
        final resolvedTotal =
            totalFromFiles > 0 ? totalFromFiles : realBytesOnDisk;
        realBytesOnDisk = task.resolvedFileSize > 0
            ? resolvedTotal.clamp(0, task.resolvedFileSize)
            : max(0, resolvedTotal);
        debugPrint(
            '[FIX-T2] Torrent retry: using per-file total=$realBytesOnDisk');
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

    final finalDownloadedBytes = task.hasMergedAudio
        ? (videoOnlySize > 0 ? videoBytes.clamp(0, videoOnlySize) : videoBytes)
        : realBytesOnDisk;

    await _setTask(
      task.copyWith(
        status: DownloadStatus.queued,
        downloadedBytes:
            shouldResetAllProgressMetadata ? 0 : finalDownloadedBytes,
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
        clearRecoveryHint: true, // FIX RT-1b: clear stale hint on retry
        clearPauseReason: true,
        cycleState: CycleState.starting,
        clearPreviousCycleState: true,
        pausedByUser: false,
        videoStreamSize: shouldResetAllProgressMetadata
            ? 0
            : task.videoStreamSize, // FIX RT-4
        audioDownloadedBytes: shouldResetAllProgressMetadata
            ? 0
            : audioBytes, // FIX RT-4 / BUG 2 FIX
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
    final stateBytes =
        await actualDownloadedBytes(tempFilePath, threadCount: threadCount);

    // Zero-fill detection: sample file at start, middle, end
    if (stateBytes > 0) {
      if (!Platform.environment.containsKey('FLUTTER_TEST')) {
        final file = File(tempFilePath);
        if (await file.exists()) {
          final fileLen = await file.length();
          if (fileLen > 0) {
            final raf = await file.open(mode: FileMode.read);
            try {
              // Check first 4KB
              final head = await raf.read(min(4096, fileLen));
              final headHasContent = head.any((b) => b != 0);

              // Check middle 4KB
              await raf.setPosition(fileLen ~/ 2);
              final mid = await raf.read(min(4096, fileLen ~/ 2));
              final midHasContent = mid.any((b) => b != 0);

              // Check last 4KB
              await raf.setPosition(max(0, fileLen - 4096));
              final tail = await raf.read(min(4096, fileLen));
              final tailHasContent = tail.any((b) => b != 0);

              if (!headHasContent && !midHasContent && !tailHasContent) {
                debugPrint('[DMX] Zero-fill detected, resetting to 0');
                return 0;
              }
            } finally {
              await raf.close();
            }
          }
        }
      }
      return stateBytes;
    }

    final state = await StateStore.load(tempFilePath);
    if (state != null && state.downloadedBytes > 0) {
      return state.downloadedBytes;
    }

    return 0;
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

  /// Centralized per-task state cleanup to prevent memory leaks.
  void _cleanupTaskState(String id) {
    final token = _cancelTokens.remove(id);
    if (token != null && !token.isCancelled) {
      try {
        token.cancel('cleaned_up');
      } catch (e, st) {
        LoggingService.logger('DownloadProvider')
            .warning('Operation failed', e, st);
      }
    }
    _taskLocks.remove(id);
    _lastTaskOpTimes.remove(id);
    _inFlightTaskOps.remove(id);
    _speedHistories.remove(id);
    _uploadSpeedHistories.remove(id);
    _progressNotifiers.remove(id)?.dispose();
    _speedNotifiers.remove(id)?.dispose();
    _lastProgressUpdateTimes.remove(id);
    _lastDbSaveTimes.remove(id);
    _lastDbSaveBytes.remove(id);
    _pendingProgressUpdates.remove(id);
    effectiveThreadOverrides.remove(id);
    _retryCounts.remove(id);
    _resumeRejectionRestarts.remove(id);
    _ytLowSpeedCounts.remove(id);
    _ytThrottlingRefreshing.remove(id);
    _retryTimers[id]?.cancel();
    _retryTimers.remove(id);
    _lastTorrentFileDiskSync.remove(id);
    _downloadMetrics.remove(id);
    _dbRetryCounts.remove(id);
    _dbRetryTimers[id]?.cancel();
    _dbRetryTimers.remove(id);
    _needsForcedPauseOnRegister.remove(id);
    _flushingIds.remove(id);
    _activeFutures.remove(id);
    disposeTaskNotifier(id);
    StateStore.removeTaskState(id);
    _orchestrator.cleanupTaskState(id);
  }

  Future<void> deleteTask(String id, {bool deleteFiles = false}) async {
    // FIX-P0-01: Guard task state mutations with synchronized lock
    return _lockFor(id).synchronized(() async {
      final task = _findTask(id);
      if (task == null) return;
      final taskSnapshot = task;
      final int? resolvedTorrentId = _resolveTorrentId(task);

      // FIX-X-05: Cancel notification immediately on delete
      final notifId = _notifications.idFor(id);
      _notifications.cancelNotification(notifId);
      _notifications.cancelForTask(id);

      // 1. Cancel the token IMMEDIATELY and wait for active future safely
      final token = _cancelTokens[id];
      if (token != null && !token.isCancelled) {
        try {
          token.cancel('deleted');
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
      }

      final activeFuture = _activeFutures[id];
      if (activeFuture != null) {
        try {
          await activeFuture.timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              debugPrint(
                  '[DMX] deleteTask: Future timeout for $id, proceeding');
            },
          );
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
      }
      _activeFutures.remove(id);

      // 2. For torrents, pause + remove from session IMMEDIATELY
      if (task.isTorrent) {
        // FIX-P2-02: Deterministically dispose the torrent subscription on
        // delete instead of relying on WeakReference GC cleanup.
        if (resolvedTorrentId != null) {
          try {
            TorrentSubscriptionRegistry.instance.dispose(resolvedTorrentId);
          } catch (e) {
            _log.fine(
                'No active subscription to dispose for $resolvedTorrentId: $e');
          }
        }
        if (resolvedTorrentId != null &&
            TorrentService.isTorrentAlive(resolvedTorrentId)) {
          // FIX-B10: Guard with alive check
          try {
            // FIX-C: forceStopTorrent verifies the engine actually halted
            // before we wipe the DB row.
            await TorrentService.forceStopTorrent(resolvedTorrentId);

            // WAIT for engine to confirm stop (up to 3 seconds)
            final stopDeadline = DateTime.now().add(const Duration(seconds: 3));
            while (DateTime.now().isBefore(stopDeadline)) {
              if (!TorrentService.isTorrentAlive(resolvedTorrentId)) break;
              final stats = TorrentService.latestStats[resolvedTorrentId];
              if (stats == null) break;
              final label = stats.stateLabel.toLowerCase();
              if (label.contains('paused') || label.contains('stopped')) break;
              await Future.delayed(const Duration(milliseconds: 100));
            }

            TorrentService.removeTorrent(
              resolvedTorrentId,
              deleteFiles: deleteFiles,
              deleteResumeData: true,
            );
          } catch (e) {
            _log.warning('[deleteTask] Torrent cleanup failed: $e');
          }
          try {
            await TorrentResumeStore.deleteResumeDataForSource(task.url);
            await TorrentResumeStore.delete(resolvedTorrentId);
          } catch (e) {
            _log.warning(
                'Explicit resume data cleanup failed for ${task.id}: $e');
          }
          _torrentIds.remove(id);
          providerTorrentIds.remove(id);
        } else {
          try {
            await TorrentResumeStore.deleteResumeDataForSource(task.url);
            if (resolvedTorrentId != null) {
              await TorrentResumeStore.delete(resolvedTorrentId);
            }
          } catch (e) {
            _log.warning(
                'Explicit resume data cleanup failed for ${task.id}: $e');
          }
          _torrentIds.remove(id);
          providerTorrentIds.remove(id);
        }
      }

      // 3. Remove from UI IMMEDIATELY (optimistic update)
      _tasks.removeWhere((t) => t.id == id);
      filteredTasksDirty = true;
      // FIX-DELETE-2: Cancel video/audio sub-tokens too before removing.
      // Previously only the primary token was removed (not cancelled), so
      // whenCancel hooks in TorrentDownloadOrchestrator never fired.
      for (final suffix in ['::video', '::audio', '']) {
        final k = suffix.isEmpty ? id : '$id$suffix';
        try {
          _cancelTokens[k]?.cancel('deleted');
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
        _cancelTokens.remove(k);
      }
      _cleanupTaskState(id);

      notifyListeners();

      // 4. Remove notification IMMEDIATELY
      _notifications.cleanupTask(id);

      // 5. Delete from DB (with retries)
      bool dbDeleteSucceeded = false;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await _databaseService.deleteTask(id);
          dbDeleteSucceeded = true;
          break;
        } catch (e) {
          debugPrint('[DMX] deleteTask DB attempt ${attempt + 1} failed: $e');
          if (attempt < 2) {
            await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
          }
        }
      }

      if (!dbDeleteSucceeded) {
        debugPrint(
            '[DMX] M3: All DB delete attempts failed for $id. Re-adding task with delete error.');
        final failedTask = task.copyWith(
          status: DownloadStatus.failed,
          errorMessage: 'Database deletion failed. Tap delete to retry.',
          speed: 0,
          clearEta: true,
        );
        try {
          await _databaseService.saveTask(failedTask);
        } catch (e) {
          _log.warning('Failed to save failedTask ${failedTask.id}', e);
          DiagnosticService.instance.record(
            'db_save',
            'Failed to save task ${failedTask.id}',
            error: e,
          );
        }
        if (!_tasks.any((t) => t.id == id)) {
          _tasks.add(failedTask);
          filteredTasksDirty = true;
          notifyListeners();
        }
      }

      // 6. Heavy cleanup in BACKGROUND
      // FIX-DELETE-3: Pass the pre-captured future reference and torrentId
      // FIX #7: Track pending delete cleanups
      final cleanupFuture = _backgroundDeleteCleanup(
              taskSnapshot, deleteFiles, activeFuture, resolvedTorrentId)
          .catchError((e) {
        _log.warning('Background delete cleanup failed', e);
      });
      _pendingDeleteCleanups.add(cleanupFuture);
      cleanupFuture.whenComplete(() {
        _pendingDeleteCleanups.remove(cleanupFuture);
      });

      updateActualTorrentUploadLimit();
      pumpQueue();

      if (activeOrSeedingCount == 0) {
        BackgroundService.stop();
        _stopWidgetTimer();
      }

      _updateTelemetryWidget(force: true);
    });
  }

  /// Runs file cleanup without blocking the UI thread.
  /// [capturedFuture] is the activeFuture captured BEFORE it was removed from
  /// _activeFutures, so this method can actually await download completion.
  Future<void> _backgroundDeleteCleanup(DownloadTask task, bool deleteFiles,
      [Future<void>? capturedFuture, int? torrentId]) async {
    try {
      // Verify no active torrent handle is still writing
      final tid = torrentId ?? _torrentIds[task.id];
      if (tid != null && TorrentService.isTorrentAlive(tid)) {
        try {
          await TorrentService.forceStopTorrent(tid);
          await Future.delayed(const Duration(milliseconds: 500));
        } catch (_) {}
      }

      // FIX-DELETE-3: Use the pre-captured future; the map entry was removed
      // before this method is called, so _activeFutures[task.id] is always null.
      final future = capturedFuture ?? _activeFutures[task.id];
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
          for (int attempt = 0; attempt < 3; attempt++) {
            try {
              await Isolate.run(() => File(task.localFilePath).delete());
              break;
            } on FileSystemException catch (e) {
              if (attempt < 2) {
                await Future.delayed(const Duration(milliseconds: 300));
                continue;
              }
              _log.warning(
                  'Failed to delete large file after 3 attempts: ${e.message}');
            } catch (e) {
              _log.warning('Failed to delete large file: $e');
              break;
            }
          }
        } else {
          for (int attempt = 0; attempt < 3; attempt++) {
            try {
              await localFile.delete();
              break;
            } on FileSystemException catch (e) {
              if (attempt < 2) {
                await Future.delayed(const Duration(milliseconds: 300));
                continue;
              }
              _log.warning('Failed to delete after 3 attempts: ${e.message}');
            } catch (e) {
              _log.warning('Failed to delete localFile: $e');
              break;
            }
          }
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
              for (int attempt = 0; attempt < 3; attempt++) {
                try {
                  await file.delete();
                  break;
                } on FileSystemException catch (e) {
                  if (attempt < 2) {
                    await Future.delayed(const Duration(milliseconds: 300));
                    continue;
                  }
                  _log.warning(
                      'Failed to delete torrent file segment after 3 attempts: ${e.message}');
                } catch (e) {
                  break;
                }
              }
            }
          } catch (e) {
            debugPrint(
              'Failed to delete torrent file segment $relPath: $e',
            );
          }
        }
      }

      // Remove empty torrent directory
      try {
        final torrentDirPath = p.normalize(p.join(root, task.fileName));
        if (p.isWithin(root, torrentDirPath)) {
          final torrentDir = Directory(torrentDirPath);
          if (await torrentDir.exists()) {
            final remaining = await torrentDir.list().toList();
            if (remaining.isEmpty) {
              await torrentDir.delete();
              _log.info('Deleted empty torrent directory: $torrentDirPath');
            }
          }
        }
      } catch (e) {
        _log.warning('Failed to delete empty torrent directory: $e');
      }
    }
  }

  Future<void> clearHistoryTasks(List<String> ids) async {
    for (final id in ids) {
      _cancelTokens.remove(id);
      _speedHistories.remove(id);
      _uploadSpeedHistories.remove(id);
      _progressNotifiers.remove(id)?.dispose();
      _speedNotifiers.remove(id)?.dispose();
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

      _cleanupTaskState(id);
      _tasks.removeWhere((task) => task.id == id);

      final torrentId = _torrentIds[id];
      if (torrentId != null) {
        TorrentService.removeTorrent(torrentId, deleteFiles: false);
        _torrentIds.remove(id);
      }

      _notifications.cleanupTask(id);
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
    // Rule 1: Completed / Failed tasks are immutable unless explicitly enqueued for retry
    if ((live.status == DownloadStatus.completed ||
            live.status == DownloadStatus.failed) &&
        incoming.status != live.status &&
        incoming.status != DownloadStatus.queued &&
        incoming.status != DownloadStatus.downloading) {
      if (incoming.downloadedBytes > live.downloadedBytes &&
          incoming.status == live.status) {
        return incoming;
      }
      return live;
    }

    // Rule 2: Automatic state updates cannot un-pause a task if incoming still has pausedByUser == true
    if (live.pausedByUser &&
        incoming.pausedByUser &&
        live.status == DownloadStatus.paused &&
        incoming.status != DownloadStatus.paused &&
        incoming.status != DownloadStatus.downloading) {
      if (incoming.downloadedBytes > live.downloadedBytes) {
        return incoming.copyWith(
          status: DownloadStatus.paused,
          pausedByUser: true,
        );
      }
      return live;
    }

    // Rule 3: Protect merging status from stale downloading snapshots
    if ((live.status == DownloadStatus.paused ||
            live.status == DownloadStatus.failed ||
            live.status == DownloadStatus.merging) &&
        incoming.status == DownloadStatus.downloading) {
      return live;
    }

    final audioUrlChanged = incoming.mergedAudioUrl != live.mergedAudioUrl;
    final isReset = incoming.downloadedBytes == 0 &&
        (incoming.status == DownloadStatus.queued ||
            incoming.status == DownloadStatus.failed ||
            (incoming.status == DownloadStatus.downloading &&
                live.downloadedBytes > 0) ||
            (incoming.audioProgress == 0.0 && audioUrlChanged));
    if (isReset) return incoming;

    // Audio URL changed while queued — reset audio progress
    if (audioUrlChanged &&
        incoming.status == DownloadStatus.queued &&
        live.audioProgress > 0) {
      return incoming.copyWith(
        audioProgress: 0.0,
        audioDownloadedBytes: 0,
      );
    }

    // Rule 5: For progress ticks during active download, accept larger progress
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
    if (prev.status == DownloadStatus.completed &&
        updated.status != DownloadStatus.completed) {
      // Allow completed → paused ONLY for seeding torrents being paused
      final isSeedingPause = prev.isTorrent &&
          prev.seedingEnabled &&
          updated.status == DownloadStatus.paused;

      // Allow completed → queued/downloading for explicit retry/re-download
      final isExplicitRestart = updated.status == DownloadStatus.queued ||
          updated.status == DownloadStatus.downloading;

      if (!isSeedingPause && !isExplicitRestart) {
        _log.warning(
          'Blocked stale update for completed task ${updated.id}: '
          '${prev.status} -> ${updated.status}.',
        );
        return;
      }
    }
    if (prev.status != updated.status) {
      if (!DownloadStateMachine.canTransitionStatus(
          prev.status, updated.status)) {
        // Seeding pause is now allowed (Fix #1), so this should not fire.
        // Keep as fine-level for any other unexpected transitions.
        _log.fine(
          'Blocked status transition for task ${updated.id}: '
          '${prev.status} -> ${updated.status}. Retaining ${prev.status}.',
        );
        updated = updated.copyWith(status: prev.status);
      }
    }

    // ERR-RESILIENCE-1.2: When a task transitions to failed, ensure it always
    // carries a FailureCategory + recovery hint so the UI can present a
    // consistent, actionable recovery path. Derived from the current fields so
    // this works even when the failure came from a path that only set an
    // errorMessage.
    if (updated.status == DownloadStatus.failed &&
        updated.failureCategory == null) {
      updated = updated.copyWith(
        failureCategory: FailureCategory.unknown,
        recoveryHint: RecoveryHints.hintFor(FailureCategory.unknown),
        cycleState: CycleState.failed,
      );
    } else if (updated.status == DownloadStatus.failed &&
        updated.recoveryHint == null) {
      updated = updated.copyWith(
        recoveryHint: RecoveryHints.hintFor(updated.failureCategory!),
        cycleState: CycleState.failed,
      );
    } else if (updated.status == DownloadStatus.failed) {
      // failureCategory and recoveryHint already present — just stamp cycleState
      if (updated.cycleState != CycleState.failed) {
        updated = updated.copyWith(cycleState: CycleState.failed);
      }
    }

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
          } catch (e, st) {
            LoggingService.logger('DownloadProvider')
                .warning('Operation failed', e, st);
          }
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

    await _saveTaskToDbInternal(updated);
  }

  Future<void> _saveTaskToDbInternal(DownloadTask updated) async {
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
          pauseTask(active[i].id, reason: PauseReason.batterySaver);
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
    unawaited(_pushWidgetData(force: force).catchError((e) {
      _log.warning('Failed to push widget data', e);
    }));
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
    if (_widgetTimer != null && _widgetTimer!.isActive) return;
    _widgetTimer?.cancel();
    // FIX-M7: Periodic cleanup of inactive speed histories every 5 minutes
    _speedHistoryCleanupTimer ??= Timer.periodic(
      const Duration(minutes: 5),
      (_) => _cleanupInactiveSpeedHistories(),
    );
    final hasActive = downloadingTasksCount > 0 || seedingTasksCount > 0;

    FrameWatchdog.setDownloadingTasksCount(downloadingTasksCount);
    BackgroundService.reconcileActiveTaskIds(
      _tasks
          .where((t) =>
              t.status == DownloadStatus.downloading ||
              (t.status == DownloadStatus.completed &&
                  t.isTorrent &&
                  t.seedingEnabled))
          .map((t) => t.id)
          .toSet(),
    );
    PowerMonitor.setDownloadActive(hasActive);

    if (!hasActive) {
      if (PowerMonitor.screenOff) {
        _stopWidgetTimer();
      }
      return;
    }

    final int timerIntervalSec =
        (DownloadEngine.isInBackground || PowerMonitor.screenOff)
            ? 30
            : BackgroundGate.adaptInterval(
                const Duration(seconds: 5),
              ).inSeconds;

    _widgetTimer = Timer.periodic(Duration(seconds: timerIntervalSec), (timer) {
      if (_disposed || !BackgroundGate.shouldWriteState) {
        timer.cancel();
        return;
      }

      unawaited(_pushWidgetData().catchError((e) {
        _log.warning('Failed to push widget data', e);
      }));

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

      // ERR-RESILIENCE-2.3: Periodic state-file integrity check (~60s).
      // Verifies every active download's .dmxstate is parseable; unrecoverable
      // corrupt states are reported and the task paused rather than silently
      // resumed against a broken state file.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - _lastIntegrityCheckMs >= 60000) {
        _lastIntegrityCheckMs = nowMs;
        unawaited(_verifyActiveStatesIntegrity().catchError((e) {
          _log.warning('Integrity check failed', e);
        }));
      }

      // Coalesce notifyListeners() calls from _setTask progress-only updates
      // so widgets rebuild at most once per timer tick instead of on every tick.
      final shouldNotify = _notifyPending || updateSeedingSpeeds();
      _notifyPending = false;
      if (shouldNotify && DownloadEngine.appInForeground) {
        notifyListeners();
      }
    });
  }

  void _stopWidgetTimer() {
    _widgetTimer?.cancel();
    _widgetTimer = null;
    BackgroundService.reconcileActiveTaskIds(const <String>{});
    PowerMonitor.setDownloadActive(false);
  }

  /// ERR-RESILIENCE-2.3: Periodic .dmxstate integrity sweep. For each active
  /// (non-torrent) download, confirm the state file is parseable; if it is
  /// corrupt and the journal cannot recover it, pause the task with a clear
  /// message instead of silently resuming from broken state.
  Future<void> _verifyActiveStatesIntegrity() async {
    if (_disposed) return;
    for (var i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      if (task.status != DownloadStatus.downloading || task.isTorrent) continue;
      if (task.downloadedBytes <= 0) continue;
      final statePath = '${task.tempFilePath}.dmxstate';
      final journalPath = '${task.tempFilePath}.journal';
      try {
        final stateFile = File(statePath);
        if (!await stateFile.exists()) continue;
        final content = await stateFile.readAsString();
        jsonDecode(content);
      } catch (e) {
        // State unparseable. Try journal recovery before declaring it broken.
        debugPrint(
          '[DMX] Integrity check: corrupt state for ${task.id}: $e',
        );
        try {
          final recovered = await DownloadJournal.recover(journalPath);
          if (recovered != null && recovered.isNotEmpty) {
            debugPrint(
              '[DMX] Integrity check: journal recovered ${task.id}',
            );
            continue;
          }
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
        _tasks[i] = task.copyWith(
          status: DownloadStatus.paused,
          speed: 0,
          clearEta: true,
          errorMessage:
              'Download state file was corrupted. Tap Resume to re-validate and continue.',
        );
        unawaited(_databaseService.saveTask(_tasks[i]).catchError((e) {
          _log.warning(
              'Failed to save task during integrity check recovery', e);
        }));
      }
    }
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

    // Delete the state file so the next resume starts a fresh identity
    // check against the new URL instead of the stale etag/url.
    if (!task.isTorrent && task.tempFilePath.isNotEmpty) {
      for (final p in [
        '${task.tempFilePath}.dmxstate',
        '${task.tempFilePath}.dmxstate.tmp',
      ]) {
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
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
          } catch (e, st) {
            LoggingService.logger('DownloadProvider')
                .warning('Operation failed', e, st);
          }
        }
        return false;
      }

      final wasTorrent = task.isTorrent;
      final isNewTorrent = cleanUrl.startsWith('magnet:') ||
          cleanUrl.toLowerCase().endsWith('.torrent');

      if (wasTorrent || isNewTorrent) {
        final torrentId = _torrentIds[taskId];
        if (torrentId != null) {
          // URL changed: resume data is invalidated below via TorrentResumeStore.deleteResumeDataForSource.
          // Pass deleteResumeData: false to avoid a double-delete race.
          TorrentService.removeTorrent(torrentId,
              deleteFiles: false, deleteResumeData: false);
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
          final t = _findTask(taskId);
          if (t != null && !t.pausedByUser) {
            await resumeTask(taskId);
          }
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
                final t = _findTask(taskId);
                if (t != null && !t.pausedByUser) {
                  await resumeTask(taskId);
                }
              }
              return;
            }
          }
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
      }

      if (newFileSize == null && !isRefresh) {
        try {
          metadata = await _downloadEngine.resolveMetadata(
            url: cleanUrl,
            requestedFileName: task.fileName,
            customUserAgent: _settingsProvider.customUserAgent,
            referer: task.downloadPageUrl,
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
      if (task.downloadedBytes > 0 &&
          resolvedFileSize > 0 &&
          task.fileSize > 0) {
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
            final meta = await _downloadEngine.resolveMetadata(
              url: cleanUrl,
              referer: task.downloadPageUrl,
            );
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

          // FIX-C3: Use percentage-based tolerance and ETag mismatch check
          final tolerance =
              (task.fileSize * 0.01).clamp(1024.0, 10.0 * 1024 * 1024);
          String? storedEtag;
          if (task.tempFilePath.isNotEmpty) {
            final sf = File('${task.tempFilePath}.dmxstate');
            if (await sf.exists()) {
              try {
                final dec = jsonDecode(await sf.readAsString());
                if (dec is Map) storedEtag = dec['etag'] as String?;
              } catch (e, st) {
                LoggingService.logger('DownloadProvider')
                    .warning('Operation failed', e, st);
              }
            }
          }
          final etagMismatch = metadata?.etag != null &&
              metadata!.etag!.isNotEmpty &&
              storedEtag != null &&
              storedEtag.isNotEmpty &&
              metadata.etag != storedEtag;
          if ((resolvedMetaSize > 0 &&
                  task.fileSize > 0 &&
                  (resolvedMetaSize - task.fileSize).abs() > tolerance) ||
              etagMismatch) {
            sizeChanged = true;

            debugPrint(
              '[DMX] FIX-C3: URL update: size or etag changed, resetting progress',
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
            referer: task.downloadPageUrl,
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
              } catch (e, st) {
                LoggingService.logger('DownloadProvider')
                    .warning('Operation failed', e, st);
              }
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
            } catch (e, st) {
              LoggingService.logger('DownloadProvider')
                  .warning('Operation failed', e, st);
            }
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
      } else if (!isSameResource && !isRefresh) {
        // Delete all .dmxstate and audio sidecars on manual URL change (FIX-02)
        for (final path in [
          task.tempFilePath,
          '${task.tempFilePath}.dmxstate',
          '${task.tempFilePath}.dmxstate.tmp',
          '${task.tempFilePath}.journal',
          '${task.tempFilePath}.audio',
          '${task.tempFilePath}.audio.dmxstate',
          '${task.tempFilePath}.audio.journal',
          '${task.tempFilePath}.audio.itag',
        ]) {
          try {
            final f = File(path);
            if (await f.exists()) await f.delete();
          } catch (e, st) {
            LoggingService.logger('DownloadProvider')
                .warning('Operation failed', e, st);
          }
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
      final clampedBytes = sizeChanged
          ? 0
          : (resolvedNewFileSize > 0
              ? task.downloadedBytes.clamp(0, resolvedNewFileSize)
              : max(0, task.downloadedBytes));

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
        final t = _findTask(taskId);
        if (t != null && !t.pausedByUser) {
          await resumeTask(taskId);
        }
      }
    } catch (e) {
      if (wasDownloading) {
        final t = _findTask(taskId);
        if (t != null && !t.pausedByUser) {
          unawaited(resumeTask(taskId).catchError((e) {
            _log.warning('Failed to resume task from YT throttle refresh', e);
          }));
        }
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

    // Clear state files before URL change so old chunk sizes are not reused
    if (task.tempFilePath.isNotEmpty) {
      await StateStore.remove(task.tempFilePath);
      final audioPath = '${task.tempFilePath}.audio';
      await StateStore.remove(audioPath);
    }

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

    // FIX YT-2: Reject webpage URLs when refreshing YouTube streams
    if (isYoutube && _orchestrator.shouldRejectResolvedYoutubeUrl(newUrl)) {
      throw Exception('Backend returned page URL, not stream URL: $newUrl');
    }

    if (!isYoutube && !task.isTorrent) {
      try {
        final meta = await _downloadEngine.resolveMetadata(
          url: newUrl,
          referer: task.downloadPageUrl,
        );
        String? storedEtag;
        if (task.tempFilePath.isNotEmpty) {
          final sf = File('${task.tempFilePath}.dmxstate');
          if (await sf.exists()) {
            try {
              final dec = jsonDecode(await sf.readAsString());
              if (dec is Map) storedEtag = dec['etag'] as String?;
            } catch (e, st) {
              LoggingService.logger('DownloadProvider')
                  .warning('Operation failed', e, st);
            }
          }
        }
        // FIX-C3: If Content-Length differs by >1% OR if ETag present and differs from stored etag, call startOverTask
        final sizeMismatch = meta.fileSize > 0 &&
            task.fileSize > 0 &&
            (meta.fileSize - task.fileSize).abs() > (task.fileSize * 0.01);
        final etagMismatch = meta.etag != null &&
            meta.etag!.isNotEmpty &&
            storedEtag != null &&
            storedEtag.isNotEmpty &&
            meta.etag != storedEtag;
        if (sizeMismatch || etagMismatch) {
          debugPrint(
            '[DMX] FIX-C3: Content-identity check in updateTaskUrlAndResume failed (size diff: $sizeMismatch, etag diff: $etagMismatch). Starting over.',
          );
          await startOverTask(id, newUrl,
              newAudioUrl: newAudioUrl, deleteTempFiles: true);
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
          } catch (e, st) {
            LoggingService.logger('DownloadProvider')
                .warning('Operation failed', e, st);
          }
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
      } else if (updated != null) {
        await _setTask(updated.copyWith(
          status: DownloadStatus.downloading,
          clearStatusMessage: true, // ← FIX: clear "updating_links" message
        ));
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
        // FIX: Bound the wait so a stale/leaked active future (e.g. an
        // early-return placeholder) can never hang the restart indefinitely.
        await activeFuture.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            debugPrint(
                '[DMX] startOverTask: activeFuture timed out for $id, proceeding');
          },
        );
        // ignore: avoid_catches_without_on_clauses
      } catch (e) {
        debugPrint('[DMX] activeFuture error in cancel: $e');
      }
    }

    final torrentId = _torrentIds[id];
    if (torrentId != null) {
      TorrentService.removeTorrent(torrentId, deleteFiles: false);
      _torrentIds.remove(id);
      unawaited(TorrentResumeStore.delete(torrentId).catchError((e) {
        _log.warning('Failed to delete TorrentResumeStore entry', e);
      })); // FIX-9: Clear TorrentResumeStore
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
        } catch (e, st) {
          LoggingService.logger('DownloadProvider')
              .warning('Operation failed', e, st);
        }
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
          } catch (e, st) {
            LoggingService.logger('DownloadProvider')
                .warning('Operation failed', e, st);
          }
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

    if (_pendingDeleteCleanups.isNotEmpty) {
      _log.info(
          'Waiting for ${_pendingDeleteCleanups.length} pending delete cleanups');
      // Best-effort: give cleanups 3 seconds to finish
      Future.wait(_pendingDeleteCleanups)
          .timeout(const Duration(seconds: 3))
          .catchError((_) => <void>[]);
    }

    AppLifecycleCoordinator.removeOnResumedCallback(forceEmitAllProgress);
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
    _widgetTimer?.cancel();
    // FIX-M7: Cancel speed history cleanup timer
    _speedHistoryCleanupTimer?.cancel();
    _speedHistoryCleanupTimer = null;

    // Cancel all active download tokens
    for (final token in _cancelTokens.values) {
      token.cancel('provider disposed');
    }
    _cancelTokens.clear();
    _activeFutures.clear();

    // Clear ALL tracking maps
    _speedHistories.clear();
    _uploadSpeedHistories.clear();
    _lastProgressUpdateTimes.clear();
    _lastDbSaveTimes.clear();
    _lastDbSaveBytes.clear();
    _pendingProgressUpdates.clear();
    // FIX-P0-01: Clear task locks on disposal
    _taskLocks.clear();
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
        (_) => unawaited(_downloadEngine.close().catchError(
            (e) => _log.warning('Failed to close engine after wait', e))),
        onError: (_) => unawaited(_downloadEngine.close().catchError(
            (e) => _log.warning('Failed to close engine on error', e))),
      );
    } else {
      unawaited(_downloadEngine
          .close()
          .catchError((e) => _log.warning('Failed to close engine', e)));
    }

    _latestTorrentStats.clear();
    for (final notifier in _progressNotifiers.values) {
      notifier.dispose();
    }
    _progressNotifiers.clear();
    for (final notifier in _speedNotifiers.values) {
      notifier.dispose();
    }
    _speedNotifiers.clear();
    progressRevision.dispose();
    lastSaveError.dispose();
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
    final now = DateTime.now();

    final candidates = _tasks.where((t) {
      // FIX-H6: Skip tasks where pausedByUser, waitingWifi, waitingNetwork, or scheduled in future
      final isPaused = t.status == DownloadStatus.paused;
      if (!isPaused) return false;
      if (t.isCancelled) return false;
      if (t.pausedByUser) return false;
      if (t.waitingWifi ||
          t.errorMessage == DownloadStatusMessages.waitingWifi ||
          t.statusMessage == DownloadStatusMessages.waitingWifi) {
        return false;
      }
      if (t.waitingNetwork ||
          t.errorMessage == DownloadStatusMessages.waitingNetwork ||
          t.statusMessage == DownloadStatusMessages.waitingNetwork) {
        return false;
      }
      if (t.scheduledAt != null && t.scheduledAt!.isAfter(now)) {
        return false;
      }
      return true;
    }).toList();

    var updatedAny = false;
    for (var task in candidates) {
      // FIX v2.0.0: Torrents use libtorrent fast-resume, not .dmxstate.
      if (task.isTorrent) continue;
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

  static bool youtubeStreamIdentityChanged(String oldUrl, String newUrl) {
    try {
      final oldUri = Uri.tryParse(oldUrl);
      final newUri = Uri.tryParse(newUrl);
      if (oldUri == null || newUri == null) return false;

      final oldItag = oldUri.queryParameters['itag'];
      final newItag = newUri.queryParameters['itag'];
      final oldMime = oldUri.queryParameters['mime'];
      final newMime = newUri.queryParameters['mime'];
      final oldClen = oldUri.queryParameters['clen'];
      final newClen = newUri.queryParameters['clen'];

      // If any identity param exists on both sides and differs → changed
      if (oldItag != null && newItag != null && oldItag != newItag) return true;
      if (oldMime != null && newMime != null && oldMime != newMime) return true;
      if (oldClen != null && newClen != null && oldClen != newClen) return true;

      // If clen matches, trust it (same stream, different CDN)
      if (oldClen != null && newClen != null) return false;

      // Fallback: if host differs AND no identity params match, assume changed
      if (oldUri.host != newUri.host) return true;

      return false;
    } catch (e, st) {
      LoggingService.logger('DownloadProvider')
          .warning('Operation failed with fallback', e, st);
      return false;
    }
  }

  /// Compares two torrent file lists for structural equality.
  bool _fileListsDiffer(
    List<Map<String, dynamic>>? a,
    List<Map<String, dynamic>>? b,
  ) {
    if (a == null && b == null) return false;
    if (a == null || b == null) return true;
    if (a.length != b.length) return true;
    for (int i = 0; i < a.length; i++) {
      final am = a[i];
      final bm = b[i];
      if (am['name'] != bm['name'] ||
          am['length'] != bm['length'] ||
          am['downloadedBytes'] != bm['downloadedBytes'] ||
          am['selected'] != bm['selected'] ||
          am['priority'] != bm['priority']) {
        return true;
      }
    }
    return false;
  }
}
