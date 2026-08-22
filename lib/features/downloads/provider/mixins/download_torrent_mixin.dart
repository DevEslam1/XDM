import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../../core/services/database_service.dart';
import '../../../../core/services/logging_service.dart';
import '../../../../core/services/retry_engine.dart';
import '../../../../core/services/torrent_service.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/utils/torrent_id_resolver.dart';
import '../../../../features/settings/provider/settings_provider.dart';
import '../../models/download_task.dart';

/// Thrown when the native torrent engine rejects an add (returns -1).
class TorrentAddRejectedException implements Exception {
  const TorrentAddRejectedException();
  @override
  String toString() =>
      'TorrentAddRejectedException: torrent engine rejected the torrent';
}

/// Mixin that encapsulates torrent-specific orchestration: seeding lifecycle,
/// per-file progress distribution, upload limit management, and torrent stats
/// queries.
///
/// Requires the host class to expose:
///  - `List<DownloadTask> get providerTasks`
///  - `Map<String, int> get providerTorrentIds`
///  - `Map<int, TorrentUpdateInfo> get providerLatestTorrentStats`
///  - `SettingsProvider get providerSettingsProvider`
///  - `DownloadTask? findTaskById(String id)`
///  - `DatabaseService get providerDatabaseService`
///  - `void providerNotifyListeners()`
///  - `void providerStartWidgetTimer()`
mixin DownloadTorrentMixin {
  // ---------------------------------------------------------------------------
  // Abstract contract — must be provided by the host class
  // ---------------------------------------------------------------------------
  List<DownloadTask> get providerTasks;
  Map<String, int> get providerTorrentIds;
  Map<int, TorrentUpdateInfo> get providerLatestTorrentStats;
  SettingsProvider get providerSettingsProvider;
  DownloadTask? findTaskById(String id);
  DatabaseService get providerDatabaseService;
  void providerNotifyListeners();
  void providerStartWidgetTimer();
  set filteredTasksDirty(bool value);

  /// Whether the device is currently on Wi-Fi / ethernet (used by the seeding
  /// ratio policy's "seed only on Wi-Fi" rule).
  bool get providerIsOnWifi;

  /// Whether the device is currently charging (used by the seeding ratio
  /// policy's "seed only when charging" rule).
  bool get providerIsCharging;

  // ---------------------------------------------------------------------------
  // Seeding lifecycle
  // ---------------------------------------------------------------------------
  Future<void> startSeedingTorrent(DownloadTask task) async {
    // B3: Check whether a live native handle already exists before adding.
    //     If the Dart map has an entry AND the native session still has the
    //     torrent alive, just resume it — no duplicate handle created.
    if (providerTorrentIds.containsKey(task.id)) {
      final existingId = providerTorrentIds[task.id]!;
      if (TorrentService.isTorrentAlive(existingId)) {
        // FIX-02: check for error state before resuming
        final latestStats = providerLatestTorrentStats[existingId];
        if (latestStats != null &&
            latestStats.stateLabel.toLowerCase().contains('error')) {
          debugPrint(
            '[DMX] Torrent $existingId is in error state. '
            'Removing and re-adding for clean retry.',
          );
          try {
            TorrentService.pauseTorrent(existingId);
            TorrentService.removeTorrent(existingId, deleteFiles: false);
          } catch (e, st) {
            LoggingService.logger('DownloadTorrentMixin').warning(
                'Failed to remove stale error torrent $existingId', e, st);
          }
          providerTorrentIds.remove(task.id);
          // Fall through to the add-new-handle path below
        } else {
          TorrentService.resumeTorrent(existingId);
          return;
        }
      }
      // Stale map entry: the native session no longer knows this ID.
      // Remove it so the add below creates a fresh handle cleanly.
      providerTorrentIds.remove(task.id);
    }
    try {
      final saveDir = task.savePath;
      // ERR-RESILIENCE-2.1/5.1: Centralized retry for the native add
      // operation. A rejected handle (torrentId < 0) or a transient native
      // error is retried once after a short backoff before the task is failed.
      final torrentId = await RetryEngine(
        maxRetries: 1,
        baseDelay: const Duration(seconds: 2),
        backoffMultiplier: 2.0,
        maxDelay: const Duration(seconds: 4),
      ).execute(
        () async {
          if (task.url.startsWith('magnet:')) {
            final id = TorrentService.addMagnet(task.url, saveDir);
            if (id < 0) throw const TorrentAddRejectedException();
            return id;
          }
          String filePath = task.url;
          if (task.url.startsWith('file://')) {
            filePath = Uri.parse(task.url).toFilePath();
          }
          final id = TorrentService.addTorrentFile(
            filePath,
            saveDir,
            sourceKey: task.url,
          );
          if (id < 0) throw const TorrentAddRejectedException();
          return id;
        },
        onRetry: (error, attempt, delay) {
          debugPrint(
            '[DMX] Torrent add rejected for ${task.id}, retrying in ${delay.inMilliseconds}ms',
          );
        },
      );
      providerTorrentIds[task.id] = torrentId;
      final tIdx = providerTasks.indexWhere((t) => t.id == task.id);
      if (tIdx != -1) {
        providerTasks[tIdx] = providerTasks[tIdx].copyWith(torrentId: torrentId);
      }
      TorrentService.resumeTorrent(torrentId);

      if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
        final fileCount = TorrentService.getFileCount(torrentId);
        if (fileCount == task.torrentFiles!.length) {
          final priorities = task.torrentFiles!.map((f) {
            final selected = isTorrentFileSelected(f);
            if (!selected) return 0;
            return f['priority'] as int? ?? 4;
          }).toList();
          TorrentService.setFilePriorities(torrentId, priorities);
        } else {
          debugPrint(
            'Skipping file priorities for ${task.id}: stored file count '
            '(${task.torrentFiles!.length}) does not match torrent ($fileCount).',
          );
        }
      }
    } catch (e) {
      debugPrint('Failed to restart seeding for task ${task.id}: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Upload speed aggregates
  // ---------------------------------------------------------------------------
  double get currentUploadSpeed {
    return providerTasks
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

  int get seedingTasksCount => providerTasks
      .where(
        (task) =>
            task.status == DownloadStatus.completed &&
            task.isTorrent &&
            task.seedingEnabled,
      )
      .length;

  // ---------------------------------------------------------------------------
  // Torrent stats queries — delegates to TorrentService / latest stats
  // ---------------------------------------------------------------------------
  int getTorrentSeeds(String taskId) {
    final task = findTaskById(taskId);
    final torrentId =
        TorrentIdResolver.resolve(task, providerMap: providerTorrentIds);
    if (torrentId != null) {
      final stat = providerLatestTorrentStats[torrentId];
      if (stat != null) {
        return stat.numSeeds < 0 ? 0 : stat.numSeeds;
      }
    }
    return 0;
  }

  int getTorrentPeers(String taskId) {
    final task = findTaskById(taskId);
    final torrentId =
        TorrentIdResolver.resolve(task, providerMap: providerTorrentIds);
    if (torrentId != null) {
      final stat = providerLatestTorrentStats[torrentId];
      if (stat != null) {
        return stat.numPeers < 0 ? 0 : stat.numPeers;
      }
    }
    return 0;
  }

  double getTorrentUploadSpeed(String taskId) {
    final task = findTaskById(taskId);
    if (task == null) {
      return 0.0;
    }
    if (task.status == DownloadStatus.completed && !task.seedingEnabled) {
      return 0.0;
    }
    final torrentId =
        TorrentIdResolver.resolve(task, providerMap: providerTorrentIds);
    if (torrentId != null) {
      final stat = providerLatestTorrentStats[torrentId];
      if (stat != null) {
        return stat.uploadRate.toDouble();
      }
    }
    return 0.0;
  }

  String getSeedingSummary(String taskId) {
    final task = findTaskById(taskId);
    if (task == null) return '';
    final torrentId =
        TorrentIdResolver.resolve(task, providerMap: providerTorrentIds);
    final stat = torrentId != null ? providerLatestTorrentStats[torrentId] : null;
    final totalUploaded = stat?.totalPayloadUpload ?? task.uploadedBytes;
    final totalDownloaded = stat?.totalPayloadDownload ?? task.downloadedBytes;
    final ratio = totalDownloaded > 0 ? (totalUploaded / totalDownloaded) : 0.0;
    final seedingDuration = task.completedAt != null
        ? DateTime.now().difference(task.completedAt!)
        : Duration.zero;
    final minutes = seedingDuration.inMinutes;
    final hours = seedingDuration.inHours;
    final timeStr = hours > 0
        ? '${hours}h ${seedingDuration.inMinutes.remainder(60)}m'
        : '${minutes}m';
    return 'Ratio ${ratio.toStringAsFixed(2)} • $timeStr seeded';
  }

  // ---------------------------------------------------------------------------
  // Torrent file progress — native getFileProgress provides exact per-file bytes
  // ---------------------------------------------------------------------------
  // FIX(8): Mark completed files with true progress (not estimated)
  // FIX(8): Mark completed files with true progress (not estimated)
  List<Map<String, dynamic>> markTorrentFilesCompleted(
    List<Map<String, dynamic>> files,
  ) {
    return files.map((f) {
      final copy = Map<String, dynamic>.from(f);
      if (isTorrentFileSelected(copy)) {
        copy['downloadedBytes'] = (copy['length'] as num?)?.toInt() ?? 0;
        copy['progress'] = 1.0;
        copy['isComplete'] = true;
        copy['progressEstimated'] = false;
      } else {
        copy['downloadedBytes'] = 0;
        copy['progress'] = 0.0;
        copy['isComplete'] = false;
        copy['progressEstimated'] = false;
      }

      copy['speed'] = 0.0;
      return copy;
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Upload limit management
  // ---------------------------------------------------------------------------

  Future<List<int>> getTorrentFileActualBytes(String taskId) async {
    final task = findTaskById(taskId);
    if (task == null || task.torrentFiles == null) return [];

    final torrentId = providerTorrentIds[taskId];
    if (torrentId == null) {
      return task.torrentFiles!
          .map((f) => (f['downloadedBytes'] as int?) ?? 0)
          .toList();
    }

    try {
      final files = TorrentService.getFiles(torrentId);
      return files.map((f) => f.downloadedBytes).toList();
    } catch (e, st) {
      Logger(
        'download_torrent_mixin',
      ).warning('[download_torrent_mixin] operation failed', e, st);
      return task.torrentFiles!
          .map((f) => (f['downloadedBytes'] as int?) ?? 0)
          .toList();
    }
  }

  void updateActualTorrentUploadLimit() {
    if (!TorrentService.isSupported || !TorrentService.isInitialized) return;

    if (providerTorrentIds.isEmpty) {
      return;
    }

    bool anySeedingEnabled = false;
    for (final taskId in List<String>.from(providerTorrentIds.keys)) {
      final task = findTaskById(taskId);
      if (task != null && task.seedingEnabled) {
        anySeedingEnabled = true;
        break;
      }
    }

    if (anySeedingEnabled) {
      int totalTaskLimitsBytes = 0;
      bool hasSpecificTaskLimit = false;
      for (final taskId in List<String>.from(providerTorrentIds.keys)) {
        final task = findTaskById(taskId);
        if (task != null && task.seedingEnabled && task.seedingLimited) {
          final taskLimitBytes = (task.seedingLimitKbps * 1000) ~/ 8;
          if (taskLimitBytes > 0) {
            totalTaskLimitsBytes += taskLimitBytes;
            hasSpecificTaskLimit = true;
          }
        }
      }

      final globalLimitBytes = providerSettingsProvider.globalTorrentSeedingLimited
          ? (providerSettingsProvider.globalTorrentSeedingLimitKbps * 1000) ~/ 8
          : 0;

      // FIX: [Audit] Sum per-task limits rather than taking minimum to avoid throttling all torrents
      if (hasSpecificTaskLimit) {
        final effectiveLimit = (globalLimitBytes > 0 && totalTaskLimitsBytes > globalLimitBytes)
            ? globalLimitBytes
            : totalTaskLimitsBytes;
        TorrentService.setUploadLimit(effectiveLimit);
      } else if (globalLimitBytes > 0) {
        TorrentService.setUploadLimit(globalLimitBytes);
      } else {
        TorrentService.setUploadLimit(0); // Unlimited
      }
    } else {
      TorrentService.setUploadLimit(0); // Effectively 0
    }
  }

  final Map<String, DateTime> _lastSeedingCheck = {};

  /// Updates the in-memory `speed` field on all seeding tasks from live
  /// torrent stats. Returns `true` if any task was modified.
  bool updateSeedingSpeeds() {
    var changed = false;
    final now = DateTime.now();
    for (var i = 0; i < providerTasks.length; i++) {
      final task = providerTasks[i];
      if (task.status == DownloadStatus.completed &&
          task.isTorrent &&
          task.seedingEnabled) {
        double speed = 0.0;
        final torrentId = providerTorrentIds[task.id];
        if (torrentId != null) {
          final torrent = providerLatestTorrentStats[torrentId];
          if (torrent != null) {
            speed = torrent.uploadRate.toDouble();
          }
        }
        providerTasks[i] = task.copyWith(speed: speed);
        changed = true;

        final lastCheck = _lastSeedingCheck[task.id];
        if (lastCheck == null || now.difference(lastCheck).inSeconds >= 30) {
          _lastSeedingCheck[task.id] = now;
          if (task.seedingEnabled && task.completedAt != null) {
            final maxMinutes = TorrentService.maxSeedingTimeMinutes;
            bool shouldStopSeeding = false;

            if (maxMinutes > 0) {
              final seedingDuration = now.difference(
                task.completedAt!,
              );
              if (seedingDuration.inMinutes >= maxMinutes) {
                shouldStopSeeding = true;
              }
            }

            if (shouldStopSeeding) {
              unawaited(updateTaskSeeding(task.id, enabled: false));
              filteredTasksDirty = true;
              changed = true;
            }
          }
        }
      } else if (task.speed > 0 && task.status == DownloadStatus.completed) {
        providerTasks[i] = task.copyWith(speed: 0);
        changed = true;
      }
    }
    return changed;
  }

  // ---------------------------------------------------------------------------
  // Helpers (private to mixin)
  // ---------------------------------------------------------------------------

  Future<void> updateTaskSeeding(
    String taskId, {
    bool? enabled,
    bool? limited,
    int? limitKbps,
  }) async {
    final index = providerTasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final oldTask = providerTasks[index];
    final newEnabled = enabled ?? oldTask.seedingEnabled;

    providerTasks[index] = oldTask.copyWith(
      seedingEnabled: newEnabled,
      seedingLimited: limited,
      seedingLimitKbps: limitKbps,
      speed: newEnabled ? oldTask.speed : 0,
    );
    filteredTasksDirty = true;
    await providerDatabaseService.saveTask(providerTasks[index]);

    if (oldTask.isTorrent) {
      final torrentId =
          TorrentIdResolver.resolve(oldTask, providerMap: providerTorrentIds);
      if (newEnabled) {
        if (torrentId != null) {
          TorrentService.resumeTorrent(torrentId);
        } else {
          unawaited(startSeedingTorrent(providerTasks[index]));
        }
      } else {
        // Only pause the torrent session if the task has already
        // finished downloading (status == completed). Do NOT remove
        // handle or evict ID so user can resume seeding anytime.
        if (torrentId != null && oldTask.status == DownloadStatus.completed) {
          await TorrentService.pauseTorrent(torrentId);
        }
        // Snap downloadedBytes to fileSize so the Completed tab shows 100%.
        final updatedIdx = providerTasks.indexWhere((t) => t.id == taskId);
        if (updatedIdx != -1) {
          final t = providerTasks[updatedIdx];
          if (t.status == DownloadStatus.completed &&
              t.fileSize > 0 &&
              t.downloadedBytes < t.fileSize) {
            providerTasks[updatedIdx] = t.copyWith(
              downloadedBytes: t.fileSize,
              chunks: List<double>.filled(t.threadCount, 1.0),
            );
            await providerDatabaseService.saveTask(providerTasks[updatedIdx]);
          }
        }
      }
    }

    updateActualTorrentUploadLimit();
    providerNotifyListeners();
    providerStartWidgetTimer();
  }

  Future<void> updateTorrentTaskFiles(
    String taskId,
    List<Map<String, dynamic>> files,
  ) async {
    final index = providerTasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final task = providerTasks[index];

    // Calculate new total size and downloaded bytes of selected files
    final selectedSize = files
        .where((f) => isTorrentFileSelected(f))
        .fold(0, (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0));
    final selectedDownloaded = files
        .where((f) => isTorrentFileSelected(f))
        .fold(0,
            (sum, f) => sum + ((f['downloadedBytes'] as num?)?.toInt() ?? 0));

    String updatedCategory = task.category;
    if (task.category == 'Other' || task.category.isEmpty) {
      final selectedFiles =
          files.where((f) => isTorrentFileSelected(f)).toList();
      final sample = selectedFiles.isNotEmpty
          ? selectedFiles.first
          : (files.isNotEmpty ? files.first : null);
      if (sample != null) {
        final fileName = (sample['name'] as String? ?? '').replaceAll('+', ' ');
        final cat = categoryFromFileName(fileName);
        if (cat != 'Other') {
          updatedCategory = cat;
        }
      }
    }

    // FIX-02: Stamp files with lastFileSyncMs timestamp for DB/UI sync tracking
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final stampedFiles =
        files.map((f) => {...f, 'lastFileSyncMs': timestamp}).toList();

    var newStatus = task.status;
    if (task.status == DownloadStatus.completed &&
        selectedDownloaded < selectedSize) {
      newStatus = DownloadStatus.paused;
    }

    final updated = task.copyWith(
      status: newStatus,
      torrentFiles: stampedFiles,
      fileSize: selectedSize > 0 ? selectedSize : task.fileSize,
      downloadedBytes: selectedDownloaded,
      category: updatedCategory,
    );

    providerTasks[index] = updated;
    filteredTasksDirty = true;
    await providerDatabaseService.saveTask(updated);

    // Propagate priority changes to the live torrent engine safely.
    final torrentId = providerTorrentIds[taskId];
    if (torrentId != null) {
      try {
        final nativeFiles = TorrentService.getFiles(torrentId);
        if (nativeFiles.length == files.length) {
          final priorities = files.map((f) {
            final selected = isTorrentFileSelected(f);
            if (!selected) return 0;
            return f['priority'] as int? ?? 4;
          }).toList();
          TorrentService.setFilePriorities(torrentId, priorities);
        }
      } catch (e) {
        debugPrint('[DownloadTorrentMixin] Failed to set file priorities: $e');
      }
    }

    providerNotifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Ratio-Based Auto-Stop & Queue Enforcement
  // ---------------------------------------------------------------------------
  void checkTorrentRatioLimits() {
    final settings = providerSettingsProvider;
    final policy = SeedingPolicy(
      maxRatio: settings.shareRatioLimit,
      maxSeedTime: Duration(minutes: settings.maxSeedingTimeMinutes),
      seedOnlyWhenCharging: settings.seedOnlyWhenCharging,
      seedOnlyOnWifi: settings.seedOnlyOnWifi,
    );

    for (final task in providerTasks) {
      if (!task.isTorrent || !task.seedingEnabled) continue;
      if (task.status != DownloadStatus.completed) continue;

      final torrentId = providerTorrentIds[task.id];
      if (torrentId == null) continue;

      final stats = providerLatestTorrentStats[torrentId];
      if (stats == null) continue;

      final seedDuration = task.completedAt != null
          ? DateTime.now().difference(task.completedAt!)
          : Duration.zero;

      final downloadedBytes = stats.totalPayloadDownload > 0
          ? stats.totalPayloadDownload
          : (task.downloadedBytes > 0 ? task.downloadedBytes : 1);
      final currentRatio = stats.totalPayloadUpload / downloadedBytes;

      final stop = policy.shouldStopSeeding(
            currentRatio: currentRatio,
            seedDuration: seedDuration,
            uploadedBytes: stats.totalPayloadUpload,
            isCharging: providerIsCharging,
            isOnWifi: providerIsOnWifi,
          ) ||
          TorrentService.shouldStopSeeding(
            progress: stats.progress,
            uploadedBytes: stats.totalPayloadUpload,
            downloadedBytes: downloadedBytes,
            shareRatioLimit: settings.shareRatioLimit,
            maxSeedingMinutes: settings.maxSeedingTimeMinutes,
            completedAt: task.completedAt,
          );

      if (stats.totalPayloadUpload >= 0 &&
          stats.totalPayloadUpload != task.uploadedBytes) {
        final idx = providerTasks.indexWhere((t) => t.id == task.id);
        if (idx != -1) {
          providerTasks[idx] = providerTasks[idx]
              .copyWith(uploadedBytes: stats.totalPayloadUpload);
        }
      }

      if (stop) {
        debugPrint(
          '[DownloadTorrentMixin] Task ${task.id} stopping seeding based on policy limits',
        );
        updateTaskSeeding(task.id, enabled: false);
      }
    }
  }

  void enforceTorrentQueue() {
    final settings = providerSettingsProvider;
    if (!settings.queueTorrents) return;

    final activeTorrents = providerTasks
        .where(
          (t) =>
              t.isTorrent &&
              (t.status == DownloadStatus.downloading ||
                  (t.status == DownloadStatus.completed && t.seedingEnabled)),
        )
        .toList();

    final activeDownloads = activeTorrents
        .where((t) => t.status == DownloadStatus.downloading)
        .length;
    final activeSeeds = activeTorrents
        .where((t) => t.status == DownloadStatus.completed && t.seedingEnabled)
        .length;

    if (activeDownloads > settings.maxActiveDownloads) {
      final toPause = activeTorrents
          .where((t) => t.status == DownloadStatus.downloading)
          .skip(settings.maxActiveDownloads);
      var pausedAny = false;
      for (final task in toPause) {
        final id = providerTorrentIds[task.id];
        if (id != null) {
          TorrentService.pauseTorrent(id);
          // Keep the DownloadTask model in sync with the engine: a queue-cap
          // pause must transition the task to paused, otherwise the UI keeps
          // showing "downloading" while nothing is transferring and a future
          // resume/pump has no consistent state to act on.
          final idx = providerTasks.indexWhere((t) => t.id == task.id);
          if (idx != -1) {
            providerTasks[idx] = providerTasks[idx].copyWith(
              status: DownloadStatus.paused,
              speed: 0,
              clearEta: true,
            );
            pausedAny = true;
            unawaited(
              providerDatabaseService
                  .saveTask(providerTasks[idx])
                  .catchError((_) {}),
            );
          }
        }
      }
      if (pausedAny) {
        filteredTasksDirty = true;
        providerNotifyListeners();
      }
    }

    if (activeSeeds > settings.maxActiveSeeds) {
      final toStopSeed = activeTorrents
          .where(
            (t) => t.status == DownloadStatus.completed && t.seedingEnabled,
          )
          .skip(settings.maxActiveSeeds);
      for (final task in toStopSeed) {
        updateTaskSeeding(task.id, enabled: false);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Advanced Torrent Controls: Web Seeds, Proxy, SSL
  // ---------------------------------------------------------------------------

  void addWebSeed(String url, int torrentId) {
    TorrentService.addWebSeed(torrentId, url);
    providerNotifyListeners();
  }

  void removeWebSeed(String url, int torrentId) {
    TorrentService.removeWebSeed(torrentId, url);
    providerNotifyListeners();
  }

  List<String> getWebSeeds(int torrentId) {
    return TorrentService.getWebSeeds(torrentId);
  }

  Future<void> applyProxySettings({
    required String host,
    required int port,
    required ProxyType type,
    String? username,
    String? password,
  }) async {
    await providerSettingsProvider.setProxySettings(
      host: host,
      port: port,
      type: type,
      username: username,
      password: password,
    );
    await TorrentService.setProxy(
      host: host,
      port: port,
      type: type,
      username: username,
      password: password,
    );
    TorrentService.reconfigureSession();
    providerNotifyListeners();
  }

  Future<void> applySslSettings({
    required String certPath,
    required String privateKeyPath,
    String? dhParamsPath,
  }) async {
    await providerSettingsProvider.setSslSettings(
      certPath: certPath,
      privateKeyPath: privateKeyPath,
      dhParamsPath: dhParamsPath,
    );
    await TorrentService.setSslCertificate(
      certPath: certPath,
      privateKeyPath: privateKeyPath,
      dhParamsPath: dhParamsPath,
    );
    TorrentService.reconfigureSession();
    providerNotifyListeners();
  }
}
