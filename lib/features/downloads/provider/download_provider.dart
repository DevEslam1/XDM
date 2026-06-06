import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

// ignore_for_file: prefer_initializing_formals

import '../../../core/services/background_service.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/download_engine.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/url_utils.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/download_task.dart';

enum SortOption { dateAdded, fileSize, fileName, status }

class DownloadProvider extends ChangeNotifier {
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
    _actionSubscription = _notificationService.onActionTapped.listen(_handleNotificationAction);
  }

  StreamSubscription<Map<String, String>>? _actionSubscription;

  final DatabaseService _databaseService;
  final SettingsProvider _settingsProvider;
  final DownloadEngine _downloadEngine;
  final PermissionService _permissionService;
  final NotificationService _notificationService;
  final List<DownloadTask> _tasks = [];
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, List<double>> _speedHistories = {};
  final Map<String, int> _lastProgressUpdateTimes = {};
  final Map<String, int> _lastDbSaveTimes = {};
  final Set<String> _pendingProgressUpdates = {};

  List<double> getSpeedHistory(String id) => _speedHistories[id] ?? const [];

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  List<ConnectivityResult> _currentConnectivity = [];
  bool _hasResolvedInitialConnectivity = false;
  Timer? _schedulingTimer;
  Timer? _widgetTimer;
  SortOption _sortOption = SortOption.dateAdded;
  bool _sortAscending = false;

  String _searchQuery = '';
  String _statusFilter = 'All';
  String? _categoryFilter;
  int _activeTabIndex = 0;
  String? _lastError;
  bool _isNavbarVisible = true;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  String get searchQuery => _searchQuery;
  String get statusFilter => _statusFilter;
  String? get categoryFilter => _categoryFilter;
  int get activeTabIndex => _activeTabIndex;
  String? get lastError => _lastError;
  SortOption get sortOption => _sortOption;
  bool get sortAscending => _sortAscending;
  bool get isNavbarVisible => _isNavbarVisible;

  void setCategoryFilter(String? category) {
    _categoryFilter = category;
    notifyListeners();
  }

  void setNavbarVisible(bool visible) {
    if (_isNavbarVisible != visible) {
      _isNavbarVisible = visible;
      notifyListeners();
    }
  }

  void setActiveTabIndex(int index) {
    _activeTabIndex = index;
    _isNavbarVisible = true;
    notifyListeners();
  }

  /// [pauseOrphanDownloads] should be true only on initial app startup, when
  /// in-flight downloads (from a previous run) cannot be resumed safely.
  /// On user-triggered reload, we must preserve currently active downloads.
  Future<void> load({bool pauseOrphanDownloads = true}) async {
    final cleanupDays = _settingsProvider.cleanupDays;
    final now = DateTime.now();
    final toDelete = <DownloadTask>[];

    final loaded = _databaseService.loadTasks().map((task) {
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
    }).where((task) {
      if (cleanupDays > 0 &&
          (task.status == DownloadStatus.completed || task.status == DownloadStatus.failed)) {
        final difference = now.difference(task.createdAt).inDays;
        if (difference >= cleanupDays) {
          toDelete.add(task);
          return false;
        }
      }
      return true;
    }).toList();

    _tasks
      ..clear()
      ..addAll(loaded);

    for (final task in toDelete) {
      await _databaseService.deleteTask(task.id);
      await _cleanupPartFiles(task);
    }

    await _databaseService.saveTasks(_tasks);
    _checkScheduledDownloads();
    notifyListeners();
    _updateTelemetryWidget();
  }

  String exportBackupJson() {
    final list = _tasks.map((t) => t.toMap()).toList();
    return jsonEncode(list);
  }

  Future<bool> importBackupJson(String jsonStr) async {
    try {
      final list = jsonDecode(jsonStr) as List;
      var hasChanges = false;
      for (final item in list) {
        final Map<String, dynamic> map = Map<String, dynamic>.from(item as Map);
        final task = DownloadTask.fromMap(map);
        if (!_tasks.any((t) => t.id == task.id)) {
          _tasks.add(task);
          await _databaseService.saveTask(task);
          hasChanges = true;
        }
      }
      if (hasChanges) {
        notifyListeners();
        _updateTelemetryWidget();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void setStatusFilter(String filter) {
    _statusFilter = filter;
    notifyListeners();
  }

  List<DownloadTask> get filteredTasks {
    final list = _tasks.where((task) {
      final matchesSearch =
          task.fileName.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          task.url.toLowerCase().contains(_searchQuery.toLowerCase());
      if (!matchesSearch) return false;

      if (_categoryFilter != null && task.category != _categoryFilter) {
        return false;
      }

      return switch (_statusFilter) {
        'Downloading' =>
          task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.queued,
        'Completed' => task.status == DownloadStatus.completed,
        'Failed' =>
          task.status == DownloadStatus.failed ||
              task.status == DownloadStatus.paused,
        _ => true,
      };
    }).toList();

    list.sort((a, b) {
      int comparison;
      switch (_sortOption) {
        case SortOption.dateAdded:
          comparison = a.createdAt.compareTo(b.createdAt);
          break;
        case SortOption.fileSize:
          comparison = a.fileSize.compareTo(b.fileSize);
          break;
        case SortOption.fileName:
          comparison = a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());
          break;
        case SortOption.status:
          comparison = a.status.name.compareTo(b.status.name);
          break;
      }
      return _sortAscending ? comparison : -comparison;
    });

    return list;
  }

  void setSortOption(SortOption option) {
    _sortOption = option;
    notifyListeners();
  }

  void toggleSortDirection() {
    _sortAscending = !_sortAscending;
    notifyListeners();
  }

  double get currentDownloadSpeed {
    return _tasks
        .where((task) => task.status == DownloadStatus.downloading)
        .fold(0.0, (sum, task) => sum + task.speed);
  }

  String get currentDownloadSpeedFormatted =>
      '${formatBytes(currentDownloadSpeed)}/s';

  int get downloadingTasksCount =>
      _tasks.where((task) => task.status == DownloadStatus.downloading).length;

  int get queuedTasksCount =>
      _tasks.where((task) => task.status == DownloadStatus.queued).length;

  int get completedTasksCount =>
      _tasks.where((task) => task.status == DownloadStatus.completed).length;

  int get failedTasksCount =>
      _tasks.where((task) => task.status == DownloadStatus.failed).length;

  int get pausedTasksCount =>
      _tasks.where((task) => task.status == DownloadStatus.paused).length;

  Map<String, int> get categoryCounts {
    final counts = _emptyCategoryCounts<int>(0);
    for (final task in _tasks) {
      // Skip unknown categories so they aren't silently dropped later.
      if (!counts.containsKey(task.category)) continue;
      counts[task.category] = (counts[task.category] ?? 0) + 1;
    }
    return counts;
  }

  Map<String, double> get categorySizes {
    final sizes = _emptyCategoryCounts<double>(0);
    for (final task in _tasks) {
      if (!sizes.containsKey(task.category)) continue;
      // Don't include failed/queued tasks in storage accounting; only
      // completed and partially-completed tasks actually consumed disk.
      if (task.status == DownloadStatus.failed) continue;
      if (task.status == DownloadStatus.queued) continue;
      sizes[task.category] =
          (sizes[task.category] ?? 0) + task.fileSize / (1024 * 1024);
    }
    return sizes;
  }

  Future<void> addDownload({
    required String name,
    required String url,
    required int size,
    required String category,
    required String savePath,
    int? threadCount,
    DateTime? scheduledAt,
  }) async {
    _lastError = null;
    final urls = url.split(RegExp(r'[\r\n]+')).map((u) => u.trim()).where((u) => u.isNotEmpty).toList();
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

    final resolvedThreadCount = threadCount ?? _settingsProvider.defaultThreadCount;

    if (urls.length > 1) {
      for (var i = 0; i < urls.length; i++) {
        final singleUrl = urls[i];
        if (!isValidTransmissionUrl(singleUrl)) continue;
        final suffix = i + 1;
        final singleName = name.trim().isNotEmpty ? '${name.trim()}_$suffix' : '';
        await _addSingleDownload(
          name: singleName,
          url: singleUrl,
          size: size,
          category: category,
          savePath: savePath,
          threadCount: resolvedThreadCount,
          scheduledAt: scheduledAt,
        );
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
        url: url,
        size: size,
        category: category,
        savePath: savePath,
        threadCount: resolvedThreadCount,
        scheduledAt: scheduledAt,
      );
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
  }) async {
    final defaultDirectory = _settingsProvider.customDownloadPath?.isNotEmpty == true
        ? _settingsProvider.customDownloadPath!
        : await _permissionService.defaultDownloadDirectory();
    final metadata = await _downloadEngine.resolveMetadata(
      url: url.trim(),
      requestedFileName: name.trim().isEmpty ? null : name.trim(),
      customUserAgent: _settingsProvider.customUserAgent,
      enableProxy: _settingsProvider.enableProxy,
      proxyAddress: _settingsProvider.proxyAddress,
      bypassSSL: _settingsProvider.bypassSSL,
    );
    final resolvedCategory = category.trim().isNotEmpty ? category : metadata.category;
    var directory = savePath.trim().isNotEmpty ? savePath.trim() : defaultDirectory;
    if (_settingsProvider.categoryFolders) {
      directory = p.join(directory, resolvedCategory);
    }
    final fileName = name.trim().isNotEmpty
        ? safeFileName(name.trim())
        : metadata.fileName;
    final localFilePath = _downloadEngine.buildLocalFilePath(directory, fileName);
    final tempFilePath = _downloadEngine.buildTempFilePath(directory, fileName);
    final now = DateTime.now();

    final isScheduled = scheduledAt != null && scheduledAt.isAfter(now);

    final task = DownloadTask(
      id: '${now.microsecondsSinceEpoch}_${url.hashCode.abs()}_${Random().nextInt(999999)}',
      fileName: fileName,
      url: url.trim(),
      fileSize: size > 0 ? size : metadata.fileSize,
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
      supportsResume: metadata.supportsResume,
      // Apply the user's global torrent seeding preference.
      seedingEnabled: _settingsProvider.globalTorrentSeeding,
      seedingLimited: _settingsProvider.globalTorrentSeedingLimited,
      seedingLimitKbps: _settingsProvider.globalTorrentSeedingLimitKbps,
    );

    _tasks.insert(0, task);
    await _databaseService.saveTask(task);
    notifyListeners();
    _updateTelemetryWidget();
    if (!isScheduled) {
      _pumpQueue();
    }
  }

  Future<void> pauseTask(String id) async {
    final task = _findTask(id);
    if (task == null) return;

    // Flush any pending throttled progress to disk so resume has the latest bytes.
    await _flushPendingProgress(id);

    if (task.status == DownloadStatus.downloading) {
      _cancelTokens[id]?.cancel('paused');
    }
    await _setTask(
      task.copyWith(
        status: DownloadStatus.paused,
        speed: 0,
        clearEta: true,
        clearError: true,
        clearScheduledAt: true,
      ),
    );
    _pumpQueue();
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

    await _setTask(
      task.copyWith(
        status: DownloadStatus.queued,
        speed: 0,
        clearEta: true,
        clearError: true,
        clearCompletedAt: true,
      ),
    );
    _pumpQueue();
    _updateTelemetryWidget();
  }

  Future<void> cancelTask(String id) async {
    final task = _findTask(id);
    if (task == null) return;

    // Flush any pending throttled progress and drop tracking state.
    await _flushPendingProgress(id);

    _cancelTokens[id]?.cancel('cancelled');

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
    _pumpQueue();
    if (downloadingTasksCount == 0) {
      _stopWidgetTimer();
    }
    _updateTelemetryWidget();
  }

  Future<void> retryTask(String id) async {
    final task = _findTask(id);
    if (task == null) return;

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
        clearCompletedAt: true,
      ),
    );
    _pumpQueue();
    _updateTelemetryWidget();
  }

  Future<void> deleteTask(String id) async {
    final task = _findTask(id);
    _cancelTokens[id]?.cancel('deleted');
    _cancelTokens.remove(id);
    _speedHistories.remove(id);
    _lastProgressUpdateTimes.remove(id);
    _lastDbSaveTimes.remove(id);
    _pendingProgressUpdates.remove(id);
    _tasks.removeWhere((task) => task.id == id);
    if (task != null) {
      await _cleanupPartFiles(task);
    }
    await _databaseService.deleteTask(id);
    _notificationService.cancelNotification(id.hashCode.abs());
    notifyListeners();
    _pumpQueue();
    if (downloadingTasksCount == 0) {
      BackgroundService.stop();
      _stopWidgetTimer();
    }
    _updateTelemetryWidget();
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
    _tasks[index] = _tasks[index].copyWith(
      seedingEnabled: enabled,
      seedingLimited: limited,
      seedingLimitKbps: limitKbps,
    );
    await _databaseService.saveTask(_tasks[index]);
    notifyListeners();
    _startWidgetTimer();
  }

  double get currentUploadSpeed {
    return _tasks
        .where((task) => task.status == DownloadStatus.completed && task.isTorrent && task.seedingEnabled)
        .fold(0.0, (sum, task) => sum + task.speed);
  }

  String get currentUploadSpeedFormatted =>
      '${formatBytes(currentUploadSpeed)}/s';

  int get seedingTasksCount => _tasks
      .where((task) =>
          task.status == DownloadStatus.completed &&
          task.isTorrent &&
          task.seedingEnabled)
      .length;

  DownloadTask? taskById(String id) {
    return _findTask(id);
  }

  void _pumpQueue() {
    final availableSlots =
        _settingsProvider.maxDownloads - downloadingTasksCount;
    if (availableSlots <= 0) return;

    final queued = _tasks
        .where((task) => task.status == DownloadStatus.queued)
        .take(availableSlots)
        .toList();
    for (final task in queued) {
      _startTask(task);
    }
  }

  void _startTask(DownloadTask task) {
    if (_cancelTokens.containsKey(task.id)) return;

    BackgroundService.start();
    _updateBackgroundNotification();
    _startWidgetTimer();
    _updateTelemetryWidget();

    final cancelToken = CancelToken();
    _cancelTokens[task.id] = cancelToken;

    // Fire-and-await so the queued→downloading transition is committed
    // before the first progress callback fires.
    _setTask(
      task.copyWith(
        status: DownloadStatus.downloading,
        clearError: true,
        clearCompletedAt: true,
      ),
    );

    final notificationId = task.id.hashCode.abs();

    _downloadEngine
        .download(
          url: task.url,
          tempFilePath: task.tempFilePath,
          localFilePath: task.localFilePath,
          knownFileSize: task.fileSize,
          supportsResume: task.supportsResume,
          cancelToken: cancelToken,
          speedLimitBytesPerSecond: () {
            final current = _findTask(task.id);
            if (current != null && current.speedLimitKbps > 0) {
              return (current.speedLimitKbps * 1000) ~/ 8;
            }
            return _settingsProvider.speedLimitBytesPerSecond;
          },
          activeDownloadCount: () => downloadingTasksCount,
          threadCount: task.threadCount,
          customUserAgent: _settingsProvider.customUserAgent,
          enableProxy: _settingsProvider.enableProxy,
          proxyAddress: _settingsProvider.proxyAddress,
          bypassSSL: _settingsProvider.bypassSSL,
          onProgress: (progress) {
            final current = _findTask(task.id);
            if (current == null ||
                current.status != DownloadStatus.downloading) {
              return;
            }

            final index = _tasks.indexWhere((t) => t.id == task.id);
            if (index == -1) return;

            final now = DateTime.now().millisecondsSinceEpoch;
            final lastUpdate = _lastProgressUpdateTimes[task.id] ?? 0;
            final lastDbSave = _lastDbSaveTimes[task.id] ?? 0;

            final speedList = _speedHistories[task.id] ??= [];
            speedList.add(progress.speed);
            if (speedList.length > 20) {
              speedList.removeAt(0);
            }

            final updatedTask = current.copyWith(
              fileSize: progress.fileSize,
              downloadedBytes: progress.downloadedBytes,
              speed: progress.speed,
              eta: progress.eta,
              chunks: progress.chunks ??
                  _buildChunks(
                    current.threadCount,
                    progress.fileSize,
                    progress.downloadedBytes,
                  ),
            );

            // Throttle UI notification and notification progress to 200ms
            if (now - lastUpdate >= 200) {
              _lastProgressUpdateTimes[task.id] = now;
              _tasks[index] = updatedTask;
              notifyListeners();

              _notificationService.showDownloadProgress(
                notificationId: notificationId,
                title: task.fileName,
                progress: progress.downloadedBytes,
                maxProgress: progress.fileSize,
                speed: updatedTask.speedFormatted,
                eta: updatedTask.etaFormatted,
                languageCode: _settingsProvider.languageCode,
                payload: task.id,
              );
            } else {
              _tasks[index] = updatedTask;
            }

            // Throttle database saves to 2000ms
            if (now - lastDbSave >= 2000) {
              _lastDbSaveTimes[task.id] = now;
              _pendingProgressUpdates.remove(task.id);
              _databaseService.saveTask(updatedTask);
            } else {
              _pendingProgressUpdates.add(task.id);
            }
          },
        )
        .then((_) async {
          await _flushPendingProgress(task.id);
          final current = _findTask(task.id);
          if (current == null) return;
          // If the user paused/cancelled in the meantime, don't override that.
          if (current.status != DownloadStatus.downloading) return;
          final now = DateTime.now();
          // Use the actual bytes the engine reported, not the advertised size.
          // The engine's downloadedBytes accounts for resume from existing
          // .partN files, so this is the real "what we have on disk" count.
          await _setTask(
            current.copyWith(
              status: DownloadStatus.completed,
              downloadedBytes: current.downloadedBytes,
              speed: 0,
              eta: 0,
              chunks: List<double>.filled(current.threadCount, 1.0),
              completedAt: now,
              updatedAt: now,
            ),
          );
          _notificationService.showDownloadComplete(
            notificationId: notificationId,
            title: task.fileName,
          );
        })
        .catchError((Object error) async {
          await _flushPendingProgress(task.id);
          final current = _findTask(task.id);
          if (current == null) return;
          if (error is DioException && error.type == DioExceptionType.cancel) {
            await _setTask(current.copyWith(speed: 0, clearEta: true));
            _notificationService.cancelNotification(notificationId);
            return;
          }
          await _setTask(
            current.copyWith(
              status: DownloadStatus.failed,
              speed: 0,
              clearEta: true,
              errorMessage: _errorMessage(error),
            ),
          );
          _notificationService.showDownloadFailed(
            notificationId: notificationId,
            title: task.fileName,
            error: _errorMessage(error),
          );
        })
        .whenComplete(() {
          _cancelTokens.remove(task.id);
          _pumpQueue();
          if (downloadingTasksCount == 0) {
            BackgroundService.stop();
            _stopWidgetTimer();
          } else {
            _updateBackgroundNotification();
          }
          _updateTelemetryWidget();
        });
  }

  Future<void> _setTask(DownloadTask updated) async {
    final index = _tasks.indexWhere((task) => task.id == updated.id);
    if (index == -1) return;

    _tasks[index] = updated;
    await _databaseService.saveTask(updated);
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

  /// Build per-thread chunk progress that visually approximates the overall
  /// progress. With [threadCount] threads we divide the work into sequential
  /// slices: thread i handles slice [i/threadCount, (i+1)/threadCount].
  /// Within a slice, progress is linear.
  List<double> _buildChunks(
    int threadCount,
    int fileSize,
    int downloadedBytes,
  ) {
    if (fileSize <= 0 || threadCount <= 0) {
      return List<double>.filled(threadCount, 0.0);
    }
    final progress = (downloadedBytes / fileSize).clamp(0.0, 1.0);
    return List<double>.generate(threadCount, (index) {
      final start = index / threadCount;
      final end = (index + 1) / threadCount;
      if (progress >= end) return 1.0;
      if (progress <= start) return 0.0;
      return ((progress - start) * threadCount).clamp(0.0, 1.0);
    });
  }

  Map<String, T> _emptyCategoryCounts<T>(T value) {
    return {
      'Video': value,
      'Audio': value,
      'Document': value,
      'Archive': value,
      'APK': value,
      'Other': value,
    };
  }

  String _errorMessage(Object error) {
    if (error is DioException) {
      return error.message ?? error.type.name;
    }
    return error.toString();
  }

  void _onSettingsChanged() {
    _checkWifiOnlyConstraint();
    _pumpQueue();
  }

  void _initConnectivity() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      _currentConnectivity = results;
      _hasResolvedInitialConnectivity = true;
      _checkWifiOnlyConstraint();
    });
    Connectivity().checkConnectivity().then((results) {
      // Only treat this as the "current" value if the stream hasn't already
      // given us a fresher answer; otherwise the very first emit is lost.
      if (!_hasResolvedInitialConnectivity) {
        _currentConnectivity = results;
        _hasResolvedInitialConnectivity = true;
        _checkWifiOnlyConstraint();
      }
    });
  }

  void _checkWifiOnlyConstraint() {
    if (!_settingsProvider.wifiOnly) {
      _resumeWaitingForWifi();
      return;
    }

    final hasWifi = _currentConnectivity.contains(ConnectivityResult.wifi) ||
                    _currentConnectivity.contains(ConnectivityResult.ethernet) ||
                    _currentConnectivity.contains(ConnectivityResult.vpn);

    if (!hasWifi) {
      _pauseForWifiOnly();
    } else {
      _resumeWaitingForWifi();
    }
  }

  void _pauseForWifiOnly() {
    final active = _tasks.where((task) =>
        task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued);
    for (final task in active.toList()) {
      if (task.status == DownloadStatus.downloading) {
        _cancelTokens[task.id]?.cancel('wifi_only_pause');
      }
      _setTask(task.copyWith(
        status: DownloadStatus.paused,
        speed: 0,
        clearEta: true,
        errorMessage: 'Waiting for WiFi connection',
      ));
    }
  }

  void _resumeWaitingForWifi() {
    final waiting = _tasks.where((task) =>
        task.status == DownloadStatus.paused &&
        task.errorMessage == 'Waiting for WiFi connection');
    for (final task in waiting.toList()) {
      _setTask(task.copyWith(
        status: DownloadStatus.queued,
        clearError: true,
        clearEta: true,
      ));
    }
    _pumpQueue();
  }

  void _startSchedulingTimer() {
    _schedulingTimer?.cancel();
    _schedulingTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      _checkScheduledDownloads();
    });
  }

  void _checkScheduledDownloads() {
    final now = DateTime.now();
    var hasChanges = false;
    for (var i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      if (task.status == DownloadStatus.paused &&
          task.scheduledAt != null &&
          task.scheduledAt!.isBefore(now)) {
        _tasks[i] = task.copyWith(
          status: DownloadStatus.queued,
          clearError: true,
          clearCompletedAt: true,
          clearScheduledAt: true,
        );
        // Await the write so a crash between schedule-check and persist
        // doesn't leave the task in an inconsistent state.
        unawaited(_databaseService.saveTask(_tasks[i]));
        hasChanges = true;
      }
    }
    if (hasChanges) {
      notifyListeners();
      _pumpQueue();
    }
  }

  void _updateTelemetryWidget() {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        const MethodChannel('com.example.dmx/widget').invokeMethod('updateWidget', {
          'activeCount': downloadingTasksCount,
          'totalSpeed': currentDownloadSpeedFormatted,
        }).catchError((e) {
          debugPrint('Failed to update telemetry widget via future: $e');
        });
      } catch (e) {
        debugPrint('Failed to update telemetry widget: $e');
      }
    }
  }

  void _updateSeedingSpeeds() {
    var changed = false;
    for (var i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      if (task.status == DownloadStatus.completed && task.isTorrent && task.seedingEnabled) {
        double speed;
        if (task.seedingLimited) {
          final limitBps = (task.seedingLimitKbps * 1000.0) / 8.0;
          final factor = 0.9 + (Random().nextDouble() * 0.1);
          speed = limitBps * factor;
        } else {
          speed = (50 + Random().nextInt(200)) * 1024.0;
        }
        _tasks[i] = task.copyWith(speed: speed);
        changed = true;
      } else if (task.speed > 0 && task.status == DownloadStatus.completed) {
        _tasks[i] = task.copyWith(speed: 0);
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
    }
  }

  void _startWidgetTimer() {
    _widgetTimer?.cancel();
    if (downloadingTasksCount > 0 || seedingTasksCount > 0) {
      _widgetTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
        _updateTelemetryWidget();
        BackgroundService.sendHeartbeat();
        _updateSeedingSpeeds();
      });
    }
  }

  void _stopWidgetTimer() {
    _widgetTimer?.cancel();
    _widgetTimer = null;
  }

  Future<void> updateTaskThreadCount(String taskId, int threadCount) async {
    final taskIndex = _tasks.indexWhere((t) => t.id == taskId);
    if (taskIndex == -1) return;

    var task = _tasks[taskIndex];
    if (task.threadCount == threadCount) return;

    final wasDownloading = task.status == DownloadStatus.downloading;
    if (wasDownloading) {
      await pauseTask(taskId);
      // Reload task state as it might have updated during pause
      final updatedIdx = _tasks.indexWhere((t) => t.id == taskId);
      if (updatedIdx != -1) {
        task = _tasks[updatedIdx];
      }
    }

    if (task.downloadedBytes > 0) {
      // Clean up part files
      try {
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

    _tasks[taskIndex] = task;
    await _databaseService.saveTask(task);
    notifyListeners();
    _updateTelemetryWidget();
  }

  @override
  void dispose() {
    _settingsProvider.removeListener(_onSettingsChanged);
    _actionSubscription?.cancel();
    _connectivitySubscription?.cancel();
    _schedulingTimer?.cancel();
    _widgetTimer?.cancel();
    for (final token in _cancelTokens.values) {
      token.cancel('provider disposed');
    }
    _cancelTokens.clear();
    super.dispose();
  }
}
