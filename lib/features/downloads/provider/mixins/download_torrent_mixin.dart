import 'package:flutter/foundation.dart';

import '../../../../core/services/torrent_service.dart';
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
mixin DownloadTorrentMixin {
  // ---------------------------------------------------------------------------
  // Abstract contract — must be provided by the host class
  // ---------------------------------------------------------------------------
  List<DownloadTask> get providerTasks;
  Map<String, int> get providerTorrentIds;
  Map<int, TorrentUpdateInfo> get providerLatestTorrentStats;
  SettingsProvider get providerSettingsProvider;
  DownloadTask? findTaskById(String id);

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
      providerTorrentIds[task.id] = torrentId;
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

    int selectedSize =
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
      for (final f in lowFiles) {
        final length = f['length'] as int;
        final share = lowSize > 0
            ? (remainingPhased * (length / lowSize)).round()
            : 0;
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

  /// Reads each torrent file's actual byte count from disk.
  Future<List<int>> getTorrentFileActualBytes(String taskId) async {
    final task = findTaskById(taskId);
    if (task == null || task.torrentFiles == null) return [];

    if (task.status == DownloadStatus.completed) {
      return task.torrentFiles!
          .map((f) => (f['length'] as int?) ?? 0)
          .toList();
    }

    final result = <int>[];
    for (final f in task.torrentFiles!) {
      final downloaded = (f['downloadedBytes'] as int?) ?? 0;
      result.add(downloaded);
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
}
