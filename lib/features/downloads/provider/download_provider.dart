import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:webview_cookie_manager/webview_cookie_manager.dart';
import '../../../core/services/torrent_service.dart';
import '../../../core/services/youtube_service.dart';

// ignore_for_file: prefer_initializing_formals

import '../../../core/services/background_service.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/download_engine.dart';
import '../../../core/services/ffmpeg_mux_service.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/url_utils.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';
import '../../browser/services/ad_blocker.dart';

import 'mixins/download_filter_mixin.dart';
import 'mixins/download_queue_mixin.dart';
import 'mixins/download_torrent_mixin.dart';
import 'mixins/download_backup_mixin.dart';

class DownloadProvider extends ChangeNotifier
    with
        DownloadFilterMixin,
        DownloadQueueMixin,
        DownloadTorrentMixin,
        DownloadBackupMixin {
  static const _mediaChannel = MethodChannel('com.example.dmx/media');

  DownloadProvider({
    required DatabaseService databaseService,
    required SettingsProvider settingsProvider,
    DownloadEngine? downloadEngine,
    PermissionService? permissionService,
    NotificationService? notificationService,
  }) : _databaseService = databaseService,
       _settingsProvider = settingsProvider,
       _downloadEngine = downloadEngine ?? DownloadEngine(),
       _permissionService = permissionService ?? PermissionService(),
       _notificationService = notificationService ?? NotificationService() {
    _settingsProvider.addListener(_onSettingsChanged);
    _initConnectivity();
    _startSchedulingTimer();
    _actionSubscription = _notificationService.onActionTapped.listen(
      _handleNotificationAction,
    );
    if (TorrentService.isInitialized) {
      _torrentUpdatesSubscription = TorrentService.torrentUpdates.listen((
        torrents,
      ) {
        _latestTorrentStats = torrents;
      });
    }
  }

  StreamSubscription<Map<String, String>>? _actionSubscription;
  StreamSubscription? _torrentUpdatesSubscription;

  final DatabaseService _databaseService;
  final SettingsProvider _settingsProvider;
  final DownloadEngine _downloadEngine;
  final PermissionService _permissionService;
  final NotificationService _notificationService;
  final List<DownloadTask> _tasks = [];
  bool _progressLock = false;
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, List<double>> _speedHistories = {};
  final Map<String, int> _lastProgressUpdateTimes = {};
  final Map<String, int> _lastDbSaveTimes = {};
  final Map<String, int> _lastDbSaveBytes = {};
  final Set<String> _pendingProgressUpdates = {};
  final Set<String> _tasksPausedDueToNetwork = {};
  final Map<String, int> _torrentIds = {};
  final Map<String, int> _notificationIds = {};
  int _nextNotificationId = 1;

  int _getNotificationId(String taskId) {
    return _notificationIds.putIfAbsent(taskId, () => _nextNotificationId++);
  }

  final Map<String, int> _retryCounts = {};
  Map<int, TorrentUpdateInfo> _latestTorrentStats = {};

  List<double> getSpeedHistory(String id) => _speedHistories[id] ?? const [];

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  List<ConnectivityResult> _currentConnectivity = [];
  bool _hasResolvedInitialConnectivity = false;
  Timer? _schedulingTimer;
  Timer? _widgetTimer;
  final Map<String, Timer> _retryTimers = {};
  final Map<String, Future<void>> _activeFutures = {};

  String? _lastError;
  String? get lastError => _lastError;

  // ---------------------------------------------------------------------------
  // Mixin contract implementations
  // ---------------------------------------------------------------------------

  /// Exposes the internal task list to all mixins.
  @override
  List<DownloadTask> get providerTasks => _tasks;

  /// Exposes the database service to [DownloadBackupMixin].
  @override
  DatabaseService get providerDatabaseService => _databaseService;

  /// Exposes the settings provider to [DownloadQueueMixin] and
  /// [DownloadTorrentMixin].
  @override
  SettingsProvider get providerSettingsProvider => _settingsProvider;

  /// Exposes the torrent ID map to [DownloadTorrentMixin].
  @override
  Map<String, int> get providerTorrentIds => _torrentIds;

  /// Exposes the latest torrent stats to [DownloadTorrentMixin].
  @override
  Map<int, TorrentUpdateInfo> get providerLatestTorrentStats =>
      _latestTorrentStats;

  /// Lookup a task by ID — used by [DownloadFilterMixin] and
  /// [DownloadTorrentMixin].
  @override
  DownloadTask? findTaskById(String id) => _findTask(id);

  /// Called by [DownloadQueueMixin.pumpQueue] to actually start a task.
  @override
  void startTaskFromQueue(DownloadTask task) => _startTask(task);

  /// Called by [DownloadBackupMixin] to update the home-screen widget.
  @override
  void updateTelemetryWidget() => _updateTelemetryWidget();

  /// Called by [DownloadQueueMixin.pumpQueue] to check if a task is waiting for a retry delay.
  @override
  bool isTaskWaitingForRetry(String taskId) => _retryTimers.containsKey(taskId);

  // ---------------------------------------------------------------------------
  // Public getters (delegated to [DownloadFilterMixin])
  // ---------------------------------------------------------------------------

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

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
    // Delegates to the mixin, providing the ad-blocker callback.
    setMixinActiveTabIndex(
      index,
      onBrowserTab: () {
        if (_settingsProvider.adBlockerEnabled) {
          AdBlocker.autoUpdateHosts();
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Load / initialization
  // ---------------------------------------------------------------------------

  Future<int?> _actualPartialBytes(DownloadTask task) async {
    if (task.tempFilePath.trim().isEmpty) return null;

    final targetFile = File(task.tempFilePath);
    if (!await targetFile.exists()) {
      return 0;
    }
    final targetSize = await targetFile.length();

    if (task.threadCount > 1) {
      final stateFile = File('${task.tempFilePath}.dmxstate');
      if (await stateFile.exists()) {
        try {
          final content = await stateFile.readAsString();
          final stateList = jsonDecode(content) as List;
          var total = 0;
          for (final chunk in stateList) {
            total += (chunk as num).toInt();
          }
          // Verify that state sum does not exceed actual file size on disk
          return total > targetSize ? targetSize : total;
        } catch (e) {
          debugPrint('Failed to parse .dmxstate: $e');
          return targetSize;
        }
      }
    }

    if (task.downloadedBytes > 0 && task.downloadedBytes <= targetSize) {
      return task.downloadedBytes;
    }
    return targetSize;
  }

  Future<DownloadTask> _reconcilePartialProgress(DownloadTask task) async {
    if (task.status == DownloadStatus.completed) return task;
    
    // Do not reconcile progress for active downloads (their memory state is accurate)
    if (_cancelTokens.containsKey(task.id) || task.status == DownloadStatus.downloading) return task;
    
    // Torrents manage their own fastresume data and piece maps.
    // Reading .part files will break torrent progress.
    if (task.isTorrent) return task;

    final actualBytes = await _actualPartialBytes(task);
    if (actualBytes == null || actualBytes == task.downloadedBytes) return task;

    final bytes = task.fileSize > 0
        ? actualBytes.clamp(0, task.fileSize)
        : actualBytes;
    return task.copyWith(
      downloadedBytes: bytes,
      chunks: _buildChunks(task.threadCount, task.fileSize, bytes),
    );
  }

  /// [pauseOrphanDownloads] should be true only on initial app startup, when
  /// in-flight downloads (from a previous run) cannot be resumed safely.
  /// On user-triggered reload, we must preserve currently active downloads.
  Future<void> load({bool pauseOrphanDownloads = true}) async {
    final cleanupDays = _settingsProvider.cleanupDays;
    final now = DateTime.now();
    final toDelete = <DownloadTask>[];

    final dbTasks = await _databaseService.loadTasks();
    final loaded = dbTasks
        .map((task) {
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
              errorMessage:
                  'Paused because XDM was closed during a foreground download.',
            );
          }
          return task.copyWith(
            speed: 0,
            clearEta: task.status != DownloadStatus.downloading,
          );
        })
        .where((task) {
          if (cleanupDays > 0 &&
              (task.status == DownloadStatus.completed ||
                  task.status == DownloadStatus.failed)) {
            final difference = now
                .difference(task.completedAt ?? task.createdAt)
                .inDays;
            if (difference >= cleanupDays) {
              toDelete.add(task);
              return false;
            }
          }
          return true;
        })
        .toList();

    final reconciled = <DownloadTask>[];
    for (final task in loaded) {
      final hasActiveStream = _cancelTokens.containsKey(task.id);
      if (hasActiveStream) {
        final memoryTask = _findTask(task.id);
        if (memoryTask != null) {
          reconciled.add(memoryTask);
          continue;
        }
      }

      try {
        reconciled.add(await _reconcilePartialProgress(task));
      } catch (e) {
        debugPrint('Failed to reconcile partial file for ${task.id}: $e');
        reconciled.add(task);
      }
    }

    _tasks
      ..clear()
      ..addAll(reconciled);

    for (final task in toDelete) {
      await _databaseService.deleteTask(task.id);
      await _cleanupPartFiles(task);
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
    if (!_hasResolvedInitialConnectivity) {
      _currentConnectivity = await Connectivity().checkConnectivity();
      _hasResolvedInitialConnectivity = true;
    }
    await _checkNetworkConnectivity(skipPump: true);
    _checkScheduledDownloads();

    // Auto-resume if enabled — unpause orphaned downloads (excluding
    // user-paused, scheduled, or Wi-Fi-waiting tasks) and pump the queue so queued
    // downloads start immediately.
    if (_settingsProvider.autoStart) {
      final autoResumeTasks = _tasks
          .where(
            (t) =>
                t.status == DownloadStatus.paused &&
                !t.pausedByUser &&
                t.errorMessage != 'Waiting for WiFi connection' &&
                (t.scheduledAt == null ||
                    t.scheduledAt!.isBefore(DateTime.now())),
          )
          .map((t) {
            _cancelTokens.remove(t.id);
            return t.copyWith(
              status: DownloadStatus.queued,
              speed: 0,
              clearEta: true,
              clearError: true,
            );
          })
          .toList();
      for (final task in autoResumeTasks) {
        final idx = _tasks.indexWhere((t) => t.id == task.id);
        if (idx != -1) {
          _tasks[idx] = task;
          await _databaseService.saveTask(task);
        }
      }
      if (autoResumeTasks.isNotEmpty) {
        notifyListeners();
      }
      // Re-apply the Wi-Fi-only constraint so auto-resumed tasks that should
      // wait for Wi-Fi are not started on mobile data.
      await _checkNetworkConnectivity(skipPump: true);
    }

    // Always pump the queue so queued-downloads (including newly
    // auto-resumed ones) start without requiring user interaction.
    pumpQueue();
    _updateTelemetryWidget();
  }

  // ---------------------------------------------------------------------------
  // Download task lifecycle
  // ---------------------------------------------------------------------------

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
      return;
    }

    final resolvedThreadCount =
        threadCount ?? _settingsProvider.defaultThreadCount;

    try {
      if (urls.length > 1) {
        var addedCount = 0;
        for (var i = 0; i < urls.length; i++) {
          final singleUrl = urls[i];
          if (!isValidTransmissionUrl(singleUrl)) continue;
          final suffix = i + 1;
          final singleName = name.trim().isNotEmpty
              ? '${name.trim()}_$suffix'
              : '';
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
        );
      }
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> _addSingleDownload({
    required String name,
    required String url,
    required int size,
    required String category,
    required String savePath,
    required int threadCount,
    DateTime? scheduledAt,
    List<Map<String, dynamic>>? torrentFiles,
    String? downloadPageUrl,
    String? mergedAudioUrl,
    int audioSize = 0,
    String? youtubeQualityPreset,
    int? torrentId,
  }) async {
    final exists = _tasks.any(
      (t) =>
          t.url == url &&
          t.status != DownloadStatus.failed &&
          t.status != DownloadStatus.completed &&
          t.status != DownloadStatus.paused,
    );
    if (exists) {
      throw Exception('This URL is already active in the download queue.');
    }

    final defaultDirectory =
        _settingsProvider.customDownloadPath?.isNotEmpty == true
        ? _settingsProvider.customDownloadPath!
        : await _permissionService.defaultDownloadDirectory();

    final bool isMagnet = url.trim().toLowerCase().startsWith('magnet:');

    String resolvedCategory;
    String fileName;
    int fileSize;
    bool supportsResume;

    // For all downloads (magnet, torrent, HTTP), bypass synchronous metadata resolve
    // to keep UI thread fully responsive. Metadata resolves in the background inside DownloadEngine.
    if (isMagnet) {
      final parsed = parseMagnetUrl(url.trim());
      final magnetName = parsed['name'] ?? 'Torrent Download';
      fileName = name.trim().isNotEmpty
          ? safeFileName(name.trim())
          : magnetName;
      fileSize = size > 0 ? size : 0;
      resolvedCategory = category.trim().isNotEmpty ? category : 'Archive';
      supportsResume = true;
    } else {
      fileName = name.trim().isNotEmpty
          ? safeFileName(name.trim())
          : fileNameFromUrl(url.trim());
      fileSize = size > 0 ? size : 0;
      resolvedCategory = category.trim().isNotEmpty
          ? category
          : categoryFromFileName(fileName);
      supportsResume = true; // Assume resume support initially
    }

    var directory = savePath.trim().isNotEmpty
        ? savePath.trim()
        : defaultDirectory;
    if (_settingsProvider.categoryFolders) {
      String subFolder = resolvedCategory;
      if (_settingsProvider.languageCode == 'ar') {
        subFolder = switch (resolvedCategory) {
          'Video' => 'الفيديو',
          'Audio' => 'الصوت',
          'Document' => 'المستندات',
          'Archive' => 'الأرشيف',
          'APK' => 'التطبيقات',
          'Other' || 'General' => 'أخرى',
          _ => resolvedCategory,
        };
      }
      directory = p.join(directory, subFolder);
    }
    final localFilePath = _downloadEngine.buildLocalFilePath(
      directory,
      fileName,
    );
    final tempFilePath = _downloadEngine.buildTempFilePath(directory, fileName);
    final now = DateTime.now();

    final isScheduled = scheduledAt != null && scheduledAt.isAfter(now);

    final task = DownloadTask(
      id: '${now.microsecondsSinceEpoch}_${Random.secure().nextInt(1000000000)}',
      fileName: fileName,
      url: url.trim(),
      fileSize: fileSize,
      downloadedBytes: 0,
      category: resolvedCategory,
      status: isScheduled ? DownloadStatus.paused : DownloadStatus.queued,
      savePath: directory,
      localFilePath: localFilePath,
      tempFilePath: tempFilePath,
      threadCount: threadCount,
      chunks: List<double>.filled(threadCount, 0.0),
      createdAt: now,
      updatedAt: now,
      scheduledAt: scheduledAt,
      supportsResume: supportsResume,
      // Apply the user's global torrent seeding preference.
      seedingEnabled: _settingsProvider.globalTorrentSeeding,
      seedingLimited: _settingsProvider.globalTorrentSeedingLimited,
      seedingLimitKbps: _settingsProvider.globalTorrentSeedingLimitKbps,
      torrentFiles: torrentFiles,
      downloadPageUrl: downloadPageUrl,
      mergedAudioUrl: mergedAudioUrl,
      audioSize: audioSize,
      youtubeQualityPreset: youtubeQualityPreset,
    );

    _tasks.insert(0, task);
    if (torrentId != null) {
      _torrentIds[task.id] = torrentId;
    }
    filteredTasksDirty = true;
    await _databaseService.saveTask(task);
    notifyListeners();
    _updateTelemetryWidget();
    if (!isScheduled) {
      pumpQueue();
    }
  }

  Future<void> pauseTask(String id) async {
    final task = _findTask(id);
    if (task == null) return;

    // Flush any pending throttled progress to disk so resume has the latest bytes.
    await _flushPendingProgress(id);

    _retryCounts.remove(id);
    _speedHistories.remove(id);
    _lastProgressUpdateTimes.remove(id);
    _lastDbSaveTimes.remove(id);
    _pendingProgressUpdates.remove(id);
    _retryTimers[id]?.cancel();
    _retryTimers.remove(id);

    if (task.status == DownloadStatus.downloading) {
      final torrentId = _torrentIds[id];
      if (torrentId != null) {
        TorrentService.pauseTorrent(torrentId);
      }
      try {
        _cancelTokens[id]?.cancel('paused');
      } catch (e) {
        // Ignore
      }
      _cancelTokens.remove(id);
    }
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
    pumpQueue();
    if (downloadingTasksCount == 0) {
      _stopWidgetTimer();
    }
    _updateTelemetryWidget();
  }

  void _handleNotificationAction(Map<String, String> event) {
    final action = event['action'];
    final taskId = event['taskId'];
    if (action == null || taskId == null) return;

    if (action == 'pause') {
      pauseTask(taskId);
    } else if (action == 'cancel') {
      cancelTask(taskId);
    }
  }

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
    pumpQueue();
    _updateTelemetryWidget();
  }

  Future<void> pauseAllTasks() async {
    startBatch();
    try {
      final active = _tasks
          .where(
            (task) =>
                task.status == DownloadStatus.downloading ||
                task.status == DownloadStatus.queued,
          )
          .toList();
      await Future.wait(active.map((task) async {
        try {
          await pauseTask(task.id);
        } catch (e) {
          debugPrint('Error pausing task: $e');
        }
      }));
      pumpQueue();
    } finally {
      endBatch(super.notifyListeners);
    }
  }

  Future<void> resumeAllTasks() async {
    startBatch();
    try {
      final resumable = _tasks
          .where(
            (task) =>
                task.status == DownloadStatus.paused ||
                task.status == DownloadStatus.failed,
          )
          .toList();
      await Future.wait(resumable.map((task) async {
        try {
          await resumeTask(task.id);
        } catch (e) {
          debugPrint('Error resuming task: $e');
        }
      }));
    } finally {
      endBatch(super.notifyListeners);
    }
  }

  Future<void> toggleStartStopAll() async {
    final activeCount = downloadingTasksCount + queuedTasksCount;
    if (activeCount > 0) {
      await pauseAllTasks();
    } else {
      await resumeAllTasks();
    }
  }

  Future<void> cancelTask(String id) async {
    final task = _findTask(id);
    if (task == null) return;

    // Flush any pending throttled progress and drop tracking state.
    await _flushPendingProgress(id);

    _retryCounts.remove(id);
    _speedHistories.remove(id);
    _lastProgressUpdateTimes.remove(id);
    _lastDbSaveTimes.remove(id);
    _pendingProgressUpdates.remove(id);
    _retryTimers[id]?.cancel();
    _retryTimers.remove(id);

    _cancelTokens[id]?.cancel('cancelled');
    _cancelTokens.remove(id);

    final torrentId = _torrentIds[id];
    if (torrentId != null) {
      TorrentService.removeTorrent(torrentId);
      _torrentIds.remove(id);
    }

    // Remove the .partN chunk files so a fresh download won't try to
    // resume from a partial state.
    await _cleanupPartFiles(task);

    await _setTask(
      task.copyWith(
        status: DownloadStatus.failed,
        speed: 0,
        clearEta: true,
        errorMessage: 'Transfer cancelled.',
      ),
    );
    pumpQueue();
    if (downloadingTasksCount == 0) {
      _stopWidgetTimer();
    }
    _updateTelemetryWidget();
  }

  Future<void> retryTask(String id) async {
    final task = _findTask(id);
    if (task == null) return;

    _retryCounts.remove(id);

    // Don't reset downloadedBytes/chunks to 0 — the .partN files are still
    // on disk and the download engine will resume from existing offsets.
    // The onProgress callback will pick up the real numbers from the next
    // chunk that arrives.
    await _setTask(
      task.copyWith(
        status: DownloadStatus.queued,
        speed: 0,
        clearEta: true,
        clearError: true,
        clearStatusMessage: true,
        clearCompletedAt: true,
      ),
    );
    pumpQueue();
    _updateTelemetryWidget();
  }

  Future<void> deleteTask(String id, {bool deleteFiles = false}) async {
    final task = _findTask(id);
    final activeFuture = _activeFutures[id];
    try {
      _cancelTokens[id]?.cancel('deleted');
    } catch (e) {
      // Ignore
    }

    if (activeFuture != null) {
      try {
        await activeFuture;
      } catch (_) {}
    }

    _cancelTokens.remove(id);
    _speedHistories.remove(id);
    _lastProgressUpdateTimes.remove(id);
    _lastDbSaveTimes.remove(id);
    _pendingProgressUpdates.remove(id);
    _retryCounts.remove(id);
    _retryTimers[id]?.cancel();
    _retryTimers.remove(id);
    final savedNotificationId = _notificationIds[id];
    _activeFutures.remove(id);
    _notificationIds.remove(id);
    _tasks.removeWhere((task) => task.id == id);
    filteredTasksDirty = true;

    final torrentId = _torrentIds[id];
    if (torrentId != null) {
      TorrentService.removeTorrent(torrentId, deleteFiles: deleteFiles);
      _torrentIds.remove(id);
    }

    if (task != null) {
      if (deleteFiles) {
        await _cleanupPartFiles(task);
        try {
          final localFile = File(task.localFilePath);
          if (await localFile.exists()) {
            await localFile.delete();
          }
        } catch (e) {
          debugPrint('Failed to delete completed file: $e');
        }

        if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
          for (final f in task.torrentFiles!) {
            final relPath = f['name'] as String?;
            if (relPath != null && relPath.isNotEmpty) {
              try {
                final fullPath = p.join(task.savePath, relPath);
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
    }
    await _databaseService.deleteTask(id);
    if (savedNotificationId != null) {
      _notificationService.cancelNotification(savedNotificationId);
    }
    updateActualTorrentUploadLimit();
    notifyListeners();
    pumpQueue();
    if (downloadingTasksCount == 0) {
      BackgroundService.stop();
      _stopWidgetTimer();
    }
    _updateTelemetryWidget();
  }

  Future<void> clearHistoryTasks(List<String> ids) async {
    for (final id in ids) {
      _cancelTokens.remove(id);
      _speedHistories.remove(id);
      _lastProgressUpdateTimes.remove(id);
      _lastDbSaveTimes.remove(id);
      _pendingProgressUpdates.remove(id);
      _retryCounts.remove(id);
      _retryTimers[id]?.cancel();
      _retryTimers.remove(id);
      _activeFutures.remove(id);
      final savedNotificationId = _notificationIds[id];
      _notificationIds.remove(id);
      _tasks.removeWhere((task) => task.id == id);

      final torrentId = _torrentIds[id];
      if (torrentId != null) {
        TorrentService.removeTorrent(torrentId, deleteFiles: false);
        _torrentIds.remove(id);
      }
      if (savedNotificationId != null) {
        _notificationService.cancelNotification(savedNotificationId);
      }
    }
    filteredTasksDirty = true;
    await _databaseService.deleteTasks(ids);
    updateActualTorrentUploadLimit();
    notifyListeners();
  }

  /// Deletes the partial .dmxpart and .partN files on disk for [task].
  Future<void> _cleanupPartFiles(DownloadTask task) async {
    try {
      final tempFile = File(task.tempFilePath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      for (int i = 0; i < task.threadCount; i++) {
        final partFile = File('${task.tempFilePath}.part$i');
        if (await partFile.exists()) {
          await partFile.delete();
        }
      }
      final stateFile = File('${task.tempFilePath}.dmxstate');
      if (await stateFile.exists()) {
        await stateFile.delete();
      }
    } catch (e) {
      debugPrint('Failed to clean up part files for ${task.id}: $e');
    }
  }

  /// Persists any throttled in-memory progress for [id] that hasn't yet
  /// been flushed to the database. No-op if there's nothing pending.
  Future<void> _flushPendingProgress(String id) async {
    _lastProgressUpdateTimes.remove(id);
    _lastDbSaveTimes.remove(id);
    if (!_pendingProgressUpdates.remove(id)) return;
    final index = _tasks.indexWhere((t) => t.id == id);
    if (index == -1) return;
    final task = _tasks[index];
    await _databaseService.saveTask(task);
  }

  Future<void> updateTaskSpeedLimit(String taskId, int speedLimitKbps) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;
    _tasks[index] = _tasks[index].copyWith(speedLimitKbps: speedLimitKbps);
    await _databaseService.saveTask(_tasks[index]);
    notifyListeners();
  }

  Future<void> updateTaskSeeding(
    String taskId, {
    bool? enabled,
    bool? limited,
    int? limitKbps,
  }) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final oldTask = _tasks[index];
    final newEnabled = enabled ?? oldTask.seedingEnabled;

    _tasks[index] = oldTask.copyWith(
      seedingEnabled: newEnabled,
      seedingLimited: limited,
      seedingLimitKbps: limitKbps,
    );
    await _databaseService.saveTask(_tasks[index]);

    if (oldTask.isTorrent) {
      final torrentId = _torrentIds[taskId];
      if (newEnabled) {
        if (torrentId != null) {
          TorrentService.resumeTorrent(torrentId);
        } else {
          startSeedingTorrent(_tasks[index]);
        }
      } else {
        // Only pause/remove the torrent session if the task has already
        // finished downloading (status == completed).  Calling pauseTorrent
        // while still downloading would abort the in-progress transfer.
        if (torrentId != null && oldTask.status == DownloadStatus.completed) {
          TorrentService.pauseTorrent(torrentId);
          _torrentIds.remove(taskId);
        }
        // Snap downloadedBytes to fileSize so the Completed tab shows 100%.
        final updatedIdx = _tasks.indexWhere((t) => t.id == taskId);
        if (updatedIdx != -1) {
          final t = _tasks[updatedIdx];
          if (t.status == DownloadStatus.completed &&
              t.fileSize > 0 &&
              t.downloadedBytes < t.fileSize) {
            _tasks[updatedIdx] = t.copyWith(
              downloadedBytes: t.fileSize,
              chunks: List<double>.filled(t.threadCount, 1.0),
            );
            await _databaseService.saveTask(_tasks[updatedIdx]);
          }
        }
      }
    }

    updateActualTorrentUploadLimit();
    notifyListeners();
    _startWidgetTimer();
  }

  DownloadTask? taskById(String id) {
    return _findTask(id);
  }

  // ---------------------------------------------------------------------------
  // Download engine orchestration
  // ---------------------------------------------------------------------------

  final Set<String> _startingTaskIds = {};

  @override
  int get pendingStartCount => _startingTaskIds.length;

  Future<void> _startTask(DownloadTask task) async {
    if (_cancelTokens.containsKey(task.id)) return;
    if (_startingTaskIds.contains(task.id)) return;
    _startingTaskIds.add(task.id);

    final hasWifiOrEthernet =
        _currentConnectivity.contains(ConnectivityResult.wifi) ||
        _currentConnectivity.contains(ConnectivityResult.ethernet);
    if (_settingsProvider.wifiOnly && !hasWifiOrEthernet) {
      await _setTask(
        task.copyWith(
          status: DownloadStatus.paused,
          errorMessage: 'Waiting for WiFi connection',
        ),
      );
      _startingTaskIds.remove(task.id);
      return;
    }

    if (downloadingTasksCount == 0) {
      BackgroundService.start();
    }
    _updateBackgroundNotification();
    _startWidgetTimer();
    _updateTelemetryWidget();

    // Extract cookies from native WebView for authentication
    String cookieString = '';
    try {
      final cookieUrl = task.downloadPageUrl ?? task.url;
      final uri = Uri.tryParse(cookieUrl);
      if (uri != null) {
        final origin = '${uri.scheme}://${uri.host}';
        final cookies = await WebviewCookieManager().getCookies(origin);
        cookieString = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      }
    } catch (_) {}

    // Just-in-time stream resolution for YouTube videos
    final youtubeUrl = task.downloadPageUrl ?? task.url;
    if (youtubeUrl.contains('youtube.com/') || youtubeUrl.contains('youtu.be/')) {
      if (cookieString.isNotEmpty) {
        YoutubeService.signIn(cookieString);
      }
    }
    
    if (task.youtubeQualityPreset != null &&
        (youtubeUrl.contains('youtube.com/') || youtubeUrl.contains('youtu.be/'))) {
      try {
        final videoId = YoutubeService.extractVideoId(youtubeUrl);
        if (videoId != null) {
          final streamInfo = await YoutubeService.getStreamForVideo(
            videoId,
            task.youtubeQualityPreset!,
          );
          if (streamInfo != null) {
            final type = streamInfo['type'] as String? ?? 'muxed';
            final ext = streamInfo['ext'] as String? ?? 'mp4';
            final title = streamInfo['title'] as String? ?? '';

            // Build a proper file name with quality label
            String resolvedFileName;
            if (type == 'combined') {
              final qLabel = streamInfo['quality'] as String? ?? 'HD';
              resolvedFileName = title.isNotEmpty
                  ? '$title [$qLabel].$ext'
                  : task.fileName;
            } else if (type == 'audio') {
              resolvedFileName = title.isNotEmpty
                  ? '$title.$ext'
                  : task.fileName;
            } else {
              final qLabel = streamInfo['quality'] as String? ?? '';
              resolvedFileName = title.isNotEmpty && qLabel.isNotEmpty
                  ? '$title [$qLabel].$ext'
                  : (title.isNotEmpty ? '$title.$ext' : task.fileName);
            }
            resolvedFileName = safeFileName(resolvedFileName);

            // Rebuild file paths with the resolved name
            final resolvedLocalPath = _downloadEngine.buildLocalFilePath(
              task.savePath,
              resolvedFileName,
            );
            final resolvedTempPath = _downloadEngine.buildTempFilePath(
              task.savePath,
              resolvedFileName,
            );

            if (type == 'combined') {
              task = task.copyWith(
                url: streamInfo['src'] as String,
                mergedAudioUrl: streamInfo['audioSrc'] as String,
                fileSize: (streamInfo['videoSize'] as int? ?? 0) +
                    (streamInfo['audioSize'] as int? ?? 0),
                audioSize: streamInfo['audioSize'] as int? ?? 0,
                fileName: resolvedFileName,
                localFilePath: resolvedLocalPath,
                tempFilePath: resolvedTempPath,
              );
            } else {
              task = task.copyWith(
                url: streamInfo['src'] as String,
                fileSize: streamInfo['size'] as int? ?? 0,
                fileName: resolvedFileName,
                localFilePath: resolvedLocalPath,
                tempFilePath: resolvedTempPath,
              );
            }
            await _setTask(task);
          } else {
            throw Exception('Stream not available');
          }
        }
      } catch (e) {
        final isRetryable = _isRetryableError(e);
        final maxRetries = _settingsProvider.autoRetryEnabled && isRetryable
            ? _settingsProvider.maxRetries
            : 0;
        final currentRetry = _retryCounts[task.id] ?? 0;

        if (currentRetry < maxRetries) {
          _retryCounts[task.id] = currentRetry + 1;
          final delaySeconds = _settingsProvider.retryDelaySeconds;
          debugPrint(
            'Transient error resolving stream for task ${task.id}. Retrying (${currentRetry + 1}/$maxRetries) in $delaySeconds seconds...',
          );

          await _setTask(
            task.copyWith(
              status: DownloadStatus.queued,
              speed: 0,
              errorMessage:
                  'Retrying in $delaySeconds seconds: ${_errorMessage(e)}',
            ),
          );

          _retryTimers[task.id]?.cancel();
          _retryTimers[task.id] = Timer(Duration(seconds: delaySeconds), () {
            _retryTimers.remove(task.id);
            final checkedTask = _findTask(task.id);
            if (checkedTask != null &&
                checkedTask.status == DownloadStatus.queued) {
              pumpQueue();
            }
          });
          _startingTaskIds.remove(task.id);
          return;
        }

        _retryCounts.remove(task.id);
        await _setTask(
          task.copyWith(
            status: DownloadStatus.failed,
            errorMessage: 'Failed to resolve YouTube stream: ${_errorMessage(e)}',
          ),
        );
        pumpQueue();
        _updateTelemetryWidget();
        _startingTaskIds.remove(task.id);
        return;
      }
    }

    final cancelToken = CancelToken();
    _cancelTokens[task.id] = cancelToken;

    int? torrentId;
    if (task.isTorrent) {
      try {
        final existingTorrentId = _torrentIds[task.id];
        if (existingTorrentId != null) {
          // Validate torrent still exists; if the engine removed it, re-add
          try {
            TorrentService.getFiles(existingTorrentId);
            torrentId = existingTorrentId;
          } catch (_) {
            _torrentIds.remove(task.id);
          }
        }
        if (torrentId == null) {
          final saveDir = task.savePath;
          if (task.url.startsWith('magnet:')) {
            torrentId = TorrentService.addMagnet(task.url, saveDir);
          } else {
            String filePath = task.url;
            if (task.url.startsWith('file://')) {
              filePath = Uri.parse(task.url).toFilePath();
            }
            torrentId = TorrentService.addTorrentFile(filePath, saveDir);
          }
          if (torrentId < 0) {
            throw Exception('Torrent engine rejected the torrent.');
          }
          _torrentIds[task.id] = torrentId;
        }
      } catch (e) {
        _cancelTokens.remove(task.id);
        await _setTask(
          task.copyWith(
            status: DownloadStatus.failed,
            errorMessage: 'Failed to initialize torrent: $e',
          ),
        );
        pumpQueue();
        _updateTelemetryWidget();
        _startingTaskIds.remove(task.id);
        return;
      }
    }

    // Fire-and-await so the queued→downloading transition is committed
    // before the first progress callback fires.
    // For torrents: also reset per-file downloaded bytes so the file list
    // starts from 0% (not carrying over stale 100% from a previous completion).
    final resetTorrentFiles = task.isTorrent && task.torrentFiles != null
        ? task.torrentFiles!.map((f) {
            final copy = Map<String, dynamic>.from(f);
            copy['downloadedBytes'] = 0;
            copy['speed'] = 0.0;
            return copy;
          }).toList()
        : null;

    await _setTask(
      task.copyWith(
        status: DownloadStatus.downloading,
        clearError: true,
        clearStatusMessage: true,
        clearCompletedAt: true,
        torrentFiles: resetTorrentFiles ?? task.torrentFiles,
        audioProgress: 0.0,
      ),
    );

    final notificationId = _getNotificationId(task.id);
    final isAutoName =
        task.fileName == 'torrent_download.zip' ||
        task.fileName.isEmpty ||
        task.fileName == fileNameFromUrl(task.url) ||
        task.fileName.startsWith('download_');

    final hasAudio = !task.isTorrent &&
        task.mergedAudioUrl != null &&
        task.mergedAudioUrl!.isNotEmpty;
    final audioTempPath = hasAudio ? '${task.tempFilePath}.audio' : null;
    // A combined YouTube task stores the total output size, but this request
    // transfers only its video stream. Passing the total makes byte ranges
    // exceed the video resource and causes an immediate 416/failed retry.
    final videoTransferSize = hasAudio && task.fileSize > task.audioSize
        ? task.fileSize - task.audioSize
        : task.fileSize;

    // YouTube CDN requires a Referer header matching the watch page URL.
    final isYoutube = task.downloadPageUrl != null &&
        (task.downloadPageUrl!.contains('youtube.com/') ||
            task.downloadPageUrl!.contains('youtu.be/'));

    // Separate cancel tokens for audio/video so we can cancel one if the other
    // fails, without a shared-cancel causing ParallelWaitError confusion.
    final videoCancelToken = CancelToken();
    final audioCancelToken = CancelToken();
    // Mirror the top-level cancel into both
    cancelToken.whenCancel.then((_) {
      if (!videoCancelToken.isCancelled) videoCancelToken.cancel();
      if (!audioCancelToken.isCancelled) audioCancelToken.cancel();
    });

    // YouTube streams use normal single-threaded mode as configured.
    final streamThreadCount = isYoutube ? 1 : task.threadCount;

    // Run video and audio sequentially (audio first, then video)
    final downloadFuture = () async {
      // Re-fetch current task state by ID to prevent using stale parameters if mutated during async gap
      final currentTask = _findTask(task.id);
      if (currentTask == null) return;
      task = currentTask;
      final maxRetries = _settingsProvider.autoRetryEnabled ? _settingsProvider.maxRetries : 0;
      int attempt = 0;
      while (true) {
        attempt++;
        try {
          await () async {
      if (hasAudio) {
                    debugPrint('[DMX] Sequential download: Starting audio first.');
                    await _downloadEngine.download(
                      url: task.mergedAudioUrl!,
                      tempFilePath: audioTempPath!,
                      localFilePath: audioTempPath,
                      knownFileSize: task.audioSize,
                      supportsResume: true,
                      cancelToken: audioCancelToken,
                      cookies: cookieString,
                      onProgress: (progress) {
                        final t = _findTask(task.id);
                        if (t == null || t.status != DownloadStatus.downloading) return;
                        final size = t.audioSize > 0 ? t.audioSize : progress.fileSize;
                        final p = size > 0 ? (progress.downloadedBytes / size).clamp(0.0, 1.0) : 0.0;
                        
                        final index = _tasks.indexWhere((x) => x.id == task.id);
                        if (index != -1) {
                          final updated = _tasks[index].copyWith(
                            audioProgress: p,
                            downloadedBytes: progress.downloadedBytes,
                            speed: progress.speed,
                            eta: progress.eta,
                            audioSize: size,
                          );
                          _tasks[index] = updated;
                          if (DateTime.now().millisecondsSinceEpoch - (_lastProgressUpdateTimes[task.id] ?? 0) >= 200) {
                            _lastProgressUpdateTimes[task.id] = DateTime.now().millisecondsSinceEpoch;
                            notifyListeners();
            
                            if (_settingsProvider.notificationsEnabled) {
                              final progressPercent = task.fileSize > 0
                                  ? ((progress.downloadedBytes / task.fileSize) * 100).round().clamp(0, 100)
                                  : 0;
                              _notificationService.showDownloadProgress(
                                notificationId: notificationId,
                                title: '${task.fileName} (Audio)',
                                progressPercent: progressPercent,
                                speed: updated.speedFormatted,
                                eta: updated.etaFormatted,
                                languageCode: _settingsProvider.languageCode,
                                payload: task.id,
                              );
                            }
                          }
                        }
                      },
                      speedLimitBytesPerSecond: () {
                        final current = _findTask(task.id);
                        if (current != null && current.speedLimitKbps > 0) {
                          return (current.speedLimitKbps * 1000) ~/ 8;
                        }
                        return _settingsProvider.speedLimitBytesPerSecond;
                      },
                      activeDownloadCount: () => downloadingTasksCount,
                      threadCount: streamThreadCount,
                      customUserAgent: _settingsProvider.customUserAgent,
                      referer: isYoutube ? task.downloadPageUrl : null,
                      enableProxy: _settingsProvider.enableProxy,
                      proxyAddress: _settingsProvider.proxyAddress,
                      proxyHost: _settingsProvider.proxyHost,
                      proxyPort: _settingsProvider.proxyPort,
                      proxyUsername: _settingsProvider.proxyUsername,
                      proxyPassword: _settingsProvider.proxyPassword,
                      bypassSSL: _settingsProvider.bypassSSL,
                      isNameAutoGenerated: false,
                    );
            
                    final audioFile = File(audioTempPath);
                    if (!await audioFile.exists()) {
                      throw Exception('Audio file not found after download: $audioTempPath');
                    }
                    final audioLen = await audioFile.length();
                    debugPrint('[DMX] Audio download complete: $audioTempPath ($audioLen bytes)');
                    if (audioLen == 0) {
                      throw Exception('Audio file is empty: $audioTempPath');
                    }
                    final idx = _tasks.indexWhere((x) => x.id == task.id);
                    if (idx != -1) {
                      _tasks[idx] = _tasks[idx].copyWith(
                        audioProgress: 1.0,
                        downloadedBytes: task.audioSize,
                      );
                    }
                  }
            
                  // Step 2: Download Video
                  debugPrint('[DMX] Sequential download: Starting video second.');
                  await _downloadEngine.download(
                    url: task.url,
                    tempFilePath: task.tempFilePath,
                    localFilePath: task.localFilePath,
                    knownFileSize: videoTransferSize,
                    supportsResume: task.supportsResume,
                    cancelToken: videoCancelToken,
                    isNameAutoGenerated: isAutoName,
                    referer: isYoutube ? task.downloadPageUrl : null,
                    getTorrentFiles: () => _findTask(task.id)?.torrentFiles ?? task.torrentFiles,
                    cookies: cookieString,
                    onProgress: (progress) {
                      final current = _findTask(task.id);
                      if (current == null || current.status != DownloadStatus.downloading) {
                        return;
                      }

                      // Issue 2 Fix: Lock progress updates to prevent race conditions during async state changes
                      if (_progressLock) return;
                      _progressLock = true;
                      try {
                        final index = _tasks.indexWhere((t) => t.id == task.id);
                        if (index == -1) return;

                        final now = DateTime.now().millisecondsSinceEpoch;
                        final lastUpdate = _lastProgressUpdateTimes[task.id] ?? 0;

                        final speedList = _speedHistories[task.id] ??= [];
                        speedList.add(progress.speed);
                        if (speedList.length > 20) {
                          speedList.removeAt(0);
                        }

                        // FIX #2: Re-read immediately before mutating and keep the read-modify-write
                        // synchronous so a concurrent update (e.g. YouTube URL refresh) is not clobbered.
                        final freshIndex = _tasks.indexWhere((t) => t.id == task.id);
                        if (freshIndex == -1) return;
                        final latest = _tasks[freshIndex];
                        if (latest.status != DownloadStatus.downloading) return;
                        final base = latest;

                        final newFileName = isAutoName && progress.fileName != null
                            ? progress.fileName!
                            : base.fileName;

                        final newLocalPath = newFileName != base.fileName
                            ? p.join(p.dirname(base.localFilePath), safeFileName(newFileName))
                            : base.localFilePath;

                        final newTempPath = newFileName != base.fileName
                            ? p.join(p.dirname(base.tempFilePath), '${safeFileName(newFileName)}.dmxpart')
                            : base.tempFilePath;

                        final newCategory = newFileName != base.fileName && base.category == 'Other'
                            ? categoryFromFileName(newFileName)
                            : base.category;

                        final resolvedVideoSize = progress.fileSize > 0 ? progress.fileSize : videoTransferSize;
                        final resolvedTotalSize = hasAudio ? resolvedVideoSize + base.audioSize : resolvedVideoSize;
                        final currentDownloadedBytes = (hasAudio ? base.audioSize : 0) + progress.downloadedBytes;

                        final updatedTask = base.copyWith(
                          fileName: newFileName,
                          localFilePath: newLocalPath,
                          tempFilePath: newTempPath,
                          category: newCategory,
                          fileSize: resolvedTotalSize,
                          downloadedBytes: currentDownloadedBytes,
                          speed: progress.speed,
                          eta: progress.eta,
                          chunks: progress.chunks ??
                              _buildChunks(
                                base.threadCount,
                                resolvedVideoSize,
                                progress.downloadedBytes,
                              ),
                          supportsResume: progress.supportsResume ?? base.supportsResume,
                          torrentFiles: progress.torrentFiles ?? base.torrentFiles,
                        );

                        if (now - lastUpdate >= 250) {
                          _lastProgressUpdateTimes[task.id] = now;
                          final freshIndex = _tasks.indexWhere((t) => t.id == task.id);
                          if (freshIndex != -1 && _tasks[freshIndex].status == DownloadStatus.downloading) {
                            _tasks[freshIndex] = updatedTask;
                          }
                          notifyListeners();

                          if (_settingsProvider.notificationsEnabled) {
                            final progressPercent = resolvedTotalSize > 0
                                ? ((currentDownloadedBytes / resolvedTotalSize) * 100).round().clamp(0, 100)
                                : 0;
                            _notificationService.showDownloadProgress(
                              notificationId: notificationId,
                              title: task.fileName,
                              progressPercent: progressPercent,
                              speed: updatedTask.speedFormatted,
                              eta: updatedTask.etaFormatted,
                              languageCode: _settingsProvider.languageCode,
                              payload: task.id,
                            );
                          }

                          // Keep the foreground service alive directly from the active
                          // download path so it never self-stops while bytes are flowing
                          BackgroundService.sendHeartbeat();
                        } else {
                          final freshIndex = _tasks.indexWhere((t) => t.id == task.id);
                          if (freshIndex != -1) _tasks[freshIndex] = updatedTask;
                          _pendingProgressUpdates.add(task.id);
                        }
                      } finally {
                        _progressLock = false;
                      }
                    },
                    speedLimitBytesPerSecond: () {
                      final current = _findTask(task.id);
                      if (current != null && current.speedLimitKbps > 0) {
                        return (current.speedLimitKbps * 1000) ~/ 8;
                      }
                      return _settingsProvider.speedLimitBytesPerSecond;
                    },
                    activeDownloadCount: () => downloadingTasksCount,
                    threadCount: streamThreadCount,
                    customUserAgent: _settingsProvider.customUserAgent,
                    enableProxy: _settingsProvider.enableProxy,
                    proxyAddress: _settingsProvider.proxyAddress,
                    proxyHost: _settingsProvider.proxyHost,
                    proxyPort: _settingsProvider.proxyPort,
                    proxyUsername: _settingsProvider.proxyUsername,
                    proxyPassword: _settingsProvider.proxyPassword,
                    bypassSSL: _settingsProvider.bypassSSL,
                  );
          }();
          return;
        } catch (error) {
          final isYoutubeDownload = task.downloadPageUrl != null &&
              YoutubeService.extractVideoId(task.downloadPageUrl!) != null;
          bool shouldRefreshYoutube = false;
          if (error is DioException && isYoutubeDownload) {
            final statusCode = error.response?.statusCode;
            if (statusCode == 403 || statusCode == 410) {
              shouldRefreshYoutube = true;
            }
          }
          if (shouldRefreshYoutube) {
            final ytMaxRetries = maxRetries > 0 ? maxRetries : 3;
            if (attempt > ytMaxRetries) {
              rethrow;
            }
            try {
              YoutubeService.resetClient();

              // For combined downloads (audio+video), use getFreshStreams
              // which returns both URLs. refreshStreamUrl only returns the
              // video URL, leaving the audio URL expired.
              Map<String, dynamic>? newUrlInfo;
              if (hasAudio) {
                final freshStreams = await YoutubeService.getFreshStreams(
                  task.downloadPageUrl!,
                );
                if (freshStreams != null && freshStreams['url'] != null) {
                  newUrlInfo = {
                    'url': freshStreams['url'],
                    'audioUrl': freshStreams['audioUrl'],
                  };
                }
              } else {
                newUrlInfo = await _refreshYoutubeStreamUrlSafe(
                  task.downloadPageUrl!,
                  task.url,
                );
              }
              if (newUrlInfo != null && newUrlInfo['url'] != null) {
                final refreshedUrl = newUrlInfo['url'] as String;
                final refreshedAudioUrl = newUrlInfo['audioUrl'] as String?;

                // Reject MIME type changes
                if (!_youtubeMimeCompatible(task.url, refreshedUrl)) {
                  rethrow;
                }

                final idx = _tasks.indexWhere((x) => x.id == task.id);
                if (idx != -1) {
                  _tasks[idx] = _tasks[idx].copyWith(
                    url: refreshedUrl,
                    mergedAudioUrl: refreshedAudioUrl ?? task.mergedAudioUrl,
                  );
                  task = _tasks[idx];
                }
                await _databaseService.saveTask(task);
                await Future.delayed(const Duration(seconds: 2));
                continue;
              }
            } catch (e) {
              // ignore
            }
          }
          rethrow;
        }
      }
    }().then((_) async {

          // Phase 3: Merge (only if audio was downloaded)
          if (hasAudio) {
            final currentForMerge = _findTask(task.id);
            if (currentForMerge == null) return;

            await _setTask(currentForMerge.copyWith(statusMessage: 'Merging video and audio...'));

            final mergedPath = '${currentForMerge.localFilePath}.merged.mp4';
            debugPrint('[DMX] Phase 3 — Merge starting:');
            debugPrint('[DMX]   Video: ${currentForMerge.localFilePath}');
            debugPrint('[DMX]   Audio: $audioTempPath');
            debugPrint('[DMX]   Output: $mergedPath');

            final videoFile = File(currentForMerge.localFilePath);
            if (await videoFile.exists()) {
              debugPrint('[DMX]   Video size: ${await videoFile.length()} bytes');
            } else {
              debugPrint('[DMX]   WARNING: Video file missing: ${currentForMerge.localFilePath}');
            }
            final af = File(audioTempPath!);
            if (await af.exists()) {
              debugPrint('[DMX]   Audio size: ${await af.length()} bytes');
            } else {
              debugPrint('[DMX]   WARNING: Audio file missing: $audioTempPath');
            }

            final success = await FFmpegMuxService.mergeVideoAudio(
              currentForMerge.localFilePath, audioTempPath, mergedPath);

            if (success) {
              final mergedFile = File(mergedPath);
              if (await mergedFile.exists()) {
                final mergedLen = await mergedFile.length();
                debugPrint('[DMX] Phase 3 — Merge successful: $mergedPath ($mergedLen bytes)');
                if (await videoFile.exists()) await videoFile.delete();
                await mergedFile.rename(currentForMerge.localFilePath);
                debugPrint('[DMX] Original video replaced with merged file');
              } else {
                debugPrint('[DMX] WARNING: Merged file not found at $mergedPath');
                throw Exception('Merged output file not found after successful FFmpeg run');
              }
              if (await af.exists()) await af.delete();
            } else {
              debugPrint('[DMX] Phase 3 — Merge FAILED — keeping original video file');
              if (await af.exists()) await af.delete();
              throw Exception('FFmpeg merge failed.');
            }
          }

          await _flushPendingProgress(task.id);
          _speedHistories.remove(task.id);
          _lastProgressUpdateTimes.remove(task.id);
          _lastDbSaveTimes.remove(task.id);

          var current = _findTask(task.id);
          if (current == null) return;
          if (current.status != DownloadStatus.downloading) return;
          
          final now = DateTime.now();
          final isSeedingTorrent = current.isTorrent &&
              current.seedingEnabled;
          if (!isSeedingTorrent && current.isTorrent) {
            // Torrent completed but seeding disabled: remove from engine
            final tid = _torrentIds[current.id];
            if (tid != null) {
              TorrentService.removeTorrent(tid);
              _torrentIds.remove(current.id);
            }
          }

          await _setTask(
            current.copyWith(
              clearError: true,
              clearStatusMessage: true,
              status: DownloadStatus.completed,
              downloadedBytes:
                  (current.isTorrent || hasAudio) && current.fileSize > 0
                  ? current.fileSize
                  : current.downloadedBytes,
              speed: 0,
              eta: 0,
              chunks: List<double>.filled(current.threadCount, 1.0),
              completedAt: now,
              updatedAt: now,
              torrentFiles: current.torrentFiles != null
                  ? markTorrentFilesCompleted(current.torrentFiles!)
                  : null,
            ),
          );

          if (_settingsProvider.vibration) {
            HapticFeedback.vibrate();
          }

          final finalPath = p.join(current.savePath, current.fileName);
          if (Platform.isAndroid && finalPath.isNotEmpty) {
            try {
              _mediaChannel.invokeMethod('scanMedia', {'path': finalPath});
            } catch (e) {
              debugPrint('Failed to scan media: $e');
            }
          }

          if (_settingsProvider.notificationsEnabled) {
            _notificationService.showDownloadComplete(
              notificationId: notificationId,
              title: task.fileName,
              playSound: _settingsProvider.soundNotification,
            );
          }
        })
        .catchError((Object error, StackTrace stackTrace) async {
          final realError = error;
          
          debugPrint('================= DOWNLOAD ERROR =================');
          debugPrint('Task ID: ${task.id}');
          debugPrint('URL: ${task.url}');
          debugPrint('Error: $realError');
          if (realError is DioException) {
            debugPrint('DioException Type: ${realError.type}');
            debugPrint('DioException Message: ${realError.message}');
            debugPrint('DioException Response: ${realError.response?.data}');
            debugPrint('DioException Status: ${realError.response?.statusCode}');
          }
          debugPrint('Stacktrace: $stackTrace');
          debugPrint('==================================================');
          
          await _flushPendingProgress(task.id);
          final current = _findTask(task.id);
          if (current == null) return;

          if (realError is DioException && realError.type == DioExceptionType.cancel) {
            _retryCounts.remove(task.id);
            if (current.status == DownloadStatus.downloading) {
              await _setTask(current.copyWith(speed: 0, clearEta: true));
            }
            _notificationService.cancelNotification(notificationId);
            return;
          }

          // Clean up orphaned temp files on failure (audio or video may have been partially downloaded)
          try {
            if (hasAudio && audioTempPath != null) {
              final audioFile = File(audioTempPath);
              if (await audioFile.exists()) await audioFile.delete();
            }
            final videoTemp = File(current.tempFilePath);
            if (await videoTemp.exists()) await videoTemp.delete();
          } catch (_) {}

          final isRetryable = _isRetryableError(realError);
          final maxRetries = _settingsProvider.autoRetryEnabled && isRetryable
              ? _settingsProvider.maxRetries
              : 0;
          final currentRetry = _retryCounts[task.id] ?? 0;

          if (currentRetry < maxRetries) {
            _retryCounts[task.id] = currentRetry + 1;
            final delaySeconds = _settingsProvider.retryDelaySeconds;
            debugPrint(
              'Transient error for task ${task.id}. Retrying (${currentRetry + 1}/$maxRetries) in $delaySeconds seconds...',
            );

            await _setTask(
              current.copyWith(
                status: DownloadStatus.queued,
                speed: 0,
                errorMessage:
                    'Retrying in $delaySeconds seconds: ${_errorMessage(realError)}',
              ),
            );

            _retryTimers[task.id]?.cancel();
            _retryTimers[task.id] = Timer(Duration(seconds: delaySeconds), () {
              _retryTimers.remove(task.id);
              final checkedTask = _findTask(task.id);
              if (checkedTask != null &&
                  checkedTask.status == DownloadStatus.queued) {
                pumpQueue();
              }
            });
            return;
          }

          _retryCounts.remove(task.id);
          await _setTask(
            current.copyWith(
              status: DownloadStatus.failed,
              speed: 0,
              clearEta: true,
              clearStatusMessage: true,
              errorMessage: _errorMessage(realError),
            ),
          );
          if (_settingsProvider.notificationsEnabled) {
            _notificationService.showDownloadFailed(
              notificationId: notificationId,
              title: task.fileName,
              error: _errorMessage(realError),
              playSound: _settingsProvider.soundNotification,
            );
          }
        })
        .whenComplete(() {
          _cancelTokens.remove(task.id);
          _activeFutures.remove(task.id);
          // Don't pumpQueue here if this task was set to queued (retry
          // scheduled by catchError). The retry timer will restart it after
          // the configured delay — immediate pumpQueue would defeat the delay
          // and create a fast fail loop.
          final status = _findTask(task.id)?.status;
          if (status != DownloadStatus.queued) {
            pumpQueue();
          }
          if (downloadingTasksCount == 0) {
            BackgroundService.stop();
            _stopWidgetTimer();
          } else {
            _updateBackgroundNotification();
          }
          _updateTelemetryWidget();
        });
    _startingTaskIds.remove(task.id);
    _activeFutures[task.id] = downloadFuture;
  }

  Future<void> _setTask(DownloadTask updated) async {
    final index = _tasks.indexWhere((task) => task.id == updated.id);
    if (index == -1) return;

    _tasks[index] = updated;
    filteredTasksDirty = true;

    try {
      await _databaseService.saveTask(updated);
    } catch (e) {
      debugPrint('Error saving task to database: $e');
    }
    updateActualTorrentUploadLimit();
    notifyListeners();
  }

  void _updateBackgroundNotification() {
    final active = downloadingTasksCount;
    if (active > 0) {
      BackgroundService.updateNotification(
        title: 'XDM - $active active',
        content: '${formatBytes(currentDownloadSpeed)}/s',
      );
    }
  }

  DownloadTask? _findTask(String id) {
    final index = _tasks.indexWhere((task) => task.id == id);
    if (index == -1) return null;
    return _tasks[index];
  }

  /// Build per-thread chunk progress reflecting parallel progress.
  List<double> _buildChunks(
    int threadCount,
    int fileSize,
    int downloadedBytes,
  ) {
    if (fileSize <= 0 || threadCount <= 0) {
      return List<double>.filled(threadCount, 0.0);
    }
    final progress = (downloadedBytes / fileSize).clamp(0.0, 1.0);
    return List<double>.filled(threadCount, progress);
  }

  // FIX #4: Prevent YouTube refresh from swapping video/audio MIME type.
  bool _youtubeMimeCompatible(String oldUrl, String newUrl) {
    final oldMime = Uri.tryParse(oldUrl)?.queryParameters['mime']?.split('/').first;
    final newMime = Uri.tryParse(newUrl)?.queryParameters['mime']?.split('/').first;
    if (oldMime == null || newMime == null) return true;
    return oldMime == newMime;
  }

  Future<Map<String, dynamic>?> _refreshYoutubeStreamUrlSafe(
    String pageUrl,
    String oldStreamUrl,
  ) async {
    final refreshed = await YoutubeService.refreshStreamUrl(
      pageUrl,
      oldStreamUrl,
    );
    if (refreshed == null || refreshed.isEmpty) return refreshed;

    final refreshedUrl = refreshed['url'] as String?;
    if (refreshedUrl != null &&
        !_youtubeMimeCompatible(oldStreamUrl, refreshedUrl)) {
      throw Exception(
        'YouTube stream type changed during URL refresh. Please re-add the download.',
      );
    }

    return refreshed;
  }

  String _errorMessage(Object error) {
    if (error is DioException) {
      if (error.response?.statusCode != null) {
        final code = error.response!.statusCode;
        return switch (code) {
          403 =>
            '403 Forbidden: Access denied. (Raw: ${error.message})',
          401 =>
            '401 Unauthorized: Authentication is required. (Raw: ${error.message})',
          404 => '404 Not Found: The file was not found. (Raw: ${error.message})',
          410 =>
            '410 Gone: The file has been permanently removed. (Raw: ${error.message})',
          416 =>
            '416 Range Not Satisfiable: Invalid byte range. (Raw: ${error.message})',
          500 => '500 Internal Server Error. (Raw: ${error.message})',
          503 =>
            '503 Service Unavailable: Server is overloaded. (Raw: ${error.message})',
          _ =>
            'HTTP Error $code: ${error.message ?? "Server returned invalid response."}',
        };
      }
      return 'Dio Error: ${error.message ?? error.type.name}';
    }
    return 'Error: ${error.toString()}';
  }

  bool _isRetryableError(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('merge') || msg.contains('ffmpeg')) {
      return false;
    }
    if (error is DioException) {
      if (error.type == DioExceptionType.cancel) {
        return false;
      }
      if (error.response?.statusCode != null) {
        final code = error.response!.statusCode;
        // Do not retry client errors (400 Bad Request, 401 Unauthorized, 403 Forbidden, 404 Not Found, 410 Gone, 416 Range Not Satisfiable)
        if (code == 400 ||
            code == 401 ||
            code == 403 ||
            code == 404 ||
            code == 410 ||
            code == 416) {
          return false;
        }
      }
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Connectivity & scheduling
  // ---------------------------------------------------------------------------

  int? _lastCleanupDays;

  void _onSettingsChanged() {
    _checkNetworkConnectivity();
    _downloadEngine.updateSpeedLimit(_settingsProvider.speedLimitBytesPerSecond, downloadingTasksCount);
    updateActualTorrentUploadLimit();
    TorrentService.applyAdvancedSettings(_settingsProvider);
    if (_lastCleanupDays == null) {
      _lastCleanupDays = _settingsProvider.cleanupDays;
    } else if (_lastCleanupDays != _settingsProvider.cleanupDays) {
      _lastCleanupDays = _settingsProvider.cleanupDays;
      load(pauseOrphanDownloads: false);
    }
    pumpQueue();
  }

  void _initConnectivity() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      _currentConnectivity = results;
      _hasResolvedInitialConnectivity = true;
      _checkNetworkConnectivity();
    });
    Connectivity().checkConnectivity().then((results) {
      if (!_hasResolvedInitialConnectivity) {
        _currentConnectivity = results;
        _hasResolvedInitialConnectivity = true;
        _checkNetworkConnectivity();
      }
    });
  }

  Future<void> _checkNetworkConnectivity({bool skipPump = false}) async {
    final hasNoNetwork = _currentConnectivity.contains(ConnectivityResult.none) || _currentConnectivity.isEmpty;
    
    if (hasNoNetwork) {
      await _pauseForNetworkDisconnect();
      return;
    } else {
      await _resumeFromNetworkDisconnect(skipPump: skipPump);
    }

    if (!_settingsProvider.wifiOnly) {
      await _resumeWaitingForWifi(skipPump: skipPump);
      return;
    }

    final hasWifi =
        _currentConnectivity.contains(ConnectivityResult.wifi) ||
        _currentConnectivity.contains(ConnectivityResult.ethernet);

    if (!hasWifi) {
      await _pauseForWifiOnly();
    } else {
      await _resumeWaitingForWifi(skipPump: skipPump);
    }
  }

  Future<void> _pauseForNetworkDisconnect() async {
    final active = _tasks.where(
      (task) =>
          task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued,
    );
    for (final task in active.toList()) {
      _tasksPausedDueToNetwork.add(task.id);
      if (task.status == DownloadStatus.downloading) {
        final torrentId = _torrentIds[task.id];
        if (torrentId != null) {
          TorrentService.pauseTorrent(torrentId);
        }
        _cancelTokens[task.id]?.cancel('network_disconnect_pause');
        _cancelTokens.remove(task.id);
      }
      await _setTask(
        task.copyWith(
          status: DownloadStatus.paused,
          speed: 0,
          clearEta: true,
          errorMessage: 'Waiting for network connection...',
        ),
      );
    }
  }

  Future<void> _resumeFromNetworkDisconnect({bool skipPump = false}) async {
    if (_tasksPausedDueToNetwork.isEmpty) return;
    
    final waiting = _tasks.where(
      (task) =>
          _tasksPausedDueToNetwork.contains(task.id) &&
          task.status == DownloadStatus.paused,
    );
    for (final task in waiting.toList()) {
      await _setTask(
        task.copyWith(
          status: DownloadStatus.queued,
          clearError: true,
          clearEta: true,
        ),
      );
    }
    _tasksPausedDueToNetwork.clear();
    if (!skipPump) pumpQueue();
  }

  Future<void> _pauseForWifiOnly() async {
    final active = _tasks.where(
      (task) =>
          task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued,
    );
    for (final task in active.toList()) {
      if (task.status == DownloadStatus.downloading) {
        final torrentId = _torrentIds[task.id];
        if (torrentId != null) {
          TorrentService.pauseTorrent(torrentId);
        }
        _cancelTokens[task.id]?.cancel('wifi_only_pause');
        _cancelTokens.remove(task.id);
      }
      await _setTask(
        task.copyWith(
          status: DownloadStatus.paused,
          speed: 0,
          clearEta: true,
          errorMessage: 'Waiting for WiFi connection',
        ),
      );
    }
  }

  Future<void> _resumeWaitingForWifi({bool skipPump = false}) async {
    final waiting = _tasks.where(
      (task) =>
          task.status == DownloadStatus.paused &&
          task.errorMessage == 'Waiting for WiFi connection',
    );
    for (final task in waiting.toList()) {
      await _setTask(
        task.copyWith(
          status: DownloadStatus.queued,
          clearError: true,
          clearEta: true,
        ),
      );
    }
    if (!skipPump) pumpQueue();
  }

  void _startSchedulingTimer() {
    _schedulingTimer?.cancel();
    _schedulingTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _checkScheduledDownloads();
    });
  }

  Future<void> _checkScheduledDownloads() async {
    final now = DateTime.now();
    var hasChanges = false;
    final saves = <Future<void>>[];
    for (var i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      if (task.status == DownloadStatus.paused &&
          !task.pausedByUser &&
          task.scheduledAt != null &&
          task.scheduledAt!.isBefore(now)) {
        _tasks[i] = task.copyWith(
          status: DownloadStatus.queued,
          clearError: true,
          clearCompletedAt: true,
          clearScheduledAt: true,
        );
        saves.add(_databaseService.saveTask(_tasks[i]));
        hasChanges = true;
      }
    }
    if (saves.isNotEmpty) {
      try {
        await Future.wait(saves);
      } catch (e) {
        debugPrint('Failed to save scheduled tasks: $e');
      }
    }
    if (hasChanges) {
      updateActualTorrentUploadLimit();
      notifyListeners();
      pumpQueue();
    }
  }

  // ---------------------------------------------------------------------------
  // Widget / telemetry timer
  // ---------------------------------------------------------------------------

  void _updateTelemetryWidget() {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        const MethodChannel('com.example.dmx/widget')
            .invokeMethod('updateWidget', {
              'activeCount': downloadingTasksCount,
              'totalSpeed': currentDownloadSpeedFormatted,
            })
            .catchError((e) {
              debugPrint('Failed to update telemetry widget via future: $e');
            });
      } catch (e) {
        debugPrint('Failed to update telemetry widget: $e');
      }
    }
  }

  void _startWidgetTimer() {
    _widgetTimer?.cancel();
    if (downloadingTasksCount > 0 || seedingTasksCount > 0) {
      _widgetTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
        _updateTelemetryWidget();
        BackgroundService.sendHeartbeat();
        
        final saves = <Future<void>>[];
        for (var i = 0; i < _tasks.length; i++) {
          final t = _tasks[i];
          if (t.status == DownloadStatus.downloading) {
            final lastBytes = _lastDbSaveBytes[t.id] ?? -1;
            if (t.downloadedBytes != lastBytes) {
              _lastDbSaveBytes[t.id] = t.downloadedBytes;
              saves.add(_databaseService.saveTask(t));
            }
          }
          // Do NOT save queued tasks here — they have no meaningful progress
        }
        Future.wait(saves).catchError((e) {
          debugPrint('Batch DB save failed: $e');
          return <void>[];
        });

        if (updateSeedingSpeeds()) {
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
    if (task.threadCount == threadCount) return;

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
        // Clean up temp file, state file, and all part files
        final tempFile = File(task.tempFilePath);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        final stateFile = File('${task.tempFilePath}.dmxstate');
        if (await stateFile.exists()) {
          await stateFile.delete();
        }
        for (int i = 0; i < task.threadCount; i++) {
          final partFile = File('${task.tempFilePath}.part$i');
          if (await partFile.exists()) {
            await partFile.delete();
          }
        }
      } catch (e) {
        debugPrint('Error deleting segment files: $e');
      }

      task = task.copyWith(
        threadCount: threadCount,
        downloadedBytes: 0,
        chunks: List<double>.filled(threadCount, 0.0),
        status: DownloadStatus.paused,
      );
    } else {
      task = task.copyWith(
        threadCount: threadCount,
        chunks: List<double>.filled(threadCount, 0.0),
      );
    }

    _tasks[activeIdx] = task;
    await _databaseService.saveTask(task);
    notifyListeners();
    _updateTelemetryWidget();
  }

  Future<void> updateTorrentTaskFiles(
    String taskId,
    List<Map<String, dynamic>> files,
  ) async {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final task = _tasks[index];

    // Calculate new total size of selected files
    final selectedSize = files
        .where((f) => f['selected'] == true)
        .fold(0, (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0));

    final updated = task.copyWith(
      torrentFiles: files,
      fileSize: selectedSize > 0 ? selectedSize : task.fileSize,
    );

    _tasks[index] = updated;
    await _databaseService.saveTask(updated);

    // Propagate priority changes to the live torrent engine.
    final torrentId = _torrentIds[taskId];
    if (torrentId != null) {
      final priorities = files.map((f) {
        final selected = f['selected'] as bool? ?? true;
        if (!selected) return 0;
        return f['priority'] as int? ?? 4;
      }).toList();
      TorrentService.setFilePriorities(torrentId, priorities);
    }

    notifyListeners();
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
    final isNewTorrent =
        cleanUrl.startsWith('magnet:') ||
        cleanUrl.toLowerCase().endsWith('.torrent');

    if (wasTorrent || isNewTorrent) {
      final torrentId = _torrentIds[taskId];
      if (torrentId != null) {
        TorrentService.removeTorrent(torrentId);
        _torrentIds.remove(taskId);
      }

      await _cleanupPartFiles(task);

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
    final resolvedSupportsResume = isRefresh ? true : (metadata?.supportsResume ?? task.supportsResume);

    bool sizeChanged = false;
    
    final oldUri = Uri.tryParse(task.url);
    final newUri = Uri.tryParse(cleanUrl);
    final oldItag = oldUri?.queryParameters['itag'];
    final newItag = newUri?.queryParameters['itag'];
    final itagChanged = oldItag != null && newItag != null && oldItag != newItag;

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

    if (sizeChanged) {
      await _cleanupPartFiles(task);
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

  Future<void> updateTaskUrlAndResume(String id, String newUrl, {String? newAudioUrl}) async {
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
      await updateTaskUrl(id, newUrl, newAudioUrl: newAudioUrl);
      final updated = _findTask(id);
      if (updated != null && updated.status != DownloadStatus.downloading) {
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
      } catch (_) {}
    }

    final torrentId = _torrentIds[id];
    if (torrentId != null) {
      TorrentService.removeTorrent(torrentId);
      _torrentIds.remove(id);
    }

    await _cleanupPartFiles(task);

    try {
      final localFile = File(task.localFilePath);
      if (await localFile.exists()) {
        await localFile.delete();
      }
    } catch (e) {
      debugPrint('Failed to delete completed file during start over: $e');
    }

    await _setTask(
      task.copyWith(
        url: newUrl.trim(),
        mergedAudioUrl: newAudioUrl ?? task.mergedAudioUrl,
        clearMergedAudioUrl: clearAudioUrl,
        fileSize: newFileSize ?? task.fileSize,
        audioSize: newAudioSize ?? task.audioSize,
        status: DownloadStatus.queued,
        downloadedBytes: 0,
        speed: 0,
        clearEta: true,
        clearError: true,
        clearCompletedAt: true,
        chunks: List<double>.filled(task.threadCount, 0.0),
      ),
    );

    pumpQueue();
    _startWidgetTimer();
    _updateTelemetryWidget();
  }

  // ---------------------------------------------------------------------------
  // Dispose
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _settingsProvider.removeListener(_onSettingsChanged);
    _actionSubscription?.cancel();
    _torrentUpdatesSubscription?.cancel();
    _connectivitySubscription?.cancel();
    _schedulingTimer?.cancel();
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _widgetTimer?.cancel();
    for (final token in _cancelTokens.values) {
      token.cancel('provider disposed');
    }
    _cancelTokens.clear();
    _activeFutures.clear();
    _downloadEngine.close();
    super.dispose();
  }
}
