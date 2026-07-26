import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:webview_cookie_manager/webview_cookie_manager.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logging/logging.dart';
import 'package:open_filex/open_filex.dart' as open_filex;
import '../../../core/services/torrent_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/services/update_service.dart';

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

/// The central [ChangeNotifier] that owns the download task list and
/// orchestrates all state mutations.
///
/// ## Mixin Architecture
///
/// This class uses several mixins to keep concerns separated:
///
///   - **[DownloadFilterMixin]**  — filtering, sorting, and search of the
///     task list. Requires `providerTasks`, `findTaskById` and the
///     `filteredTasksDirty` flag.
///   - **[DownloadQueueMixin]**  — concurrency-limit logic and queue
///     pumping. Requires `startTaskFromQueue`, `findTaskById`,
///     `isTaskWaitingForRetry`, and `pendingStartCount`.
///   - **[DownloadTorrentMixin]**  — torrent seeding resume/update logic.
///     Requires `providerTorrentIds`, `providerLatestTorrentStats`,
///     `providerSettingsProvider`, `findTaskById`, `notifyListeners`.
///   - **[DownloadBackupMixin]**  — backup export/import and encryption.
///     Requires `providerTasks`, `providerDatabaseService`, `notifyListeners`,
///     `filteredTasksDirty`, `updateTelemetryWidget`.
///
/// Each mixin declares an abstract contract that must be fulfilled by the
/// host class. The relevant property/method implementations are grouped
/// in the "Mixin contract implementations" section below.
class DownloadProvider extends ChangeNotifier
    with
        DownloadFilterMixin,
        DownloadQueueMixin,
        DownloadTorrentMixin,
        DownloadBackupMixin {
  static const _mediaChannel = MethodChannel('com.example.dmx/media');

  // ---------------------------------------------------------------------------
  // Status message constants (public in DownloadTask for i18n)
  // ---------------------------------------------------------------------------

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
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, Queue<double>> _speedHistories = {};
  final Map<String, ({String cookie, DateTime timestamp})> _cookieCache = {};
  static const int _cookieCacheMaxSize = 50;
  final Map<String, Future<void>> _dbSaveQueues = {};
  final Map<String, int> _ytLowSpeedCounts = {};
  final Map<String, bool> _ytThrottlingRefreshing = {};
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

  List<double> getSpeedHistory(String id) => _speedHistories[id]?.toList() ?? const [];

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

  @override
  void providerNotifyListeners() => notifyListeners();

  @override
  void providerStartWidgetTimer() => _startWidgetTimer();

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
      return task.downloadedBytes;
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
    // Cancel stale notifications from previous sessions
    await _notificationService.cancelAll();

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
              errorMessage: DownloadStatusMessages.pausedOrphaned,
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

    // Phase 1 — load tasks into memory immediately so the UI can render.
    // File-reconciliation I/O is deferred to phase 2 (post-first-frame) below.
    _tasks
      ..clear()
      ..addAll(loaded);

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
                t.errorMessage != DownloadStatusMessages.waitingWifi &&
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

    // Phase 2 — deferred per-task file reconciliation (I/O heavy).
    // Runs after the first frame so the UI renders immediately with stale
    // progress, then updates in place once files are stat'ed.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final reconciled = <DownloadTask>[];
      for (final task in _tasks) {
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

      for (var i = 0; i < reconciled.length; i++) {
        if (i < _tasks.length && _tasks[i].id == reconciled[i].id) {
          _tasks[i] = reconciled[i];
        }
      }
      notifyListeners();
    });
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
    bool isAppUpdate = false,
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
            isAppUpdate: isAppUpdate,
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
    bool isAppUpdate = false,
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

    String resolvedCategory;
    String fileName;
    int fileSize;
    bool supportsResume;

    // For all downloads (magnet, torrent, HTTP), bypass synchronous metadata resolve
    // to keep UI thread fully responsive. Metadata resolves in the background inside DownloadEngine.
    // Calculate size from torrentFiles if available
    final int torrentFilesTotalSize = (torrentFiles != null && torrentFiles.isNotEmpty)
        ? torrentFiles.where((f) => f['selected'] == true).fold(0, (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0))
        : 0;

    if (isMagnet) {
      final parsed = parseMagnetUrl(url.trim());
      final rawMagnetName = parsed['name'] ?? 'Torrent Download';
      final magnetName = safeFileName(rawMagnetName.replaceAll('+', ' '));
      fileName = name.trim().isNotEmpty
          ? safeFileName(name.trim().replaceAll('+', ' '))
          : magnetName;
      fileSize = size > 0 ? size : (torrentFilesTotalSize > 0 ? torrentFilesTotalSize : 0);

      // Determine category from primary torrent file if present, else from fileName
      String catCandidate = categoryFromFileName(fileName);
      if ((catCandidate == 'Other' || catCandidate.isEmpty) &&
          torrentFiles != null &&
          torrentFiles.isNotEmpty) {
        final firstFile = torrentFiles.firstWhere(
          (f) => f['selected'] == true,
          orElse: () => torrentFiles.first,
        );
        final firstFileName = (firstFile['name'] as String? ?? '').replaceAll('+', ' ');
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
      fileSize = size > 0 ? size : (torrentFilesTotalSize > 0 ? torrentFilesTotalSize : 0);
      resolvedCategory = (category.trim().isNotEmpty && category != 'Auto')
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
    final localFilePath = await getUniqueFilePath(
      directory,
      fileName,
    );
    final uniqueName = p.basename(localFilePath);
    final tempFilePath = _downloadEngine.buildTempFilePath(directory, uniqueName);
    final now = DateTime.now();

    final isScheduled = scheduledAt != null && scheduledAt.isAfter(now);

    final effectiveThreadCount = threadCount;

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
      threadCount: effectiveThreadCount,
      chunks: List<double>.filled(effectiveThreadCount, 0.0),
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
      isAppUpdate: isAppUpdate,
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
    if (action == null) return;

    switch (action) {
      case 'pause':
        if (taskId != null) pauseTask(taskId);
        break;
      case 'resume':
        if (taskId != null) resumeTask(taskId);
        break;
      case 'cancel':
        if (taskId != null) cancelTask(taskId);
        break;
      case 'pause_all':
        pauseAllTasks();
        break;
      case 'resume_all':
        resumeAllTasks();
        break;
      case 'install_apk':
      case 'tap':
        if (taskId != null) {
          final task = _findTask(taskId);
          if (task != null && task.isAppUpdate && task.status == DownloadStatus.completed) {
            open_filex.OpenFilex.open(task.localFilePath);
          }
        }
        break;
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
    pumpQueue();
    _updateTelemetryWidget();
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
                final fullPath = p.normalize(p.join(task.savePath, relPath));
                if (!fullPath.startsWith(task.savePath)) {
                  debugPrint('[DMX] Blocked path traversal attempt: $relPath');
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
      _lastDbSaveBytes.remove(id);
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
    try {
      await _startTaskBody(task);
    } finally {
      _startingTaskIds.remove(task.id);
    }
  }

  Future<void> _startTaskBody(DownloadTask task) async {
    // Clean up stale torrent IDs for tasks that no longer exist
    _torrentIds.removeWhere((id, _) => !_tasks.any((t) => t.id == id));

    // Apply global connection cap override from queue pump (runtime-only, never mutates stored task)
    final runtimeThreadCount =
        effectiveThreadOverrides.remove(task.id) ?? task.threadCount;

    final hasWifiOrEthernet =
        _currentConnectivity.contains(ConnectivityResult.wifi) ||
        _currentConnectivity.contains(ConnectivityResult.ethernet);
    if (_settingsProvider.wifiOnly && !hasWifiOrEthernet) {
      await _setTask(
        task.copyWith(
          status: DownloadStatus.paused,
          errorMessage: DownloadStatusMessages.waitingWifi,
        ),
      );
      return;
    }

    if (downloadingTasksCount == 0) {
      BackgroundService.start();
      // Prompt for battery optimization exemption once per app install
      if (!_settingsProvider.batteryOptimizationPrompted) {
        _settingsProvider.setBatteryOptimizationPrompted(true);
        PermissionService().requestBatteryOptimizationExemption();
      }
    }
    _updateBackgroundNotification();
    _startWidgetTimer();
    _updateTelemetryWidget();

    // Periodic cleanup of stale cookie cache entries
    if (_cookieCache.length > _cookieCacheMaxSize ~/ 2) {
      final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
      _cookieCache.removeWhere((_, entry) => entry.timestamp.isBefore(cutoff));
    }

    // Extract cookies from native WebView for authentication (using a 5-minute TTL cache)
    String cookieString = '';
    try {
      final cookieUrl = task.downloadPageUrl ?? task.url;
      final uri = Uri.tryParse(cookieUrl);
      if (uri != null) {
        final origin = '${uri.scheme}://${uri.host}';
        final now = DateTime.now();
        final cached = _cookieCache[origin];
        if (cached != null && now.difference(cached.timestamp) < const Duration(minutes: 5)) {
          cookieString = cached.cookie;
        } else {
          final cookies = await WebviewCookieManager().getCookies(origin);
          cookieString = cookies.map((c) => '${c.name}=${c.value}').join('; ');
          _cookieCache[origin] = (cookie: cookieString, timestamp: now);
          if (_cookieCache.length > _cookieCacheMaxSize) {
            final oldest = _cookieCache.entries
                .reduce((a, b) => a.value.timestamp.isBefore(b.value.timestamp) ? a : b)
                .key;
            _cookieCache.remove(oldest);
          }
        }
      }
    // ignore: avoid_catches_without_on_clauses
    } catch (e) {
      debugPrint('[DMX] Cookie resolution error: $e');
    }

    // Just-in-time stream resolution for YouTube videos
    final youtubeUrl = task.downloadPageUrl ?? task.url;
    if (task.youtubeQualityPreset != null &&
        (youtubeUrl.contains('youtube.com/') ||
            youtubeUrl.contains('youtu.be/'))) {
      if (cookieString.isNotEmpty) {
        YoutubeService.signIn(cookieString);
      }
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
              final videoSize = streamInfo['videoSize'] as int? ?? 0;
              final audioSize = streamInfo['audioSize'] as int? ?? 0;
              // Fall back to the total 'size' field when backend doesn't return
              // separate video/audio sizes (common with the /extract endpoint).
              final totalSize = (videoSize + audioSize) > 0
                  ? videoSize + audioSize
                  : (streamInfo['size'] as int? ?? 0);
              task = task.copyWith(
                url: streamInfo['src'] as String,
                mergedAudioUrl: streamInfo['audioSrc'] as String,
                fileSize: totalSize,
                audioSize: audioSize,
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
          } else if (task.url.isNotEmpty && !task.url.contains('youtube.com/')) {
            debugPrint('[DMX] YoutubeService.getStreamForVideo returned null; proceeding with pre-resolved stream URL.');
          } else {
            throw Exception('Stream not available');
          }
        }
      } catch (e) {
        if (task.url.isNotEmpty && !task.url.contains('youtube.com/')) {
          debugPrint('[DMX] YoutubeService stream resolution error ($e); proceeding with pre-resolved stream URL.');
        } else {
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
          return;
        }
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
        return;
      }
    }

    // Fire-and-await so the queued→downloading transition is committed
    // before the first progress callback fires.
    // For torrents: check real downloaded percentage on disk before starting/resuming
    final verifiedTorrentFiles = task.isTorrent && task.torrentFiles != null
        ? checkRealTorrentDiskProgress(task)
        : task.torrentFiles;

    int realTotalDownloaded = task.downloadedBytes;
    if (task.isTorrent && verifiedTorrentFiles != null && verifiedTorrentFiles.isNotEmpty) {
      final totalDiskDownloaded = verifiedTorrentFiles
          .where((f) => (f['selected'] as bool? ?? true))
          .fold<int>(0, (sum, f) => sum + ((f['downloadedBytes'] as int?) ?? 0));
      if (totalDiskDownloaded > realTotalDownloaded) {
        realTotalDownloaded = totalDiskDownloaded;
      }
    }

    await _setTask(
      task.copyWith(
        status: DownloadStatus.downloading,
        downloadedBytes: realTotalDownloaded,
        clearError: true,
        clearStatusMessage: true,
        clearCompletedAt: true,
        torrentFiles: verifiedTorrentFiles,
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

    // Detect YouTube early so we can skip CDN HEAD probes that trigger 429s.
    final isYoutube = task.downloadPageUrl != null &&
        (task.downloadPageUrl!.contains('youtube.com/') ||
            task.downloadPageUrl!.contains('youtu.be/'));

    // Ensure audioSize is properly set for combined downloads.
    // Skip for YouTube — googlevideo.com CDN URLs 429 on extra HEAD requests
    // and the audio size is already provided by the stream resolution step.
    if (hasAudio && task.audioSize <= 0 && task.mergedAudioUrl != null && !isYoutube) {
      try {
        final meta = await _downloadEngine.resolveMetadata(
          url: task.mergedAudioUrl!,
          customUserAgent: _settingsProvider.customUserAgent,
          enableProxy: _settingsProvider.enableProxy,
          proxyAddress: _settingsProvider.proxyAddress,
          proxyHost: _settingsProvider.proxyHost,
          proxyPort: _settingsProvider.proxyPort,
          bypassSSL: _settingsProvider.bypassSSL,
          cookies: cookieString,
          oauthToken: YoutubeService.oauthToken,
        );
        if (meta.fileSize > 0) {
          final idx = _tasks.indexWhere((t) => t.id == task.id);
          if (idx != -1) {
            _tasks[idx] = _tasks[idx].copyWith(audioSize: meta.fileSize);
            task = _tasks[idx];
          }
        }
      } catch (e) {
        debugPrint('[DMX] Failed to resolve audio size: $e');
      }
    }

    // Recalculate video transfer size with correct audio size.
    // When sizes were set from stream info: videoTransferSize = fileSize - audioSize.
    // When only total fileSize is known (no sub-sizes from backend): use fileSize directly
    // and rely on the engine's own probe to determine actual video segment size.
    int videoTransferSize;
    if (hasAudio && task.audioSize > 0 && task.fileSize > task.audioSize) {
      videoTransferSize = task.fileSize - task.audioSize;
    } else if (hasAudio && task.audioSize > 0 && task.fileSize > 0) {
      // fileSize may only represent the video portion (backend returned total=videoSize)
      // or total is equal to audioSize — treat fileSize as total and subtract audio.
      videoTransferSize = (task.fileSize - task.audioSize).clamp(0, task.fileSize);
    } else {
      videoTransferSize = task.fileSize;
    }

    // If the video transfer size is still unknown and this is NOT a YouTube
    // download, probe the video URL via HEAD so the engine can activate
    // multi-threaded mode. We skip this for YouTube because googlevideo.com
    // CDN URLs 429 easily and every extra HEAD wastes a signed URL's limited
    // window — the engine's single-thread fallback handles them fine.
    if (hasAudio && videoTransferSize <= 0 && !isYoutube) {
      try {
        final videoMeta = await _downloadEngine.resolveMetadata(
          url: task.url,
          customUserAgent: _settingsProvider.customUserAgent,
          enableProxy: _settingsProvider.enableProxy,
          proxyAddress: _settingsProvider.proxyAddress,
          proxyHost: _settingsProvider.proxyHost,
          proxyPort: _settingsProvider.proxyPort,
          bypassSSL: _settingsProvider.bypassSSL,
          cookies: cookieString,
          oauthToken: YoutubeService.oauthToken,
        );
        if (videoMeta.fileSize > 0) {
          videoTransferSize = videoMeta.fileSize;
          debugPrint('[DMX] Resolved video transfer size via HEAD probe: $videoTransferSize bytes');
        }
      } catch (e) {
        debugPrint('[DMX] Failed to resolve video transfer size: $e');
      }
    }

    // YouTube streams use multi-threaded mode as configured.
    final streamThreadCount = runtimeThreadCount;

    // Run video and audio in PARALLEL — each gets the full configured
    // thread count (streamThreadCount), not split between them.
    final downloadFuture = () async {
      final currentTask = _findTask(task.id);
      if (currentTask == null) return;
      task = currentTask;
      final maxRetries = _settingsProvider.autoRetryEnabled ? _settingsProvider.maxRetries : 0;
      int attempt = 0;

      // Shared byte/speed trackers — read and written by both the audio and
      // video progress callbacks, combined by pushCombinedProgress().
      int audioBytesSoFar = hasAudio && task.audioSize > 0
          ? (task.audioProgress * task.audioSize).round()
          : 0;
      int videoBytesSoFar = (task.downloadedBytes - audioBytesSoFar)
          .clamp(0, task.fileSize > 0 ? task.fileSize : task.downloadedBytes);
      double audioSpeedNow = 0.0;
      double videoSpeedNow = 0.0;

      void pushCombinedProgress({
        List<double>? chunksOverride,
        bool? supportsResumeOverride,
        List<Map<String, dynamic>>? torrentFilesOverride,
        String? fileNameOverride,
        String? localFilePathOverride,
        String? tempFilePathOverride,
        String? categoryOverride,
      }) {
        final index = _tasks.indexWhere((t) => t.id == task.id);
        if (index == -1) return;
        final base = _tasks[index];
        if (base.status != DownloadStatus.downloading) return;

        final audioContribution = hasAudio ? (base.audioSize > 0 ? base.audioSize : 0) : 0;
        final totalSize = videoTransferSize + audioContribution;
        final totalDownloaded = audioBytesSoFar + videoBytesSoFar;
        final combinedSpeed = audioSpeedNow + videoSpeedNow;

        int? calculatedEta;
        if (combinedSpeed > 0 && totalSize > totalDownloaded) {
          final remainingBytes = totalSize - totalDownloaded;
          final rawEta = (remainingBytes / combinedSpeed).round();
          if (rawEta > 0) {
            final prevEta = base.eta;
            if (prevEta != null && prevEta > 0) {
              calculatedEta = ((0.3 * rawEta) + (0.7 * prevEta)).round();
            } else {
              calculatedEta = rawEta;
            }
          }
        }

        final updated = base.copyWith(
          fileName: fileNameOverride ?? base.fileName,
          localFilePath: localFilePathOverride ?? base.localFilePath,
          tempFilePath: tempFilePathOverride ?? base.tempFilePath,
          category: categoryOverride ?? base.category,
          fileSize: totalSize,
          downloadedBytes: totalDownloaded,
          speed: combinedSpeed,
          eta: calculatedEta,
          clearEta: calculatedEta == null,
          chunks: chunksOverride ?? base.chunks,
          supportsResume: supportsResumeOverride ?? base.supportsResume,
          torrentFiles: torrentFilesOverride ?? base.torrentFiles,
        );

        final now = DateTime.now().millisecondsSinceEpoch;
        final lastUpdate = _lastProgressUpdateTimes[task.id] ?? 0;
        if (now - lastUpdate >= 250) {
          _lastProgressUpdateTimes[task.id] = now;
          _tasks[index] = updated;
          notifyListeners();

          if (_settingsProvider.notificationsEnabled) {
            final progressPercent = totalSize > 0
                ? ((totalDownloaded / totalSize) * 100).round().clamp(0, 100)
                : 0;
            _notificationService.showDownloadProgress(
              notificationId: notificationId,
              title: task.fileName,
              progressPercent: progressPercent,
              speed: updated.speedFormatted,
              eta: updated.etaFormatted,
              languageCode: _settingsProvider.languageCode,
              payload: task.id,
            );
          }
          BackgroundService.sendHeartbeat();
        } else {
          _tasks[index] = updated;
          _pendingProgressUpdates.add(task.id);
        }
      }

      while (true) {
        attempt++;

        // Fresh cancel tokens every attempt — see note #3 above. Mirror the
        // top-level cancelToken into both, same as before.
        final videoCancelToken = CancelToken();
        final audioCancelToken = CancelToken();
        cancelToken.whenCancel.then((_) {
          if (!videoCancelToken.isCancelled) videoCancelToken.cancel();
          if (!audioCancelToken.isCancelled) audioCancelToken.cancel();
        });

        try {
          Future<void> runAudio() async {
            if (!hasAudio) return;
            debugPrint('[DMX] Parallel download: starting audio stream.');
            await _downloadEngine.download(
              url: task.mergedAudioUrl!,
              tempFilePath: audioTempPath!,
              localFilePath: audioTempPath,
              knownFileSize: task.audioSize,
              supportsResume: true,
              cancelToken: audioCancelToken,
              cookies: cookieString,
              oauthToken: YoutubeService.oauthToken,
              onProgress: (progress) {
                final t = _findTask(task.id);
                if (t == null || t.status != DownloadStatus.downloading) return;

                audioBytesSoFar = progress.downloadedBytes;
                audioSpeedNow = progress.speed;

                final size = t.audioSize > 0 ? t.audioSize : progress.fileSize;
                final fraction =
                    size > 0 ? (progress.downloadedBytes / size).clamp(0.0, 1.0) : 0.0;
                final index = _tasks.indexWhere((x) => x.id == task.id);
                if (index != -1) {
                  _tasks[index] =
                      _tasks[index].copyWith(audioProgress: fraction, audioSize: size);
                }
                pushCombinedProgress();
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
              referer: isYoutube
                  ? (task.downloadPageUrl ?? 'https://www.youtube.com/')
                  : null,
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
            audioBytesSoFar = task.audioSize > 0 ? task.audioSize : audioLen;
            audioSpeedNow = 0.0;
            final idx = _tasks.indexWhere((x) => x.id == task.id);
            if (idx != -1) {
              _tasks[idx] = _tasks[idx].copyWith(audioProgress: 1.0);
            }
            pushCombinedProgress();
          }

          Future<void> runVideo() async {
            debugPrint('[DMX] Parallel download: starting video stream.');
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
              torrentId: torrentId,
              cookies: cookieString,
              oauthToken: YoutubeService.oauthToken,
              onProgress: (progress) {
                final current = _findTask(task.id);
                if (current == null || current.status != DownloadStatus.downloading) {
                  return;
                }

                videoBytesSoFar = progress.downloadedBytes;
                videoSpeedNow = progress.speed;

                // --- Throttling detection: unchanged from the original logic ---
                if (isYoutube &&
                    progress.downloadedBytes > 1024 * 1024 &&
                    progress.speed > 0 &&
                    progress.speed < 120 * 1024) {
                  final lowSpeedCount = (_ytLowSpeedCounts[task.id] ?? 0) + 1;
                  _ytLowSpeedCounts[task.id] = lowSpeedCount;

                  Logger.root.warning(
                    'Suspiciously low YouTube download speed (${(progress.speed / 1024).toStringAsFixed(1)} KB/s) for video ${task.id} (sample $lowSpeedCount). '
                    'The stream URL may be throttled due to n-parameter descrambling.',
                  );

                  if (lowSpeedCount >= 10 && !(_ytThrottlingRefreshing[task.id] ?? false)) {
                    _ytThrottlingRefreshing[task.id] = true;
                    _ytLowSpeedCounts[task.id] = 0;
                    Logger.root.info(
                      'Persistent YouTube throttling detected for ${task.id}. Attempting automatic stream refresh...',
                    );
                    Future.microtask(() async {
                      try {
                        final pageUrl = task.downloadPageUrl ?? task.url;
                        final fresh = await YoutubeService.getFreshStreams(pageUrl);
                        if (fresh != null && fresh['url'] != null) {
                          await updateTaskUrlAndResume(task.id, fresh['url']!,
                              newAudioUrl: fresh['audioUrl']);
                        }
                      } catch (err) {
                        debugPrint('Auto YouTube stream refresh failed: $err');
                      } finally {
                        _ytThrottlingRefreshing[task.id] = false;
                      }
                    });
                  }
                } else if (isYoutube && progress.speed >= 120 * 1024) {
                  _ytLowSpeedCounts[task.id] = 0;
                }
                // --- end throttling detection ---

                final speedQueue = _speedHistories[task.id] ??= Queue<double>();
                speedQueue.add(progress.speed);
                if (speedQueue.length > 20) speedQueue.removeFirst();

                final index = _tasks.indexWhere((t) => t.id == task.id);
                if (index == -1) return;
                final base = _tasks[index];

                final newFileName = isAutoName && progress.fileName != null
                    ? progress.fileName!
                    : base.fileName;
                final newLocalPath = newFileName != base.fileName
                    ? p.join(p.dirname(base.localFilePath), safeFileName(newFileName))
                    : base.localFilePath;
                final newTempPath = newFileName != base.fileName
                    ? p.join(p.dirname(base.tempFilePath), '${safeFileName(newFileName)}.dmxpart')
                    : base.tempFilePath;
                final newCategory =
                    newFileName != base.fileName && base.category == 'Other'
                        ? categoryFromFileName(newFileName)
                        : base.category;

                pushCombinedProgress(
                  chunksOverride: progress.chunks ??
                      _buildChunks(streamThreadCount, videoTransferSize, progress.downloadedBytes),
                  supportsResumeOverride: progress.supportsResume,
                  torrentFilesOverride: progress.torrentFiles,
                  fileNameOverride: newFileName,
                  localFilePathOverride: newLocalPath,
                  tempFilePathOverride: newTempPath,
                  categoryOverride: newCategory,
                );
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
          }

          await Future.wait([runVideo(), runAudio()]);
          return;
        } catch (error) {
          // Stop whichever side is still running before we retry or give up —
          // otherwise a background download from this failed attempt can
          // collide with the next attempt's writes to the same temp files.
          if (!videoCancelToken.isCancelled) videoCancelToken.cancel();
          if (!audioCancelToken.isCancelled) audioCancelToken.cancel();

          final isYoutubeDownload = (task.downloadPageUrl != null &&
                  YoutubeService.extractVideoId(task.downloadPageUrl!) != null) ||
              task.url.contains('.googlevideo.com/') ||
              task.youtubeQualityPreset != null;
          bool shouldRefreshYoutube = false;
          if (isYoutubeDownload) {
            final errStr = error.toString();
            final statusCode =
                error is DioException ? error.response?.statusCode : null;
            if (statusCode == 403 ||
                statusCode == 410 ||
                errStr.contains('403') ||
                errStr.contains('410') ||
                errStr.contains('Forbidden')) {
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

              final pageUrl =
                  (task.downloadPageUrl != null && task.downloadPageUrl!.isNotEmpty)
                      ? task.downloadPageUrl!
                      : task.url;

              Map<String, dynamic>? newUrlInfo;
              if (hasAudio) {
                final freshStreams = await YoutubeService.getFreshStreams(pageUrl);
                if (freshStreams != null && freshStreams['url'] != null) {
                  newUrlInfo = {
                    'url': freshStreams['url'],
                    'audioUrl': freshStreams['audioUrl'],
                  };
                }
              } else {
                newUrlInfo = await _refreshYoutubeStreamUrlSafe(pageUrl, task.url);
              }

              if (newUrlInfo != null && newUrlInfo['url'] != null) {
                final refreshedUrl = newUrlInfo['url'] as String;
                final refreshedAudioUrl = newUrlInfo['audioUrl'] as String?;

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

            await _setTask(currentForMerge.copyWith(
                statusMessage: DownloadStatusMessages.merging));

            // Re-derive the actual video file path from the CURRENT task state
            // (the engine may have auto-resolved a different filename)
            var actualVideoPath = currentForMerge.localFilePath;
            if (!await File(actualVideoPath).exists() && await File(currentForMerge.tempFilePath).exists()) {
              actualVideoPath = currentForMerge.tempFilePath;
            }
            final actualAudioPath = audioTempPath!;
            final videoExt = p.extension(actualVideoPath).isNotEmpty
                ? p.extension(actualVideoPath)
                : '.mp4';
            final mergedPath = '${p.withoutExtension(actualVideoPath)}$videoExt.merged$videoExt';

            debugPrint('[DMX] Phase 3 — Merge starting:');
            debugPrint('[DMX]   Video: $actualVideoPath');
            debugPrint('[DMX]   Audio: $actualAudioPath');
            debugPrint('[DMX]   Output: $mergedPath');

            // Verify both files exist BEFORE calling FFmpeg
            final videoFile = File(actualVideoPath);
            final audioFile = File(actualAudioPath);

            if (!await videoFile.exists()) {
              throw Exception('Video file missing after download: $actualVideoPath');
            }
            if (!await audioFile.exists()) {
              throw Exception('Audio file missing after download: $actualAudioPath');
            }

            final videoLen = await videoFile.length();
            final audioLen = await audioFile.length();
            debugPrint('[DMX]   Video size: $videoLen bytes');
            debugPrint('[DMX]   Audio size: $audioLen bytes');

            if (videoLen == 0) {
              throw Exception('Video file is empty: $actualVideoPath');
            }
            if (audioLen == 0) {
              throw Exception('Audio file is empty: $actualAudioPath');
            }

            // Use deleteInputsIfTemp: false — we handle cleanup ourselves
            final success = await FFmpegMuxService.mergeVideoAudio(
              actualVideoPath,
              actualAudioPath,
              mergedPath,
              deleteInputsIfTemp: false, // ← KEY FIX: don't let FFmpeg delete inputs
            );

            if (success) {
              final mergedFile = File(mergedPath);
              if (await mergedFile.exists()) {
                final mergedLen = await mergedFile.length();
                debugPrint('[DMX] Merge successful: $mergedPath ($mergedLen bytes)');

                // Now safely delete the original video
                try { await videoFile.delete(); } catch (_) {}
                // Rename merged → final path
                await mergedFile.rename(actualVideoPath);
                debugPrint('[DMX] Original video replaced with merged file');
              } else {
                throw Exception('Merged output file not found after FFmpeg success');
              }
              // Clean up audio temp file
              try { await audioFile.delete(); } catch (_) {}
            } else {
              // Merge failed — clean up audio but KEEP the video-only file
              try { await audioFile.delete(); } catch (_) {}
              throw Exception(
                  'FFmpeg merge failed. The video-only file is saved at: $actualVideoPath');
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

          final finalFileSize = current.fileSize > 0
              ? current.fileSize
              : (current.downloadedBytes > 0 ? current.downloadedBytes : 0);
          await _setTask(
            current.copyWith(
              clearError: true,
              clearStatusMessage: true,
              status: DownloadStatus.completed,
              fileSize: finalFileSize,
              downloadedBytes:
                  (current.isTorrent || hasAudio) && finalFileSize > 0
                  ? finalFileSize
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
            if (task.isAppUpdate) {
              _notificationService.showDownloadComplete(
                notificationId: notificationId,
                title: 'Update ready',
                body: 'App update ${task.fileName} downloaded. Tap to install.',
                playSound: _settingsProvider.soundNotification,
                payload: task.id,
                actions: const [
                  AndroidNotificationAction(
                    'install_apk',
                    'Install',
                    showsUserInterface: true,
                  ),
                ],
              );
            } else {
              _notificationService.showDownloadComplete(
                notificationId: notificationId,
                title: task.fileName,
                playSound: _settingsProvider.soundNotification,
              );
            }
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
    _activeFutures[task.id] = downloadFuture;
  }

  Future<void> _setTask(DownloadTask updated) async {
    final index = _tasks.indexWhere((task) => task.id == updated.id);
    if (index == -1) return;

    final prev = _tasks[index];
    _tasks[index] = updated;
    // Only invalidate the filter/sort cache when a "structural" field changes
    // (status, category, name, URL, or fileSize). Progress-only updates (speed,
    // downloadedBytes, chunks, eta) must NOT set filteredTasksDirty to true,
    // otherwise the filtered list would be recomputed on every tick, wasting CPU
    // and causing unnecessary widget rebuilds.
    if (prev.status != updated.status || prev.category != updated.category ||
        prev.fileName != updated.fileName || prev.url != updated.url ||
        prev.fileSize != updated.fileSize) {
      filteredTasksDirty = true;
    }

    final previousSave = _dbSaveQueues[updated.id] ?? Future.value();
    final completer = Completer<void>();
    _dbSaveQueues[updated.id] = completer.future;

    updateActualTorrentUploadLimit();

    await previousSave;
    try {
      await _databaseService.saveTask(updated);
      // Notify AFTER successful DB write to keep UI and persistence in sync
      notifyListeners();
    } catch (e) {
      debugPrint('Error saving task to database: $e');
      // Still notify so UI doesn't freeze, but log the inconsistency
      notifyListeners();
    } finally {
      completer.complete();
      if (_dbSaveQueues[updated.id] == completer.future) {
        _dbSaveQueues.remove(updated.id);
      }
    }
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

  /// Build per-thread chunk progress fallback returning unified overall progress.
  List<double> _buildChunks(
    int threadCount,
    int fileSize,
    int downloadedBytes,
  ) {
    if (fileSize <= 0 || threadCount <= 0) {
      return [0.0];
    }
    final overallProgress = (downloadedBytes / fileSize).clamp(0.0, 1.0);
    return [overallProgress];
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
      final statusCode = error.response?.statusCode;
      if (statusCode != null) {
        return switch (statusCode) {
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
            'HTTP Error $statusCode: ${error.message ?? "Server returned invalid response."}',
        };
      }
      return 'Dio Error: ${error.message ?? error.type.name}';
    }
    return 'Error: ${error.toString()}';
  }

  bool _isRetryableError(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('merge') || msg.contains('ffmpeg') || msg.contains('missing') || msg.contains('not found')) {
      return false;
    }
    if (error is DioException) {
      if (error.type == DioExceptionType.cancel) {
        return false;
      }
      final statusCode = error.response?.statusCode;
      if (statusCode != null) {
        // Do not retry client errors (400 Bad Request, 401 Unauthorized, 403 Forbidden, 404 Not Found, 410 Gone, 416 Range Not Satisfiable)
        if (statusCode == 400 ||
            statusCode == 401 ||
            statusCode == 403 ||
            statusCode == 404 ||
            statusCode == 410 ||
            statusCode == 416) {
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
          errorMessage: DownloadStatusMessages.waitingNetwork,
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
      _tasksPausedDueToNetwork.add(task.id); // Track for proper resume
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
          errorMessage: DownloadStatusMessages.waitingWifi,
        ),
      );
    }
  }

  Future<void> _resumeWaitingForWifi({bool skipPump = false}) async {
    final waiting = _tasks.where(
      (task) =>
          task.status == DownloadStatus.paused &&
          task.errorMessage == DownloadStatusMessages.waitingWifi,
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

  DateTime? _lastUpdateCheckTime;

  void _startSchedulingTimer() {
    _schedulingTimer?.cancel();
    _schedulingTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      _checkScheduledDownloads();
      _checkPeriodicAppUpdate();
      if (downloadingTasksCount > 0) {
        BackgroundService.sendHeartbeat();
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
      debugPrint('[DownloadProvider] Background update check error: $e');
    }
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
        if (tasksToSave.isNotEmpty) {
          _databaseService.saveTasks(tasksToSave).catchError((e) {
            debugPrint('Batch DB save failed: $e');
          });
        }

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

    final targetThreadCount = threadCount;
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
        clearError: true,
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
      // updateTaskUrl already handles resume internally for downloading tasks
      await updateTaskUrl(id, newUrl, newAudioUrl: newAudioUrl, isRefresh: true);
      final updated = _findTask(id);
      // Only resume if the task was NOT already downloading
      if (updated != null &&
          updated.status != DownloadStatus.downloading &&
          updated.status != DownloadStatus.queued) {
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
    _cookieCache.clear();
    _speedHistories.clear();
    _lastProgressUpdateTimes.clear();
    _lastDbSaveTimes.clear();
    _lastDbSaveBytes.clear();
    _pendingProgressUpdates.clear();
    _ytLowSpeedCounts.clear();
    _ytThrottlingRefreshing.clear();
    _torrentIds.clear();
    _notificationIds.clear();
    _retryCounts.clear();
    // Drain pending DB saves before closing the engine
    if (_dbSaveQueues.isNotEmpty) {
      Future.wait(_dbSaveQueues.values).then((_) {
        _downloadEngine.close();
      });
    } else {
      _downloadEngine.close();
    }
    _dbSaveQueues.clear();
    super.dispose();
  }
}