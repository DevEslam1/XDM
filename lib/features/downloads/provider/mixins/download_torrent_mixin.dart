import 'package:flutter/foundation.dart';

import '../../../../core/services/torrent_service.dart';
import '../../../../core/services/database_service.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../features/settings/provider/settings_provider.dart';
import '../../models/download_task.dart';

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

  // ---------------------------------------------------------------------------
  // Seeding lifecycle
  // ---------------------------------------------------------------------------
  void startSeedingTorrent(DownloadTask task) {
    if (providerTorrentIds.containsKey(task.id)) return;
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
      if (torrentId < 0) return;
      providerTorrentIds[task.id] = torrentId;
      TorrentService.resumeTorrent(torrentId);

      if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
        final fileCount = TorrentService.getFileCount(torrentId);
        if (fileCount == task.torrentFiles!.length) {
          final priorities = task.torrentFiles!
              .map((f) {
                final selected = f['selected'] as bool? ?? true;
                if (!selected) return 0;
                return f['priority'] as int? ?? 4;
              })
              .toList();
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
      '${_formatBytes(currentUploadSpeed)}/s';

  int get seedingTasksCount => providerTasks
      .where(
        (task) =>
            task.status == DownloadStatus.completed &&
            task.isTorrent &&
            task.seedingEnabled,
      )
      .length;

  // ---------------------------------------------------------------------------
  // Torrent stat queries
  // ---------------------------------------------------------------------------
  int getTorrentSeeds(String taskId) {
    final torrentId = providerTorrentIds[taskId];
    if (torrentId != null) {
      final stat = providerLatestTorrentStats[torrentId];
      if (stat != null) {
        return stat.numSeeds;
      }
    }
    return 0;
  }

  int getTorrentPeers(String taskId) {
    final torrentId = providerTorrentIds[taskId];
    if (torrentId != null) {
      final stat = providerLatestTorrentStats[torrentId];
      if (stat != null) {
        return stat.numPeers;
      }
    }
    return 0;
  }

  double getTorrentUploadSpeed(String taskId) {
    final task = findTaskById(taskId);
    if (task == null || !task.seedingEnabled) {
      return 0.0;
    }
    final torrentId = providerTorrentIds[taskId];
    if (torrentId != null) {
      final stat = providerLatestTorrentStats[torrentId];
      if (stat != null) {
        return stat.uploadRate.toDouble();
      }
    }
    return 0.0;
  }

  // ---------------------------------------------------------------------------
  // Torrent file progress — native getFileProgress provides exact per-file bytes
  // ---------------------------------------------------------------------------
  List<Map<String, dynamic>> markTorrentFilesCompleted(
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

  // ---------------------------------------------------------------------------
  // Upload limit management
  // ---------------------------------------------------------------------------

  /// Returns each torrent file's confirmed downloaded byte count using native
  /// getFileProgress from the engine.
  Future<List<int>> getTorrentFileActualBytes(String taskId) async {
    final task = findTaskById(taskId);
    if (task == null || task.torrentFiles == null) return [];

    final torrentId = providerTorrentIds[taskId];
    if (torrentId == null) return [];

    try {
      final files = TorrentService.getFiles(torrentId);
      return files.map((f) => f.downloadedBytes).toList();
    } catch (_) {
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
    for (final taskId in providerTorrentIds.keys) {
      final task = findTaskById(taskId);
      if (task != null && task.seedingEnabled) {
        anySeedingEnabled = true;
        break;
      }
    }

    if (anySeedingEnabled) {
      int? minLimitBytes;
      for (final taskId in providerTorrentIds.keys) {
        final task = findTaskById(taskId);
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
      } else if (providerSettingsProvider.globalTorrentSeedingLimited) {
        final limitBytes =
            (providerSettingsProvider.globalTorrentSeedingLimitKbps * 1000) ~/
                8;
        TorrentService.setUploadLimit(limitBytes > 0 ? limitBytes : 0);
      } else {
        TorrentService.setUploadLimit(0); // Unlimited
      }
    } else {
      TorrentService.setUploadLimit(0); // Effectively 0
    }
  }

  // ---------------------------------------------------------------------------
  // Seeding speed sync
  // ---------------------------------------------------------------------------
  /// Updates the in-memory `speed` field on all seeding tasks from live
  /// torrent stats. Returns `true` if any task was modified.
  bool updateSeedingSpeeds() {
    var changed = false;
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

        if (task.seedingEnabled && task.completedAt != null) {
          final maxMinutes = TorrentService.maxSeedingTimeMinutes;
          bool shouldStopSeeding = false;

          if (maxMinutes > 0) {
            final seedingDuration =
                DateTime.now().difference(task.completedAt!);
            if (seedingDuration.inMinutes >= maxMinutes) {
              shouldStopSeeding = true;
            }
          }

          if (shouldStopSeeding) {
            if (torrentId != null) {
              TorrentService.pauseTorrent(torrentId);
              providerTorrentIds.remove(task.id);
            }
            providerTasks[i] = task.copyWith(seedingEnabled: false);
            changed = true;
          }
        }
      } else if (task.speed > 0 &&
          task.status == DownloadStatus.completed) {
        providerTasks[i] = task.copyWith(speed: 0);
        changed = true;
      }
    }
    return changed;
  }

  // ---------------------------------------------------------------------------
  // Helpers (private to mixin)
  // ---------------------------------------------------------------------------
  /// Minimal bytes formatter — avoids importing file_utils into this mixin.
  String _formatBytes(double bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    int i = 0;
    double size = bytes;
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(i == 0 ? 0 : 1)} ${suffixes[i]}';
  }

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
    );
    filteredTasksDirty = true;
    await providerDatabaseService.saveTask(providerTasks[index]);

    if (oldTask.isTorrent) {
      final torrentId = providerTorrentIds[taskId];
      if (newEnabled) {
        if (torrentId != null) {
          TorrentService.resumeTorrent(torrentId);
        } else {
          startSeedingTorrent(providerTasks[index]);
        }
      } else {
        // Only pause/remove the torrent session if the task has already
        // finished downloading (status == completed).  Calling pauseTorrent
        // while still downloading would abort the in-progress transfer.
        if (torrentId != null && oldTask.status == DownloadStatus.completed) {
          TorrentService.pauseTorrent(torrentId);
          providerTorrentIds.remove(taskId);
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

    // Calculate new total size of selected files
    final selectedSize = files
        .where((f) => f['selected'] == true)
        .fold(0, (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0));

    String updatedCategory = task.category;
    if (task.category == 'Other' || task.category.isEmpty) {
      final selectedFiles = files.where((f) => f['selected'] == true).toList();
      final sample = selectedFiles.isNotEmpty ? selectedFiles.first : (files.isNotEmpty ? files.first : null);
      if (sample != null) {
        final fileName = (sample['name'] as String? ?? '').replaceAll('+', ' ');
        final cat = categoryFromFileName(fileName);
        if (cat != 'Other') {
          updatedCategory = cat;
        }
      }
    }

    final updated = task.copyWith(
      torrentFiles: files,
      fileSize: selectedSize > 0 ? selectedSize : task.fileSize,
      category: updatedCategory,
    );

    providerTasks[index] = updated;
    filteredTasksDirty = true;
    await providerDatabaseService.saveTask(updated);

    // Propagate priority changes to the live torrent engine.
    final torrentId = providerTorrentIds[taskId];
    if (torrentId != null) {
      final priorities = files.map((f) {
        final selected = f['selected'] as bool? ?? true;
        if (!selected) return 0;
        return f['priority'] as int? ?? 4;
      }).toList();
      TorrentService.setFilePriorities(torrentId, priorities);
    }

    providerNotifyListeners();
  }
}
