import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../../../core/services/torrent_service.dart';
import '../../../core/services/youtube_service.dart';

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
import '../../browser/services/ad_blocker.dart';

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
  final Map<String, List<double>> _speedHistories = {};
  final Map<String, int> _lastProgressUpdateTimes = {};
  final Map<String, int> _lastDbSaveTimes = {};
  final Set<String> _pendingProgressUpdates = {};
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
  bool _queueProcessing = false;

  bool _batchMode = false;
  bool _needsNotify = false;

  @override
  void notifyListeners() {
    if (_batchMode) {
      _needsNotify = true;
    } else {
      super.notifyListeners();
    }
  }

  void _startBatch() {
    _batchMode = true;
    _needsNotify = false;
  }

  void _endBatch() {
    _batchMode = false;
    if (_needsNotify) {
      _needsNotify = false;
      super.notifyListeners();
    }
  }
  SortOption _sortOption = SortOption.dateAdded;
  bool _sortAscending = false;

  String _searchQuery = '';
  String _statusFilter = 'All';
  final Set<String> _categoryFilters = {};
  Set<String> get categoryFilters => _categoryFilters;
  String? get categoryFilter =>
      _categoryFilters.isEmpty ? null : _categoryFilters.first;
  int _activeTabIndex = 0;
  String? _lastError;
  bool _isNavbarVisible = true;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  String get searchQuery => _searchQuery;
  String get statusFilter => _statusFilter;
  int get activeTabIndex => _activeTabIndex;
  String? get lastError => _lastError;
  SortOption get sortOption => _sortOption;
  bool get sortAscending => _sortAscending;
  bool get isNavbarVisible => _isNavbarVisible;

  String? _browserUrlToLoad;
  String? get browserUrlToLoad => _browserUrlToLoad;

  void openUrlInBrowser(String url) {
    _browserUrlToLoad = url;
    setActiveTabIndex(1);
  }

  void clearBrowserUrlToLoad() {
    _browserUrlToLoad = null;
  }

  void setCategoryFilter(String? category) {
    _categoryFilters.clear();
    if (category != null) {
      _categoryFilters.add(category);
    }
    notifyListeners();
  }

  void toggleCategoryFilter(String category) {
    if (_categoryFilters.contains(category)) {
      _categoryFilters.remove(category);
    } else {
      _categoryFilters.add(category);
    }
    _filteredTasksDirty = true;
    notifyListeners();
  }

  void clearCategoryFilters() {
    _categoryFilters.clear();
    notifyListeners();
  }

  void setNavbarVisible(bool visible) {
    if (_isNavbarVisible != visible) {
      _isNavbarVisible = visible;
      notifyListeners();
    }
  }

  void setActiveTabIndex(int index) {
    if (_activeTabIndex == index) return;
    _activeTabIndex = index;
    _isNavbarVisible = true;
    notifyListeners();
    if (index == 1 && _settingsProvider.adBlockerEnabled) {
      AdBlocker.autoUpdateHosts();
    }
  }

  /// [pauseOrphanDownloads] should be true only on initial app startup, when
  /// in-flight downloads (from a previous run) cannot be resumed safely.
  /// On user-triggered reload, we must preserve currently active downloads.
  Future<void> load({bool pauseOrphanDownloads = true}) async {
    final cleanupDays = _settingsProvider.cleanupDays;
    final now = DateTime.now();
    final toDelete = <DownloadTask>[];

    final loaded = _databaseService
        .loadTasks()
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
            final difference = now.difference(task.completedAt ?? task.createdAt).inDays;
            if (difference >= cleanupDays) {
              toDelete.add(task);
              return false;
            }
          }
          return true;
        })
        .toList();

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
        _startSeedingTorrent(task);
      }
    }

    _updateActualTorrentUploadLimit();
    _checkScheduledDownloads();
    _startWidgetTimer();
    notifyListeners();
    _updateTelemetryWidget();
  }

  List<int> _xorCipher(List<int> data, List<int> key) {
    final List<int> result = List<int>.filled(data.length, 0);
    for (int i = 0; i < data.length; i++) {
      result[i] = data[i] ^ key[i % key.length];
    }
    return result;
  }

  String _encryptBackup(String jsonStr, String password) {
    final dataBytes = utf8.encode(jsonStr);
    final keyBytes = sha256.convert(utf8.encode(password)).bytes;
    final cipherBytes = _xorCipher(dataBytes, keyBytes);
    final magic = utf8.encode('XDMCRYPT');
    final finalBytes = [...magic, ...cipherBytes];
    return base64Encode(finalBytes);
  }

  String? _decryptBackup(String encryptedBase64, String password) {
    try {
      final bytes = base64Decode(encryptedBase64);
      final magic = utf8.encode('XDMCRYPT');
      if (bytes.length < magic.length) return null;
      for (int i = 0; i < magic.length; i++) {
        if (bytes[i] != magic[i]) return null;
      }
      final cipherBytes = bytes.sublist(magic.length);
      final keyBytes = sha256.convert(utf8.encode(password)).bytes;
      final dataBytes = _xorCipher(cipherBytes, keyBytes);
      return utf8.decode(dataBytes);
    } catch (e) {
      return null;
    }
  }

  String exportBackupJson({String? password}) {
    final list = _tasks.map((t) => t.toMap()).toList();
    final jsonStr = jsonEncode(list);
    if (password != null && password.isNotEmpty) {
      return _encryptBackup(jsonStr, password);
    }
    return jsonStr;
  }

  Future<bool> importBackupJson(
    String content, {
    bool replace = false,
    String? password,
  }) async {
    try {
      String jsonStr = content.trim();
      bool isEncrypted = false;
      try {
        final bytes = base64Decode(jsonStr);
        final magic = utf8.encode('XDMCRYPT');
        if (bytes.length >= magic.length) {
          isEncrypted = true;
          for (int i = 0; i < magic.length; i++) {
            if (bytes[i] != magic[i]) {
              isEncrypted = false;
              break;
            }
          }
        }
      } catch (_) {}

      if (isEncrypted) {
        if (password == null || password.isEmpty) {
          return false;
        }
        final decrypted = _decryptBackup(jsonStr, password);
        if (decrypted == null) {
          return false;
        }
        jsonStr = decrypted;
      }

      final list = jsonDecode(jsonStr) as List;
      for (final item in list) {
        if (item is! Map) return false;
        if (!item.containsKey('id') ||
            !item.containsKey('url') ||
            !item.containsKey('fileName')) {
          return false;
        }
      }

      if (replace) {
        await _databaseService.clearAllTasks();
        _tasks.clear();
        _filteredTasksDirty = true;
      }

      var hasChanges = false;
      for (final item in list) {
        final Map<String, dynamic> map = Map<String, dynamic>.from(item as Map);
        final task = DownloadTask.fromMap(map);
        if (!_tasks.any((t) => t.id == task.id)) {
          _tasks.add(task);
          _filteredTasksDirty = true;
          await _databaseService.saveTask(task);
          hasChanges = true;
        }
      }

      if (hasChanges || replace) {
        notifyListeners();
        _updateTelemetryWidget();
      }
      return true;
    } catch (e) {
      debugPrint('Backup import error: $e');
      return false;
    }
  }

  void setSearchQuery(String query) {
    if (_searchQuery == query) return;
    _searchQuery = query;
    _filteredTasksDirty = true;
    notifyListeners();
  }

  void setStatusFilter(String filter) {
    if (_statusFilter == filter) return;
    _statusFilter = filter;
    _filteredTasksDirty = true;
    notifyListeners();
  }

  List<DownloadTask>? _cachedFilteredTasks;
  bool _filteredTasksDirty = true;

  List<DownloadTask> get filteredTasks {
    if (!_filteredTasksDirty && _cachedFilteredTasks != null) {
      return _cachedFilteredTasks!.map((t) => _findTask(t.id) ?? t).toList();
    }
    final list = _tasks.where((task) {
      final queryLower = _searchQuery.toLowerCase();
      final matchesSearch =
          task.fileName.toLowerCase().contains(queryLower) ||
          task.url.toLowerCase().contains(queryLower);
      if (!matchesSearch) return false;

      if (_categoryFilters.isNotEmpty &&
          !_categoryFilters.contains(task.category)) {
        return false;
      }

      return switch (_statusFilter) {
        'Downloading' =>
          task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.queued ||
              (task.status == DownloadStatus.completed &&
                  task.isTorrent &&
                  task.seedingEnabled),
        'Completed' => task.status == DownloadStatus.completed,
        'Failed' => task.status == DownloadStatus.failed,
        'Paused' => task.status == DownloadStatus.paused,
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
          comparison = a.fileName.toLowerCase().compareTo(
            b.fileName.toLowerCase(),
          );
          break;
        case SortOption.status:
          comparison = a.status.name.compareTo(b.status.name);
          break;
      }
      return _sortAscending ? comparison : -comparison;
    });

    _cachedFilteredTasks = list;
    _filteredTasksDirty = false;
    return list;
  }

  void setSortOption(SortOption option) {
    if (_sortOption == option) return;
    _sortOption = option;
    _filteredTasksDirty = true;
    notifyListeners();
  }

  void toggleSortDirection() {
    _sortAscending = !_sortAscending;
    _filteredTasksDirty = true;
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
    List<Map<String, dynamic>>? torrentFiles,
    String? downloadPageUrl,
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
  }) async {
    final exists = _tasks.any((t) => t.url == url && t.status != DownloadStatus.failed && t.status != DownloadStatus.completed);
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
    );

    _tasks.insert(0, task);
    _filteredTasksDirty = true;
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
      _cancelTokens[id]?.cancel('paused');
      _cancelTokens.remove(id);
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

    _retryCounts.remove(id);

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

  Future<void> pauseAllTasks() async {
    _startBatch();
    try {
      final active = _tasks
          .where((task) =>
              task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.queued)
          .toList();
      for (final task in active) {
        await pauseTask(task.id);
      }
      _pumpQueue();
    } finally {
      _endBatch();
    }
  }

  Future<void> resumeAllTasks() async {
    _startBatch();
    try {
      final resumable = _tasks
          .where((task) =>
              task.status == DownloadStatus.paused ||
              task.status == DownloadStatus.failed)
          .toList();
      for (final task in resumable) {
        await resumeTask(task.id);
      }
    } finally {
      _endBatch();
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
    _pumpQueue();
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
        clearCompletedAt: true,
      ),
    );
    _pumpQueue();
    _updateTelemetryWidget();
  }

  Future<void> deleteTask(String id, {bool deleteFiles = false}) async {
    final task = _findTask(id);
    _cancelTokens[id]?.cancel('deleted');
    _cancelTokens.remove(id);
    _speedHistories.remove(id);
    _lastProgressUpdateTimes.remove(id);
    _lastDbSaveTimes.remove(id);
    _pendingProgressUpdates.remove(id);
    _retryCounts.remove(id);
    _retryTimers[id]?.cancel();
    _retryTimers.remove(id);
    _activeFutures.remove(id);
    _tasks.removeWhere((task) => task.id == id);
    _filteredTasksDirty = true;

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
    _notificationService.cancelNotification(_getNotificationId(id));
    _updateActualTorrentUploadLimit();
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
          _startSeedingTorrent(_tasks[index]);
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

    _updateActualTorrentUploadLimit();
    notifyListeners();
    _startWidgetTimer();
  }

  void _startSeedingTorrent(DownloadTask task) {
    if (_torrentIds.containsKey(task.id)) return;
    try {
      final saveDir = task.savePath;
      int torrentId;
      if (task.url.startsWith('magnet:')) {
        torrentId = TorrentService.addMagnet(task.url, saveDir);
      } else {
        String filePath = task.url;
        if (task.url.startsWith('file://')) {
          filePath = Uri.parse(task.url).toFilePath();
        }
        torrentId = TorrentService.addTorrentFile(filePath, saveDir);
      }
      _torrentIds[task.id] = torrentId;
      TorrentService.resumeTorrent(torrentId);

      if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
        final priorities = task.torrentFiles!
            .map((f) {
              final selected = f['selected'] as bool? ?? true;
              if (!selected) return 0;
              return f['priority'] as int? ?? 4;
            })
            .toList();
        TorrentService.setFilePriorities(torrentId, priorities);
      }
    } catch (e) {
      debugPrint('Failed to restart seeding for task ${task.id}: $e');
    }
  }

  double get currentUploadSpeed {
    return _tasks
        .where(
          (task) =>
              task.status == DownloadStatus.completed &&
              task.isTorrent &&
              task.seedingEnabled,
        )
        .fold(0.0, (sum, task) => sum + task.speed);
  }

  String get currentUploadSpeedFormatted =>
      '${formatBytes(currentUploadSpeed)}/s';

  int get seedingTasksCount => _tasks
      .where(
        (task) =>
            task.status == DownloadStatus.completed &&
            task.isTorrent &&
            task.seedingEnabled,
      )
      .length;

  int getTorrentSeeds(String taskId) {
    final torrentId = _torrentIds[taskId];
    if (torrentId != null) {
      final stat = _latestTorrentStats[torrentId];
      if (stat != null) {
        return stat.numSeeds;
      }
    }
    return 0;
  }

  int getTorrentPeers(String taskId) {
    final torrentId = _torrentIds[taskId];
    if (torrentId != null) {
      final stat = _latestTorrentStats[torrentId];
      if (stat != null) {
        return stat.numPeers;
      }
    }
    return 0;
  }

  double getTorrentUploadSpeed(String taskId) {
    final task = _findTask(taskId);
    if (task == null || !task.seedingEnabled) {
      return 0.0;
    }
    final torrentId = _torrentIds[taskId];
    if (torrentId != null) {
      final stat = _latestTorrentStats[torrentId];
      if (stat != null) {
        return stat.uploadRate.toDouble();
      }
    }
    return 0.0;
  }

  DownloadTask? taskById(String id) {
    return _findTask(id);
  }

  void _pumpQueue() {
    if (_queueProcessing) return;
    _queueProcessing = true;
    try {
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
    } finally {
      _queueProcessing = false;
    }
  }

  Future<void> _startTask(DownloadTask task) async {
    if (_cancelTokens.containsKey(task.id)) return;

    if (downloadingTasksCount == 0) {
      BackgroundService.start();
    }
    _updateBackgroundNotification();
    _startWidgetTimer();
    _updateTelemetryWidget();

    final cancelToken = CancelToken();
    _cancelTokens[task.id] = cancelToken;

    int? torrentId;
    if (task.isTorrent) {
      try {
        final existingTorrentId = _torrentIds[task.id];
        if (existingTorrentId != null) {
          torrentId = existingTorrentId;
        } else {
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
        _pumpQueue();
        _updateTelemetryWidget();
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
        clearCompletedAt: true,
        torrentFiles: resetTorrentFiles ?? task.torrentFiles,
      ),
    );

    final notificationId = _getNotificationId(task.id);
    final isAutoName =
        task.fileName == 'torrent_download.zip' ||
        task.fileName.isEmpty ||
        task.fileName == fileNameFromUrl(task.url) ||
        task.fileName.startsWith('download_');

    final downloadFuture = _downloadEngine
        .download(
          url: task.url,
          tempFilePath: task.tempFilePath,
          localFilePath: task.localFilePath,
          knownFileSize: task.fileSize,
          supportsResume: task.supportsResume,
          cancelToken: cancelToken,
          isNameAutoGenerated: isAutoName,
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
          proxyHost: _settingsProvider.proxyHost,
          proxyPort: _settingsProvider.proxyPort,
          proxyUsername: _settingsProvider.proxyUsername,
          proxyPassword: _settingsProvider.proxyPassword,
          bypassSSL: _settingsProvider.bypassSSL,
          torrentFiles: task.torrentFiles,
          torrentId: torrentId,
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

            final isAutoName =
                current.fileName == 'torrent_download.zip' ||
                current.fileName.isEmpty ||
                current.fileName == fileNameFromUrl(current.url) ||
                current.fileName.startsWith('download_');

            final newFileName = isAutoName && progress.fileName != null
                ? progress.fileName!
                : current.fileName;

            final newLocalPath = newFileName != current.fileName
                ? p.join(p.dirname(current.localFilePath), safeFileName(newFileName))
                : current.localFilePath;

            final newTempPath = newFileName != current.fileName
                ? p.join(
                    p.dirname(current.tempFilePath),
                    '${safeFileName(newFileName)}.dmxpart',
                  )
                : current.tempFilePath;

            final newCategory =
                newFileName != current.fileName && current.category == 'Other'
                ? categoryFromFileName(newFileName)
                : current.category;

            final updatedTask = current.copyWith(
              fileName: newFileName,
              localFilePath: newLocalPath,
              tempFilePath: newTempPath,
              category: newCategory,
              fileSize: progress.fileSize > 0
                  ? progress.fileSize
                  : current.fileSize,
              downloadedBytes: progress.downloadedBytes,
              speed: progress.speed,
              eta: progress.eta,
              chunks:
                  progress.chunks ??
                  _buildChunks(
                    current.threadCount,
                    progress.fileSize > 0
                        ? progress.fileSize
                        : current.fileSize,
                    progress.downloadedBytes,
                  ),
              torrentFiles:
                  current.torrentFiles == null || current.torrentFiles!.isEmpty
                  ? progress.torrentFiles
                  : _updateTorrentFilesProgress(
                      current.torrentFiles!,
                      progress.downloadedBytes,
                      progress.speed,
                    ),
              supportsResume: progress.supportsResume ?? current.supportsResume,
            );

            // Throttle UI notification and notification progress to 200ms
            if (now - lastUpdate >= 200) {
              _lastProgressUpdateTimes[task.id] = now;
              _tasks[index] = updatedTask;
              notifyListeners();

              if (_settingsProvider.notificationsEnabled) {
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
              }
            } else {
              _tasks[index] = updatedTask;
            }

            // Throttle database saves to 2000ms
            if (now - lastDbSave >= 2000) {
              _lastDbSaveTimes[task.id] = now;
              _pendingProgressUpdates.remove(task.id);
              _databaseService.saveTask(updatedTask).catchError((e) {
                debugPrint('Failed to save task progress to database: $e');
              });
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
              // For torrents, always snap to fileSize so progress shows 100%.
              // For HTTP, use the actual bytes written (may differ if server
              // reported a wrong Content-Length).
              downloadedBytes: current.isTorrent && current.fileSize > 0
                  ? current.fileSize
                  : current.downloadedBytes,
              speed: 0,
              eta: 0,
              chunks: List<double>.filled(current.threadCount, 1.0),
              completedAt: now,
              updatedAt: now,
              torrentFiles: current.torrentFiles != null
                  ? _markTorrentFilesCompleted(current.torrentFiles!)
                  : null,
            ),
          );
          if (_settingsProvider.notificationsEnabled) {
            _notificationService.showDownloadComplete(
              notificationId: notificationId,
              title: task.fileName,
              playSound: _settingsProvider.soundNotification,
            );
          }
        })
        .catchError((Object error) async {
          await _flushPendingProgress(task.id);
          final current = _findTask(task.id);
          if (current == null) return;
          if (error is DioException && error.type == DioExceptionType.cancel) {
            _retryCounts.remove(task.id);
            // Only clear the speed/eta fields — do NOT override the status.
            // pauseTask() / cancelTask() may have already transitioned the
            // status to paused/failed; overwriting it here would undo that
            // transition (race condition between the async catchError and the
            // synchronous state machine in pauseTask).
            if (current.status == DownloadStatus.downloading) {
              await _setTask(current.copyWith(speed: 0, clearEta: true));
            }
            _notificationService.cancelNotification(notificationId);
            return;
          }

          // Check if YouTube link expired (403 Forbidden or 410 Gone)
          if (error is DioException &&
              (error.response?.statusCode == 403 || error.response?.statusCode == 410 ||
               error.message?.contains('403') == true || error.message?.contains('410') == true) &&
              current.downloadPageUrl != null &&
              YoutubeService.extractVideoId(current.downloadPageUrl!) != null) {
            debugPrint('Detected YouTube ${error.response?.statusCode ?? 403} error. Attempting to refresh stream URL...');
            bool refreshed = false;
            try {
              final newUrl = await YoutubeService.refreshStreamUrl(
                current.downloadPageUrl!,
                current.url,
              );
              if (newUrl != null) {
                await updateTaskUrlAndResume(current.id, newUrl);
                refreshed = true;
                return;
              }
            } catch (e) {
              debugPrint('Failed to refresh YouTube stream URL: $e');
            }

            if (!refreshed) {
              // If refresh failed, still try auto-retry since the URL might work after a brief delay
              final currentRetry = _retryCounts[task.id] ?? 0;
              if (_settingsProvider.autoRetryEnabled && currentRetry < _settingsProvider.maxRetries) {
                _retryCounts[task.id] = currentRetry + 1;
                final delaySeconds = _settingsProvider.retryDelaySeconds;
                await _setTask(
                  current.copyWith(
                    status: DownloadStatus.queued,
                    speed: 0,
                    errorMessage: 'YouTube stream expired. Retrying in $delaySeconds seconds...',
                  ),
                );
                _retryTimers[task.id]?.cancel();
                _retryTimers[task.id] = Timer(Duration(seconds: delaySeconds), () {
                  _retryTimers.remove(task.id);
                  final checkedTask = _findTask(task.id);
                  if (checkedTask != null && checkedTask.status == DownloadStatus.queued) {
                    _pumpQueue();
                  }
                });
                return;
              }
            }
          }

          final isRetryable = _isRetryableError(error);
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
                    'Retrying in $delaySeconds seconds: ${_errorMessage(error)}',
              ),
            );

            _retryTimers[task.id]?.cancel();
            _retryTimers[task.id] = Timer(Duration(seconds: delaySeconds), () {
              _retryTimers.remove(task.id);
              final checkedTask = _findTask(task.id);
              if (checkedTask != null &&
                  checkedTask.status == DownloadStatus.queued) {
                _pumpQueue();
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
              errorMessage: _errorMessage(error),
            ),
          );
          if (_settingsProvider.notificationsEnabled) {
            _notificationService.showDownloadFailed(
              notificationId: notificationId,
              title: task.fileName,
              error: _errorMessage(error),
              playSound: _settingsProvider.soundNotification,
            );
          }
        })
        .whenComplete(() {
          _cancelTokens.remove(task.id);
          _activeFutures.remove(task.id);
          _pumpQueue();
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

    final oldTask = _tasks[index];
    _tasks[index] = updated;

    if (oldTask.status != updated.status ||
        oldTask.category != updated.category ||
        oldTask.fileName != updated.fileName ||
        oldTask.fileSize != updated.fileSize) {
      _filteredTasksDirty = true;
    }

    try {
      await _databaseService.saveTask(updated);
    } catch (e) {
      debugPrint('Error saving task to database: $e');
    }
    _updateActualTorrentUploadLimit();
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
      if (error.response?.statusCode != null) {
        final code = error.response!.statusCode;
        return switch (code) {
          403 => '403 Forbidden: Access denied. The download link may have expired or permission is required.',
          401 => '401 Unauthorized: Authentication is required to access this file.',
          404 => '404 Not Found: The file was not found on the server.',
          410 => '410 Gone: The file has been permanently removed from the server.',
          416 => '416 Range Not Satisfiable: The server returned an invalid byte range error.',
          500 => '500 Internal Server Error: Server-side issue occurred.',
          503 => '503 Service Unavailable: The server is temporarily down or overloaded.',
          _ => 'HTTP Error $code: ${error.message ?? "Server returned invalid response."}',
        };
      }
      return error.message ?? error.type.name;
    }
    return error.toString();
  }

  bool _isRetryableError(Object error) {
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

  void _onSettingsChanged() {
    _checkWifiOnlyConstraint();
    _updateActualTorrentUploadLimit();
    _pumpQueue();
  }

  void _initConnectivity() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
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

  Future<void> _checkWifiOnlyConstraint() async {
    if (!_settingsProvider.wifiOnly) {
      await _resumeWaitingForWifi();
      return;
    }

    final hasWifi =
        _currentConnectivity.contains(ConnectivityResult.wifi) ||
        _currentConnectivity.contains(ConnectivityResult.ethernet) ||
        _currentConnectivity.contains(ConnectivityResult.vpn);

    if (!hasWifi) {
      await _pauseForWifiOnly();
    } else {
      await _resumeWaitingForWifi();
    }
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

  Future<void> _resumeWaitingForWifi() async {
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
    _pumpQueue();
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
      _updateActualTorrentUploadLimit();
      notifyListeners();
      _pumpQueue();
    }
  }

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

  void _updateSeedingSpeeds() {
    var changed = false;
    for (var i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      if (task.status == DownloadStatus.completed &&
          task.isTorrent &&
          task.seedingEnabled) {
        double speed = 0.0;
        final torrentId = _torrentIds[task.id];
        if (torrentId != null) {
          final torrent = _latestTorrentStats[torrentId];
          if (torrent != null) {
            speed = torrent.uploadRate.toDouble();
          }
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
      _widgetTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
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

    var activeIdx = taskIndex;
    final wasDownloading = task.status == DownloadStatus.downloading;
    if (wasDownloading) {
      await pauseTask(taskId);
      // Reload task state as it might have updated during pause
      activeIdx = _tasks.indexWhere((t) => t.id == taskId);
      if (activeIdx == -1) return;
      task = _tasks[activeIdx];
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
      final priorities = files
          .map((f) {
            final selected = f['selected'] as bool? ?? true;
            if (!selected) return 0;
            return f['priority'] as int? ?? 4;
          })
          .toList();
      TorrentService.setFilePriorities(torrentId, priorities);
    }

    notifyListeners();
  }

  Future<void> updateTaskUrl(String taskId, String newUrl) async {
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
      // Reload task state in case it updated during pause
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
      // Remove old torrent from engine if registered
      final torrentId = _torrentIds[taskId];
      if (torrentId != null) {
        TorrentService.removeTorrent(torrentId);
        _torrentIds.remove(taskId);
      }

      // Clean up part files
      await _cleanupPartFiles(task);

      // Resolve metadata for new URL
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
      await _databaseService.saveTask(updatedTask);
      notifyListeners();

      if (wasDownloading) {
        await resumeTask(taskId);
      }
      return;
    }

    // Resolve metadata for standard URL
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
      throw Exception('Failed to resolve new link: $e');
    }

    bool sizeChanged = false;
    if (metadata.fileSize > 0 &&
        task.fileSize > 0 &&
        metadata.fileSize != task.fileSize) {
      sizeChanged = true;
    }

    if (sizeChanged) {
      await _cleanupPartFiles(task);
    }

    final updatedTask = task.copyWith(
      url: cleanUrl,
      fileSize: metadata.fileSize > 0 ? metadata.fileSize : task.fileSize,
      supportsResume: metadata.supportsResume,
      downloadedBytes: sizeChanged ? 0 : task.downloadedBytes,
      chunks: sizeChanged
          ? List<double>.filled(task.threadCount, 0.0)
          : task.chunks,
      fileName:
          (task.fileName.isEmpty || task.fileName == 'torrent_download.zip')
          ? metadata.fileName
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

  Future<void> updateTaskUrlAndResume(String id, String newUrl) async {
    final task = _findTask(id);
    if (task == null) return;
    
    // Check if the stream format (itag) changed
    final oldUri = Uri.tryParse(task.url);
    final newUri = Uri.tryParse(newUrl);
    final oldItag = oldUri?.queryParameters['itag'];
    final newItag = newUri?.queryParameters['itag'];
    final itagChanged = oldItag != null && newItag != null && oldItag != newItag;
    
    if (itagChanged) {
      // Different format — start over to avoid corrupted file
      await startOverTask(id, newUrl);
    } else {
      await updateTaskUrl(id, newUrl);
      final updated = _findTask(id);
      if (updated != null && updated.status != DownloadStatus.downloading) {
        await resumeTask(id);
      }
    }
  }

  Future<void> startOverTask(String id, String newUrl) async {
    final task = _findTask(id);
    if (task == null) return;

    // Cancel active download if running
    _cancelTokens[id]?.cancel('restart');
    _cancelTokens.remove(id);

    final activeFuture = _activeFutures[id];
    if (activeFuture != null) {
      try {
        await activeFuture;
      } catch (_) {}
    }

    final torrentId = _torrentIds[id];
    if (torrentId != null) {
      TorrentService.removeTorrent(torrentId);
      _torrentIds.remove(id);
    }

    // Clean up partial files
    await _cleanupPartFiles(task);

    // Also clean up final completed file if it exists
    try {
      final localFile = File(task.localFilePath);
      if (await localFile.exists()) {
        await localFile.delete();
      }
    } catch (e) {
      debugPrint('Failed to delete completed file during start over: $e');
    }

    // Reset task fields
    await _setTask(
      task.copyWith(
        url: newUrl.trim(),
        status: DownloadStatus.queued,
        downloadedBytes: 0,
        speed: 0,
        clearEta: true,
        clearError: true,
        clearCompletedAt: true,
        chunks: List<double>.filled(task.threadCount, 0.0),
      ),
    );

    _pumpQueue();
    _startWidgetTimer();
    _updateTelemetryWidget();
  }

  List<Map<String, dynamic>> _updateTorrentFilesProgress(
    List<Map<String, dynamic>> files,
    int totalDownloaded,
    double totalSpeed,
  ) {
    final result = files.map((f) => Map<String, dynamic>.from(f)).toList();

    final selectedFiles = result.where((f) => f['selected'] == true).toList();
    if (selectedFiles.isEmpty) return result;

    int selectedSize = selectedFiles.fold(0, (sum, f) => sum + (f['length'] as int));
    if (selectedSize == 0) return result;

    // 10% of totalDownloaded is distributed proportionally to simulate background downloading
    final proportionalTotal = (totalDownloaded * 0.1).round();
    final phasedTotal = totalDownloaded - proportionalTotal;

    // Calculate proportional shares
    final proportionalShares = <String, int>{};
    for (final f in selectedFiles) {
      final length = (f['length'] as num?)?.toInt() ?? 0;
      final name = f['name'] as String;
      final share = selectedSize > 0
          ? (proportionalTotal * (length / selectedSize)).round()
          : 0;
      proportionalShares[name] = share.clamp(0, length);
    }

    // Distribute the remaining 90% (phasedTotal) sequentially by priority: High (7), Normal (4), Low (1)
    final highFiles = selectedFiles.where((f) => (f['priority'] as int? ?? 4) == 7).toList();
    final normalFiles = selectedFiles.where((f) => (f['priority'] as int? ?? 4) == 4).toList();
    final lowFiles = selectedFiles.where((f) => (f['priority'] as int? ?? 4) == 1).toList();

    int remainingPhased = phasedTotal;
    final phasedShares = <String, int>{};
    for (final f in selectedFiles) {
      phasedShares[f['name'] as String] = 0;
    }

    // Phase 1: High priority
    if (highFiles.isNotEmpty) {
      final highSize = highFiles.fold(0, (sum, f) => sum + (f['length'] as int));
      if (remainingPhased <= highSize) {
        for (final f in highFiles) {
          final length = f['length'] as int;
          final share = highSize > 0 ? (remainingPhased * (length / highSize)).round() : 0;
          phasedShares[f['name'] as String] = share.clamp(0, length);
        }
        remainingPhased = 0;
      } else {
        for (final f in highFiles) {
          phasedShares[f['name'] as String] = f['length'] as int;
        }
        remainingPhased -= highSize;
      }
    }

    // Phase 2: Normal priority
    if (remainingPhased > 0 && normalFiles.isNotEmpty) {
      final normalSize = normalFiles.fold(0, (sum, f) => sum + (f['length'] as int));
      if (remainingPhased <= normalSize) {
        for (final f in normalFiles) {
          final length = f['length'] as int;
          final share = normalSize > 0 ? (remainingPhased * (length / normalSize)).round() : 0;
          phasedShares[f['name'] as String] = share.clamp(0, length);
        }
        remainingPhased = 0;
      } else {
        for (final f in normalFiles) {
          phasedShares[f['name'] as String] = f['length'] as int;
        }
        remainingPhased -= normalSize;
      }
    }

    // Phase 3: Low priority
    if (remainingPhased > 0 && lowFiles.isNotEmpty) {
      final lowSize = lowFiles.fold(0, (sum, f) => sum + (f['length'] as int));
      for (final f in lowFiles) {
        final length = f['length'] as int;
        final share = lowSize > 0 ? (remainingPhased * (length / lowSize)).round() : 0;
        phasedShares[f['name'] as String] = share.clamp(0, length);
      }
    }

    // Combine proportional and phased shares, and calculate speeds
    for (var f in result) {
      if (f['selected'] != true) {
        f['downloadedBytes'] = 0;
        f['speed'] = 0.0;
        continue;
      }
      final name = f['name'] as String;
      final length = f['length'] as int;

      final combined = (proportionalShares[name] ?? 0) + (phasedShares[name] ?? 0);
      final downloadedBytes = combined.clamp(0, length);
      f['downloadedBytes'] = downloadedBytes;

      f['speed'] = totalSpeed > 0 && downloadedBytes < length
          ? totalSpeed * (length / selectedSize)
          : 0.0;
    }

    return result;
  }

  /// Reads each torrent file's actual byte count from disk.
  /// Returns a list parallel to [task.torrentFiles] where each entry is the
  /// number of bytes confirmed written to disk (clamped to the declared length).
  /// Files that don't exist yet return 0.  For completed files the value equals
  /// the declared length (i.e. 100%).
  Future<List<int>> getTorrentFileActualBytes(String taskId) async {
    final task = _findTask(taskId);
    if (task == null || task.torrentFiles == null) return [];

    if (task.status == DownloadStatus.completed) {
      return task.torrentFiles!.map((f) => (f['length'] as int?) ?? 0).toList();
    }

    final result = <int>[];
    for (final f in task.torrentFiles!) {
      final downloaded = (f['downloadedBytes'] as int?) ?? 0;
      result.add(downloaded);
    }
    return result;
  }

  List<Map<String, dynamic>> _markTorrentFilesCompleted(
    List<Map<String, dynamic>> files,
  ) {
    return files.map((f) {
      final copy = Map<String, dynamic>.from(f);
      if (copy['selected'] == true) {
        copy['downloadedBytes'] = (copy['length'] as num?)?.toInt() ?? 0;
      } else {
        copy['downloadedBytes'] = 0;
      }
      copy['speed'] = 0.0;
      return copy;
    }).toList();
  }

  void _updateActualTorrentUploadLimit() {
    if (!TorrentService.isSupported || !TorrentService.isInitialized) return;

    if (_torrentIds.isEmpty) {
      return;
    }

    bool anySeedingEnabled = false;
    for (final taskId in _torrentIds.keys) {
      final task = _findTask(taskId);
      if (task != null && task.seedingEnabled) {
        anySeedingEnabled = true;
        break;
      }
    }

    if (anySeedingEnabled) {
      int? minLimitBytes;
      for (final taskId in _torrentIds.keys) {
        final task = _findTask(taskId);
        if (task != null && task.seedingEnabled && task.seedingLimited) {
          final taskLimitBytes = (task.seedingLimitKbps * 1000) ~/ 8;
          if (taskLimitBytes > 0) {
            if (minLimitBytes == null || taskLimitBytes < minLimitBytes) {
              minLimitBytes = taskLimitBytes;
            }
          }
        }
      }

      if (minLimitBytes != null) {
        TorrentService.setUploadLimit(minLimitBytes);
      } else if (_settingsProvider.globalTorrentSeedingLimited) {
        final limitBytes =
            (_settingsProvider.globalTorrentSeedingLimitKbps * 1000) ~/ 8;
        TorrentService.setUploadLimit(limitBytes > 0 ? limitBytes : 0);
      } else {
        TorrentService.setUploadLimit(0); // Unlimited
      }
    } else {
      TorrentService.setUploadLimit(0); // Effectively 0
    }
  }

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
    super.dispose();
  }
}
