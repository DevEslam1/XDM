import 'dart:io';
import 'package:path/path.dart' as p;
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
  // Torrent file progress distribution
  // ---------------------------------------------------------------------------
  List<Map<String, dynamic>> updateTorrentFilesProgress(
    List<Map<String, dynamic>> files,
    int totalDownloaded,
    double totalSpeed,
  ) {
    final result = files.map((f) => Map<String, dynamic>.from(f)).toList();

    final selectedFiles =
        result.where((f) => f['selected'] == true).toList();
    if (selectedFiles.isEmpty) return result;

    final int selectedSize =
        selectedFiles.fold(0, (sum, f) => sum + (f['length'] as int));
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
    final highFiles = selectedFiles
        .where((f) => (f['priority'] as int? ?? 4) == 7)
        .toList();
    final normalFiles = selectedFiles
        .where((f) => (f['priority'] as int? ?? 4) == 4)
        .toList();
    final lowFiles = selectedFiles
        .where((f) => (f['priority'] as int? ?? 4) == 1)
        .toList();

    int remainingPhased = phasedTotal;
    final phasedShares = <String, int>{};
    for (final f in selectedFiles) {
      phasedShares[f['name'] as String] = 0;
    }

    // Phase 1: High priority
    if (highFiles.isNotEmpty) {
      final highSize =
          highFiles.fold(0, (sum, f) => sum + (f['length'] as int));
      if (remainingPhased <= highSize) {
        for (final f in highFiles) {
          final length = f['length'] as int;
          final share = highSize > 0
              ? (remainingPhased * (length / highSize)).round()
              : 0;
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
      final normalSize =
          normalFiles.fold(0, (sum, f) => sum + (f['length'] as int));
      if (remainingPhased <= normalSize) {
        for (final f in normalFiles) {
          final length = f['length'] as int;
          final share = normalSize > 0
              ? (remainingPhased * (length / normalSize)).round()
              : 0;
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
      final lowSize =
          lowFiles.fold(0, (sum, f) => sum + (f['length'] as int));
      if (remainingPhased <= lowSize) {
        for (final f in lowFiles) {
          final length = f['length'] as int;
          final share = lowSize > 0
              ? (remainingPhased * (length / lowSize)).round()
              : 0;
          phasedShares[f['name'] as String] = share.clamp(0, length);
        }
      } else {
        for (final f in lowFiles) {
          phasedShares[f['name'] as String] = f['length'] as int;
        }
      }
    }
    // If any bytes remain unassigned (all phases exhausted), distribute proportionally
    if (remainingPhased > 0 && selectedSize > 0) {
      for (final f in selectedFiles) {
        final name = f['name'] as String;
        final length = f['length'] as int;
        final current = phasedShares[name] ?? 0;
        final remaining = length - current;
        if (remaining > 0) {
          final share = (remainingPhased * (remaining / selectedSize)).round();
          phasedShares[name] = current + share.clamp(0, remaining);
        }
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

      final combined =
          (proportionalShares[name] ?? 0) + (phasedShares[name] ?? 0);
      final downloadedBytes = combined.clamp(0, length);
      f['downloadedBytes'] = downloadedBytes;

      f['speed'] = totalSpeed > 0 && downloadedBytes < length
          ? totalSpeed * (length / selectedSize)
          : 0.0;
    }

    return result;
  }

  /// Marks all selected torrent files as completed (downloadedBytes = length).
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

  /// Checks disk storage for existing torrent files and updates per-file downloadedBytes
  /// and total downloadedBytes to reflect real disk progress before continuing/resuming.
  List<Map<String, dynamic>> checkRealTorrentDiskProgress(DownloadTask task) {
    final files = task.torrentFiles;
    if (files == null || files.isEmpty) return files ?? [];
    final result = <Map<String, dynamic>>[];
    for (final f in files) {
      final copy = Map<String, dynamic>.from(f);
      final selected = copy['selected'] as bool? ?? true;
      final relPath = copy['name'] as String? ?? '';
      final length = (copy['length'] as num?)?.toInt() ?? 0;
      final stored = (copy['downloadedBytes'] as num?)?.toInt() ?? 0;
      if (!selected) { copy['downloadedBytes'] = 0; result.add(copy); continue; }
      int diskBytes = stored;
      if (relPath.isNotEmpty && length > 0) {
        try {
          final file = _locateTorrentFile(task, relPath);
          if (file != null) {
            final diskLen = file.lengthSync();
            // Trust on-disk size only while BELOW declared length (sparse files
            // report full logical size while partial). Completion is snapped to
            // 100% later by markTorrentFilesCompleted.
            if (diskLen > stored && diskLen < length) diskBytes = diskLen;
          }
        } catch (_) {}
      }
      copy['downloadedBytes'] = diskBytes;
      result.add(copy);
    }
    return result;
  }

  File? _locateTorrentFile(DownloadTask task, String relPath) {
    for (final candidate in <String>[
      p.normalize(p.join(task.localFilePath, relPath)), // multi-file: root folder
      p.normalize(p.join(task.savePath, relPath)),       // single-file: savePath/name
      task.localFilePath,                                 // single-file: path IS file
    ]) {
      try {
        final f = File(candidate);
        if (f.existsSync()) return f;
      } catch (_) {}
    }
    return null;
  }

  /// Returns each torrent file's confirmed downloaded byte count on disk.
  Future<List<int>> getTorrentFileActualBytes(String taskId) async {
    final task = findTaskById(taskId);
    if (task == null || task.torrentFiles == null) return [];

    final result = <int>[];
    final selectedFiles = task.torrentFiles!.where((f) => (f['selected'] as bool? ?? true)).toList();
    final totalSelectedSize = selectedFiles.fold(0, (sum, f) => sum + ((f['length'] as num?)?.toInt() ?? 0));
    final taskDownloaded = task.downloadedBytes;

    for (final f in task.torrentFiles!) {
      final relPath = f['name'] as String? ?? '';
      final length = (f['length'] as int?) ?? 0;
      final downloaded = (f['downloadedBytes'] as int?) ?? 0;

      int diskBytes = downloaded;
      if (relPath.isNotEmpty && length > 0) {
        try {
          final file = _locateTorrentFile(task, relPath);
          if (file != null) {
            final diskLen = file.lengthSync();
            // Only trust diskLen when file is clearly smaller than full size
            // (partial download). Sparse files report full logical size even
            // when only partially written, so we preserve stored estimate.
            if (diskLen > diskBytes && diskLen < length) {
              diskBytes = diskLen;
            }
          } else {
            diskBytes = 0;
          }
        } catch (_) {}
      }

      if (diskBytes > 0) {
        result.add(diskBytes.clamp(0, length > 0 ? length : diskBytes));
      } else if (taskDownloaded > 0 && totalSelectedSize > 0 && (f['selected'] as bool? ?? true) && length > 0) {
        final estimated = ((taskDownloaded * (length / totalSelectedSize))).round().clamp(0, length);
        result.add(estimated);
      } else {
        result.add(0);
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Upload limit management
  // ---------------------------------------------------------------------------
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
