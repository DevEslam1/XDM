import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/interfaces/i_download_engine.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/download_engine.dart' hide DownloadCommand;
import '../../../core/services/download_metrics.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/power_monitor.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/services/update_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../settings/provider/settings_provider.dart';
import '../data/drift_task_snapshot_store.dart';
import '../domain/commands/download_commands.dart';
import '../domain/events/download_events.dart';
import '../domain/executor/task_executor.dart';
import '../models/download_add_spec.dart';
import '../models/download_state_machine.dart';
import '../models/download_task.dart';
import '../services/download_engine_adapter.dart';
import 'download_orchestrator.dart';
import 'mixins/download_backup_mixin.dart';
import 'mixins/download_filter_mixin.dart';
import 'mixins/download_queue_mixin.dart';
import 'mixins/download_torrent_mixin.dart';
import 'network_monitor.dart';
import 'notification_coordinator.dart';
import 'progress_emitter.dart';
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
    required DatabaseService databaseService, required SettingsProvider settingsProvider,
    IDownloadEngine? downloadEngine, PermissionService? permissionService,
    NotificationService? notificationService, bool enableBackgroundTimers = true,
  })  : _databaseService = databaseService, _settingsProvider = settingsProvider,
        _downloadEngine = downloadEngine ?? DownloadEngine(enableCleanupTimer: enableBackgroundTimers && !Platform.environment.containsKey('FLUTTER_TEST')),
        _permissionService = permissionService ?? PermissionService(),
        _notificationService = notificationService ?? NotificationService(),
        enableBackgroundTimers = enableBackgroundTimers && !Platform.environment.containsKey('FLUTTER_TEST') {
    _settingsProvider.addListener(_onSettingsChanged);
    _networkMonitor = NetworkMonitor(
      tasks: () => _tasks, torrentIds: () => _torrentIds, cancelTokens: () => _cancelTokens,
      activeFutures: () => _activeFutures, wifiOnly: () => _settingsProvider.wifiOnly,
      setTask: _setTask, pumpQueue: pumpQueue, onNetworkChanged: (cmd) => _executor.dispatch(cmd),
    );
    _scheduleManager = ScheduleManager(
      tasks: () => _tasks, databaseService: _databaseService, isDisposed: () => _disposed,
      downloadingTasksCount: () => downloadingTasksCount, updateTorrentUploadLimit: updateTorrentUploadLimit,
      notifyListeners: notifyListeners, pumpQueue: pumpQueue, onScheduleFired: (id) => _executor.dispatch(ScheduleFired(id)),
    );
    _notifications = NotificationCoordinator(
      notificationService: _notificationService, settingsProvider: _settingsProvider,
      downloadingTasksCount: () => downloadingTasksCount, currentDownloadSpeed: () => currentDownloadSpeed,
      findTask: _findTask, onPauseTask: pauseTask, onResumeTask: resumeTask, onCancelTask: cancelTask,
      onPauseAll: pauseAllTasks, onResumeAll: resumeAllTasks, onStopAll: pauseAllTasks, onStartAll: resumeAllTasks,
      onExitApp: () async => exit(0),
    );
    _orchestrator = DownloadOrchestrator(this);
    _engineAdapter = DownloadEngineAdapter(
      downloadEngine: _downloadEngine, findTask: _findTask, saveTask: _setTask, pumpQueueCallback: () => pumpQueue(),
    );
    _snapshotStore = DriftTaskSnapshotStore(
      databaseService: _databaseService, findTask: _findTask,
      onTaskUpdated: (updated) {
        final idx = _tasks.indexWhere((t) => t.id == updated.id);
        if (idx != -1) { _tasks[idx] = updated; } else { _tasks.add(updated); }
        filteredTasksDirty = true; notifyListeners();
      },
    );
    _executor = TaskExecutor(enginePort: _engineAdapter, snapshotStore: _snapshotStore, auditLog: _auditLog);
    _eventSubscription = _executor.events.listen(_onDomainEvent);
  }

  final DatabaseService _databaseService;
  final SettingsProvider _settingsProvider;
  final IDownloadEngine _downloadEngine;
  final PermissionService _permissionService;
  final NotificationService _notificationService;
  @override final bool enableBackgroundTimers;

  late final NetworkMonitor _networkMonitor;
  late final ScheduleManager _scheduleManager;
  late final NotificationCoordinator _notifications;
  late final DownloadOrchestrator _orchestrator;
  late final DownloadEngineAdapter _engineAdapter;
  late final DriftTaskSnapshotStore _snapshotStore;
  late final TaskExecutor _executor;
  final TransitionAuditLog _auditLog = TransitionAuditLog();
  final ProgressEmitter _progressEmitter = ProgressEmitter();
  StreamSubscription<DownloadEvent>? _eventSubscription;

  final List<DownloadTask> _tasks = [];
  bool _disposed = false;
  String? lastError;
  Timer? _widgetUpdateTimer;

  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, ({CancelToken video, CancelToken audio})> _orchestratorTokens = {};
  final Map<String, Future<void>> _activeFutures = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, int> _retryCounts = {};
  final Map<String, Queue<double>> _speedHistories = {};
  final Map<String, int> _lastProgressUpdateTimes = {}, _lastDbSaveTimes = {}, _lastDbSaveBytes = {}, _lastTorrentFileDiskSync = {};
  final Set<String> _pendingProgressUpdates = {};
  final Map<String, int> _ytLowSpeedCounts = {};
  final Map<String, bool> _ytThrottlingRefreshing = {};
  final Map<String, int> _torrentIds = {};
  final Map<int, TorrentUpdateInfo> _latestTorrentStats = {};
  final Map<String, bool> _resumeRejectionRestarts = {};
  final Map<String, DownloadMetrics> _downloadMetrics = {};

  @override List<DownloadTask> get providerTasks => _tasks;
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  TransitionAuditLog get auditLog => _auditLog;
  ScheduleManager get scheduleManager => _scheduleManager;
  @override NetworkMonitor get networkMonitor => _networkMonitor;
  @override NotificationCoordinator get notifications => _notifications;
  TaskExecutor get executor => _executor;
  PermissionService get permissionService => _permissionService;
  @override int get pendingStartCount => _orchestrator.pendingStartCount;
  @override bool get providerIsOnWifi => _networkMonitor.hasWifiOrEthernet;
  @override bool get providerIsCharging => PowerMonitor.isCharging;
  @override SettingsProvider get providerSettingsProvider => _settingsProvider;
  @override DatabaseService get providerDatabaseService => _databaseService;
  @override IDownloadEngine get downloadEngine => _downloadEngine;
  @override bool get providerDisposed => _disposed;
  @override Map<String, CancelToken> get cancelTokens => _cancelTokens;
  @override Map<String, ({CancelToken video, CancelToken audio})> get orchestratorTokens => _orchestratorTokens;
  @override Map<String, Future<void>> get activeFutures => _activeFutures;
  @override Map<String, Timer> get retryTimers => _retryTimers;
  @override Map<String, int> get retryCounts => _retryCounts;
  @override Map<String, Queue<double>> get speedHistories => _speedHistories;
  @override Map<String, int> get lastProgressUpdateTimes => _lastProgressUpdateTimes;
  @override Map<String, int> get lastDbSaveTimes => _lastDbSaveTimes;
  @override Map<String, int> get lastDbSaveBytes => _lastDbSaveBytes;
  @override Map<String, int> get lastTorrentFileDiskSync => _lastTorrentFileDiskSync;
  @override Set<String> get pendingProgressUpdates => _pendingProgressUpdates;
  @override Map<String, int> get ytLowSpeedCounts => _ytLowSpeedCounts;
  @override Map<String, bool> get ytThrottlingRefreshing => _ytThrottlingRefreshing;
  @override Map<String, int> get providerTorrentIds => _torrentIds;
  @override Map<int, TorrentUpdateInfo> get providerLatestTorrentStats => _latestTorrentStats;
  @override Map<String, bool> get resumeRejectionRestarts => _resumeRejectionRestarts;
  @override Map<String, DownloadMetrics> get downloadMetrics => _downloadMetrics;

  @override double get currentDownloadSpeed => _tasks.where((t) => t.status == DownloadStatus.downloading).fold(0.0, (s, t) => s + t.speed);
  int get totalDownloadedBytes => _tasks.fold(0, (s, t) => s + t.downloadedBytes);

  void _onSettingsChanged() => notifyListeners();
  void _onDomainEvent(DownloadEvent event) { filteredTasksDirty = true; notifyListeners(); }

  Future<void> load({bool pauseOrphanDownloads = true}) async {
    final loaded = await _databaseService.loadTasks();
    _tasks.clear();
    _tasks.addAll(loaded);
    filteredTasksDirty = true;
    notifyListeners();
    if (pauseOrphanDownloads) {
      for (var i = 0; i < _tasks.length; i++) {
        final t = _tasks[i];
        if (t.status == DownloadStatus.downloading) {
          await _applyStateChange(t.id, DomainDownloadState.paused, PauseTask(t.id, reason: 'orphan_recovery'), reason: 'orphan_recovery', pausedByUser: false);
        }
      }
    }
    _scheduleManager.setReady(true);
    await _networkMonitor.ensureInitialConnectivity();
    _autoResumeIncomplete();
  }

  void _autoResumeIncomplete() {
    for (final task in _tasks) {
      if (task.isCancelled || task.pausedByUser) continue;
      if (task.status == DownloadStatus.downloading) {
        resumeTask(task.id);
      } else if (task.status == DownloadStatus.paused) {
        final isWaitingWifi = task.errorMessage?.toLowerCase().contains('waiting for wifi') == true;
        final isWaitingNet = task.errorMessage?.toLowerCase().contains('waiting for network') == true;
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

  DownloadTask? _findTask(String id) {
    final idx = _tasks.indexWhere((t) => t.id == id);
    return idx != -1 ? _tasks[idx] : null;
  }

  @override DownloadTask? findTaskById(String id) => _findTask(id);
  DownloadTask? taskById(String id) => _findTask(id);
  bool isTaskOperationPending(String taskId) => false;
  bool get isLoadingTasks => false;
  bool get isReconciling => false;
  void setActiveTabIndex(int index) {}
  DownloadMetrics? getMetrics(String taskId) => _downloadMetrics[taskId];
  List<double> getSpeedHistory(String taskId) => _speedHistories[taskId]?.toList() ?? const [];
  List<double> getUploadSpeedHistory(String taskId) => const [];
  ValueNotifier<double> progressNotifier(String taskId) => _progressEmitter.progressNotifier(taskId);
  ValueNotifier<double> speedNotifier(String taskId) => _progressEmitter.speedNotifier(taskId);
  void disposeTaskNotifier(String taskId) => _progressEmitter.disposeTaskNotifier(taskId);
  void updateTorrentUploadLimit() => updateActualTorrentUploadLimit();

  static bool youtubeStreamIdentityChanged(String? oldUrl, String? newUrl) {
    if (oldUrl == null || newUrl == null || oldUrl == newUrl) return false;
    final oldUri = Uri.tryParse(oldUrl);
    final newUri = Uri.tryParse(newUrl);
    if (oldUri == null || newUri == null) return false;
    if (oldUri.host != newUri.host) return true;
    final oldId = oldUri.queryParameters['id'] ?? oldUri.queryParameters['docid'];
    final newId = newUri.queryParameters['id'] ?? newUri.queryParameters['docid'];
    final oldItag = oldUri.queryParameters['itag'];
    final newItag = newUri.queryParameters['itag'];
    return (oldId != null && newId != null && oldId != newId) ||
        (oldItag != null && newItag != null && oldItag != newItag);
  }

  static int torrentBytesFromFiles(List<Map<String, dynamic>>? files) =>
      files == null ? 0 : files.where((f) => f['selected'] != false).fold(0, (s, f) => s + ((f['downloadedBytes'] as num?)?.toInt() ?? 0));

  static int torrentSelectedFilesTotalSize(List<Map<String, dynamic>>? files) =>
      files == null ? 0 : files.where((f) => f['selected'] != false).fold(0, (s, f) => s + ((f['length'] as num?)?.toInt() ?? 0));

  static List<double> reconcileChunks({required List<double> stateChunks, required int actualBytesOnDisk, required int fileSize, required int threadCount}) {
    if (threadCount <= 0) return const [];
    if (fileSize <= 0) return List.filled(threadCount, 0.0);
    return List.filled(threadCount, (actualBytesOnDisk / fileSize).clamp(0.0, 1.0));
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

  Future<void> _setTask(DownloadTask task) async {
    final idx = _tasks.indexWhere((t) => t.id == task.id);
    if (idx != -1) { _tasks[idx] = task; } else { _tasks.add(task); }
    filteredTasksDirty = true;
    await _databaseService.saveTask(task);
    if (!DownloadEngine.isInBackground || !PowerMonitor.screenOff) notifyListeners();
  }

  @override
  Future<void> setTaskState(DownloadTask task) async {
    final existing = _findTask(task.id);
    final isProgressOnly = existing != null && existing.status == task.status && existing.status == DownloadStatus.downloading && existing.downloadedBytes != task.downloadedBytes;
    final idx = _tasks.indexWhere((t) => t.id == task.id);
    if (idx != -1) { _tasks[idx] = task; } else { _tasks.add(task); }
    filteredTasksDirty = true;
    if (isProgressOnly) {
      _pendingProgressUpdates.add(task.id);
    } else {
      _pendingProgressUpdates.remove(task.id);
      await _databaseService.saveTask(task);
    }
    if (!DownloadEngine.isInBackground || !PowerMonitor.screenOff) notifyListeners();
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
    String id, DomainDownloadState toState, DownloadCommand cmd, {
    String? reason, String? errorMessage, bool? pausedByUser, bool? isCancelled, String? pauseReason,
  }) async {
    final task = _findTask(id);
    if (task == null) return;
    DownloadStateMachine(taskId: id, initialState: DownloadStateMachine.fromStatus(task.status))
        .transition(toState, reason: reason ?? errorMessage);
    await _snapshotStore.onTaskStateChanged(
      id, DownloadStateMachine.fromStatus(task.status), toState, cmd,
      errorMessage: errorMessage, pausedByUser: pausedByUser, isCancelled: isCancelled, pauseReason: pauseReason,
    );
    final updated = _findTask(id);
    if (updated != null) {
      _tasks[_tasks.indexOf(updated)] = updated;
      filteredTasksDirty = true;
      notifyListeners();
    }
    pumpQueue();
  }

  Future<void> markCompletedFileMissing(String taskId) => _applyStateChange(
        taskId, DomainDownloadState.failed, CancelTask(taskId), errorMessage: 'File missing',
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

  Future<void> deleteMultipleTasks(List<String> ids, {bool deleteFiles = false}) async {
    for (final id in ids) { await deleteTask(id, deleteFiles: deleteFiles); }
  }

  Future<void> resumeMultipleTasks(List<String> ids) async {
    for (final id in ids) { await resumeTask(id); }
  }

  Future<void> pauseMultipleTasks(List<String> ids) async {
    for (final id in ids) { await pauseTask(id); }
  }

  Future<void> changeCategoryForMultipleTasks(List<String> ids, String category) async {
    for (final id in ids) {
      final t = _findTask(id);
      if (t != null) await _setTask(t.copyWith(category: category));
    }
  }

  Future<bool> addDownload({
    String url = '', String? name, String? category, int? size, int? threadCount, DateTime? scheduledAt,
    List<Map<String, dynamic>>? torrentFiles, String? downloadPageUrl, String? mergedAudioUrl, int audioSize = 0,
    String? youtubeQualityPreset, int? torrentId, bool isAppUpdate = false, String? playlistId, String? playlistTitle,
    String? thumbnailUrl, String? savePath, String? expectedSha256, List<String>? mirrorUrls, String? siteType,
    String? siteDisplayName, String? contentHint,
  }) async {
    final effectiveSavePath = savePath ?? _settingsProvider.customDownloadPath ?? '';
    final taskName = name ?? (url.split('/').lastOrNull ?? 'download');
    final threads = threadCount ?? _settingsProvider.defaultThreadCount;
    final task = DownloadTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(), fileName: taskName, url: url, fileSize: size ?? 0,
      downloadedBytes: 0, category: category ?? 'Other',
      status: scheduledAt != null ? DownloadStatus.paused : DownloadStatus.queued,
      savePath: effectiveSavePath, localFilePath: '$effectiveSavePath/$taskName', tempFilePath: '$effectiveSavePath/$taskName.dmxpart',
      threadCount: threads, chunks: List<double>.filled(threads, 0.0),
      createdAt: DateTime.now(), updatedAt: DateTime.now(), scheduledAt: scheduledAt,
      torrentFiles: torrentFiles, downloadPageUrl: downloadPageUrl, mergedAudioUrl: mergedAudioUrl,
      audioSize: audioSize, youtubeQualityPreset: youtubeQualityPreset, isAppUpdate: isAppUpdate,
      playlistId: playlistId, playlistTitle: playlistTitle, thumbnailUrl: thumbnailUrl,
      expectedSha256: expectedSha256, mirrorUrls: mirrorUrls, siteType: siteType,
      siteDisplayName: siteDisplayName, contentHint: contentHint, pausedByUser: false,
    );
    await _setTask(task);
    if (scheduledAt == null) pumpQueue();
    return true;
  }

  Future<List<String>> addDownloadsBatch(List<DownloadAddSpec> specs) async {
    final ids = <String>[];
    for (final s in specs) {
      await addDownload(
        url: s.url, name: s.name, category: s.category, size: s.size, savePath: s.savePath,
        threadCount: s.threadCount, scheduledAt: s.scheduledAt, torrentFiles: s.torrentFiles,
        downloadPageUrl: s.downloadPageUrl, mergedAudioUrl: s.mergedAudioUrl, audioSize: s.audioSize,
        youtubeQualityPreset: s.youtubeQualityPreset, torrentId: s.torrentId, isAppUpdate: s.isAppUpdate,
        playlistId: s.playlistId, playlistTitle: s.playlistTitle, thumbnailUrl: s.thumbnailUrl,
      );
      ids.add(_tasks.last.id);
    }
    return ids;
  }

  Future<List<String>> addBatchDownloads({List<DownloadAddSpec>? specs, List<DownloadTask>? tasks, String? savePath}) async {
    final ids = <String>[];
    if (specs != null) {
      for (final s in specs) {
        await addDownload(
          url: s.url, name: s.name, category: s.category, size: s.size, savePath: s.savePath,
          threadCount: s.threadCount, scheduledAt: s.scheduledAt, torrentFiles: s.torrentFiles,
          downloadPageUrl: s.downloadPageUrl, mergedAudioUrl: s.mergedAudioUrl, audioSize: s.audioSize,
          youtubeQualityPreset: s.youtubeQualityPreset, torrentId: s.torrentId, isAppUpdate: s.isAppUpdate,
          playlistId: s.playlistId, playlistTitle: s.playlistTitle, thumbnailUrl: s.thumbnailUrl,
        );
        ids.add(_tasks.last.id);
      }
    }
    if (tasks != null) {
      for (final t in tasks) { await _setTask(t); ids.add(t.id); }
      pumpQueue();
    }
    return ids;
  }

  Future<void> startTask(String id) => _executor.dispatch(StartTask(id));

  @override
  Future<void> pauseTask(String id, {PauseReason reason = PauseReason.userRequested}) async {
    _cancelTokens.remove(id)?.cancel('user_paused');
    await _applyStateChange(
      id, DomainDownloadState.paused,
      PauseTask(id, reason: reason.name, userInitiated: reason == PauseReason.userRequested),
      reason: reason.name, pausedByUser: reason == PauseReason.userRequested, pauseReason: reason.name,
    );
  }

  @override
  Future<void> resumeTask(String id) async {
    final task = _findTask(id);
    if (task == null) return;
    final isTorrent = task.url.startsWith('magnet:') || task.url.endsWith('.torrent') || task.category == 'Torrent' || (task.torrentFiles != null && task.torrentFiles!.isNotEmpty);
    if (task.status == DownloadStatus.completed && isTorrent) {
      await _setTask(task.copyWith(seedingEnabled: true));
      return;
    }
    await _applyStateChange(id, DomainDownloadState.queued, ResumeTask(id), pausedByUser: false, isCancelled: false);
  }

  Future<void> cancelTask(String id) async {
    _cancelTokens.remove(id)?.cancel('cancelled');
    _notifications.cancelForTask(id);
    await _applyStateChange(
      id, DomainDownloadState.failed, CancelTask(id),
      reason: 'Transfer cancelled.', errorMessage: 'Transfer cancelled.',
      pausedByUser: true, isCancelled: true,
    );
  }

  Future<void> cancelDownload(String taskId) => cancelTask(taskId);

  Future<void> deleteTask(String id, {bool deleteFiles = false}) async {
    final task = _findTask(id);
    if (task != null) {
      _cancelTokens.remove(id)?.cancel('deleted');
      _notifications.cancelForTask(id);
      if (deleteFiles) {
        await _deleteFileSafely(task.localFilePath);
        await _deleteFileSafely(task.tempFilePath);
      }
      _tasks.removeWhere((t) => t.id == id);
      await _databaseService.deleteTask(id);
      filteredTasksDirty = true;
      notifyListeners();
    }
  }

  Future<void> retryTask(String id) async {
    final task = _findTask(id);
    if (task == null) return;
    var newUrl = task.url, newAudioUrl = task.mergedAudioUrl, downloadedBytes = task.downloadedBytes;
    final msg = task.errorMessage?.toLowerCase() ?? '';
    final isUnrecoverable = msg.contains('checksum') || msg.contains('corrupt') || msg.contains('unrecoverable');
    var shouldResetProgress = isUnrecoverable;
    if (task.downloadPageUrl != null && task.youtubeQualityPreset != null) {
      try {
        final streams = await YoutubeService.getFreshStreams(task.downloadPageUrl!);
        if (streams != null) {
          final freshUrl = streams['url'] as String?, freshAudioUrl = streams['audioUrl'] as String?;
          if (freshUrl != null && youtubeStreamIdentityChanged(task.url, freshUrl)) shouldResetProgress = true;
          if (freshUrl != null) newUrl = freshUrl;
          if (freshAudioUrl != null) newAudioUrl = freshAudioUrl;
        }
      } catch (_) {}
    }
    if (shouldResetProgress) {
      downloadedBytes = 0;
      await _deleteFileSafely(task.tempFilePath);
      await _deleteFileSafely('${task.tempFilePath}.dmxstate');
    } else {
      final stateFile = File('${task.tempFilePath}.dmxstate');
      if (await stateFile.exists()) {
        try {
          final content = await stateFile.readAsString();
          downloadedBytes = calculateDownloadedFromState(jsonDecode(content) as Map<String, dynamic>);
        } catch (_) { downloadedBytes = 0; }
      }
    }
    await _applyStateChange(id, DomainDownloadState.queued, RetryTask(id), pausedByUser: false, isCancelled: false);
    final updated = _findTask(id);
    if (updated != null) {
      await _setTask(updated.copyWith(
        url: newUrl, mergedAudioUrl: newAudioUrl, downloadedBytes: downloadedBytes,
        videoStreamSize: shouldResetProgress ? 0 : updated.videoStreamSize,
        audioDownloadedBytes: shouldResetProgress ? 0 : updated.audioDownloadedBytes,
      ));
    }
  }

  Future<void> clearHistoryTasks(List<String> ids) async { for (final id in ids) { await deleteTask(id); } }
  Future<void> startUpdateDownload(UpdateInfo update) async {
    final dir = await UpdateService().getUpdatesDirectory();
    await addDownload(url: update.downloadUrl, name: 'XDM_${update.latestVersion}_v${update.versionCode}.apk', category: 'Other', savePath: dir.path, isAppUpdate: true);
  }
  void markTorrentTasksFailed(String message) {
    for (final t in _tasks) {
      final isT = t.url.startsWith('magnet:') || t.url.endsWith('.torrent') || t.category == 'Torrent' || (t.torrentFiles != null && t.torrentFiles!.isNotEmpty);
      if (isT && (t.status == DownloadStatus.downloading || t.status == DownloadStatus.queued)) {
        _applyStateChange(t.id, DomainDownloadState.failed, CancelTask(t.id), errorMessage: message);
      }
    }
  }

  Future<void> pauseAllTasks() => mixinPauseAllTasks(notifyListeners);
  Future<void> resumeAllTasks() => mixinResumeAllTasks(notifyListeners);
  Future<void> toggleStartStopAll() => mixinToggleStartStopAll(notifyListeners);

  @override bool startTaskFromQueue(DownloadTask task) => _orchestrator.startTask(task);
  @override bool isTaskPendingStart(String taskId) => _orchestrator.isTaskPendingStart(taskId);
  @override bool isTaskWaitingForRetry(String taskId) => _retryTimers.containsKey(taskId);
  @override
  Future<void> flushPendingProgress(String id) async {
    final task = _findTask(id);
    if (task != null && _pendingProgressUpdates.remove(id)) await _databaseService.saveTask(task);
  }
  @override int effectiveSpeedLimit() => 0;
  @override List<double> buildChunks(int count, int size, int bytes) => count <= 0 ? const [] : size <= 0 ? List.filled(count, 0.0) : List.filled(count, (bytes / size).clamp(0.0, 1.0));
  @override ({int total, List<Map<String, dynamic>>? files}) scanExistingTorrentData(String p, List<Map<String, dynamic>>? f) => (total: 0, files: f);
  @override Future<void> updateTaskUrlAndResume(String id, String url, {String? newAudioUrl}) async { if (_findTask(id) != null) await resumeTask(id); }
  Future<void> updateTaskUrl(String id, String url, {String? newAudioUrl}) => updateTaskUrlAndResume(id, url, newAudioUrl: newAudioUrl);
  @override void updateTelemetryWidget() {}
  @override void providerStartWidgetTimer() {}
  @override void providerStopWidgetTimer() {}
  @override void providerNotifyListeners() => notifyListeners();
  @override void pushProgressTick(String id, double p, double s) => _progressEmitter.pushTick(id, p, s);
  @override List<Map<String, dynamic>> markTorrentFilesCompleted(List<Map<String, dynamic>> files) => files.map((m) => {...m, 'downloadedBytes': m['length'] ?? 0, 'progress': 1.0}).toList();
  @override Future<void> cleanupPartFiles(DownloadTask t, {bool preserveParts = false}) async { if (!preserveParts) await _deleteFileSafely(t.tempFilePath); }
  @override Future<void> startOverTask(String id, String url, {String? newAudioUrl, bool clearAudioUrl = false, bool fromError = false, int? newFileSize, int? newAudioSize, bool deleteTempFiles = false}) async {
    final t = _findTask(id);
    if (t == null) return;
    if (deleteTempFiles) await _deleteFileSafely(t.tempFilePath);
    await resumeTask(id);
  }

  @override
  void dispose() {
    _disposed = true;
    _eventSubscription?.cancel();
    _widgetUpdateTimer?.cancel();
    _networkMonitor.dispose(); _scheduleManager.dispose(); _notifications.dispose();
    _orchestrator.dispose(); _executor.dispose();
    _settingsProvider.removeListener(_onSettingsChanged);
    super.dispose();
  }
}
