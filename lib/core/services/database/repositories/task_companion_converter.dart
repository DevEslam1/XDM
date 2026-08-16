import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart';
import '../../../../features/downloads/models/download_task.dart';
import '../../crash_reporting_service.dart';
import '../app_database.dart';

class TaskCompanionConverter {
  static DownloadTasksCompanion taskToCompanion(DownloadTask task) {
    return DownloadTasksCompanion.insert(
      id: task.id,
      fileName: task.fileName,
      url: task.url,
      fileSize: drift.Value(task.fileSize),
      downloadedBytes: drift.Value(task.downloadedBytes),
      speed: drift.Value(task.speed),
      eta: drift.Value(task.eta),
      category: task.category,
      status: task.status.name,
      savePath: task.savePath,
      localFilePath: task.localFilePath,
      tempFilePath: task.tempFilePath,
      errorMessage: drift.Value(task.errorMessage),
      threadCount: task.threadCount,
      chunks: drift.Value(task.chunks),
      createdAt: task.createdAt.millisecondsSinceEpoch,
      updatedAt: task.updatedAt.millisecondsSinceEpoch,
      completedAt: drift.Value(task.completedAt?.millisecondsSinceEpoch),
      scheduledAt: drift.Value(task.scheduledAt?.millisecondsSinceEpoch),
      supportsResume: drift.Value(task.supportsResume),
      speedLimitKbps: drift.Value(task.speedLimitKbps),
      seedingEnabled: drift.Value(task.seedingEnabled),
      seedingLimited: drift.Value(task.seedingLimited),
      seedingLimitKbps: drift.Value(task.seedingLimitKbps),
      torrentFiles: drift.Value(task.torrentFiles),
      downloadPageUrl: drift.Value(task.downloadPageUrl),
      mergedAudioUrl: drift.Value(task.mergedAudioUrl),
      audioSize: drift.Value(task.audioSize),
      audioDownloadedBytes: drift.Value(task.audioDownloadedBytes),
      videoStreamSize: drift.Value(task.videoStreamSize),
      audioProgress: drift.Value(task.audioProgress),
      pausedByUser: drift.Value(task.pausedByUser),
      youtubeQualityPreset: drift.Value(task.youtubeQualityPreset),
      notes: drift.Value(task.notes),
      playlistId: drift.Value(task.playlistId),
      playlistTitle: drift.Value(task.playlistTitle),
      thumbnailUrl: drift.Value(task.thumbnailUrl),
      isAppUpdate: drift.Value(task.isAppUpdate),
      uploadedBytes: drift.Value(task.uploadedBytes),
      priority: drift.Value(task.priority),
      expectedSha256: drift.Value(task.expectedSha256),
      mirrorUrls: drift.Value(task.mirrorUrls),
      pauseReason: drift.Value(task.pauseReason?.name),
      totalPieces: drift.Value(task.totalPieces),
      completedPieces: drift.Value(task.completedPieces),
      ytCounterpartDownloadedBytes:
          drift.Value(task.ytCounterpartDownloadedBytes),
      cycleState: drift.Value(task.cycleState?.name),
    );
  }

  static DownloadTask rowToTask(DbDownloadTask row) {
    DateTime parseIntDate(int msSinceEpoch) {
      try {
        return DateTime.fromMillisecondsSinceEpoch(msSinceEpoch);
      } catch (e) {
        debugPrint(
          '[DMX] Error parsing date millisecondsSinceEpoch $msSinceEpoch: $e',
        );
        return DateTime.fromMillisecondsSinceEpoch(0);
      }
    }

    DateTime? parseNullableIntDate(int? msSinceEpoch) {
      if (msSinceEpoch == null) return null;
      try {
        return DateTime.fromMillisecondsSinceEpoch(msSinceEpoch);
      } catch (e) {
        debugPrint(
          '[DMX] Error parsing nullable date millisecondsSinceEpoch $msSinceEpoch: $e',
        );
        return null;
      }
    }

    final statusName = row.status;
    final parsedStatus = DownloadStatus.values.firstWhere(
      (value) => value.name == statusName,
      orElse: () {
        debugPrint(
          '[DMX] _rowToTask: unrecognised status "$statusName" for task '
          '${row.id} — reporting and defaulting to paused.',
        );
        CrashReportingService.recordError(
          FormatException('Unrecognised download task status: "$statusName"'),
          StackTrace.current,
          hint: 'recoverable',
        );
        return DownloadStatus.paused;
      },
    );

    final rawCycleState =
        row.cycleState != null ? CycleState.fromName(row.cycleState) : null;
    final rawPauseReason =
        row.pauseReason != null ? PauseReason.fromName(row.pauseReason) : null;

    final isInterruptedActive = parsedStatus == DownloadStatus.downloading ||
        rawCycleState == CycleState.starting ||
        rawCycleState == CycleState.resuming ||
        rawCycleState == CycleState.retrying ||
        rawCycleState == CycleState.fetchingMetadata ||
        rawCycleState == CycleState.merging ||
        rawCycleState == CycleState.verifying ||
        rawCycleState == CycleState.updatingLinks ||
        rawCycleState == CycleState.allocating ||
        rawCycleState == CycleState.stalled;

    final isUpdatingLinks = rawCycleState == CycleState.updatingLinks;
    final status = isInterruptedActive ? DownloadStatus.paused : parsedStatus;
    final cycleState = isInterruptedActive ? CycleState.paused : rawCycleState;
    final pauseReason = isUpdatingLinks
        ? PauseReason.urlExpired
        : (isInterruptedActive ? PauseReason.appRestarted : rawPauseReason);
    final previousCycleState = isInterruptedActive ? rawCycleState : null;

    final files = row.torrentFiles;
    int totalFiles = 0;
    int completedFiles = 0;
    int totalFileBytes = 0;
    int downloadedFileBytes = 0;
    if (files != null && files.isNotEmpty) {
      for (final f in files) {
        final selected = (f['selected'] as bool?) ?? true;
        if (!selected) continue;
        final len = (f['length'] as num?)?.toInt() ?? 0;
        final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        totalFiles++;
        totalFileBytes += len;
        if (len == 0 || dl >= len) {
          completedFiles++;
        }
        downloadedFileBytes += len > 0 ? dl.clamp(0, len) : 0;
      }
    }

    return DownloadTask(
      id: row.id,
      fileName: row.fileName,
      url: row.url,
      fileSize: row.fileSize,
      downloadedBytes: row.downloadedBytes,
      speed: row.speed,
      eta: row.eta,
      category: row.category,
      status: status,
      savePath: row.savePath,
      localFilePath: row.localFilePath,
      tempFilePath: row.tempFilePath,
      errorMessage: row.errorMessage,
      threadCount: row.threadCount,
      chunks: row.chunks ?? [],
      createdAt: parseIntDate(row.createdAt),
      updatedAt: parseIntDate(row.updatedAt),
      completedAt: parseNullableIntDate(row.completedAt),
      scheduledAt: parseNullableIntDate(row.scheduledAt),
      supportsResume: row.supportsResume,
      speedLimitKbps: row.speedLimitKbps,
      seedingEnabled: row.seedingEnabled,
      seedingLimited: row.seedingLimited,
      seedingLimitKbps: row.seedingLimitKbps,
      torrentFiles: row.torrentFiles,
      downloadPageUrl: row.downloadPageUrl,
      mergedAudioUrl: row.mergedAudioUrl,
      audioSize: row.audioSize,
      audioDownloadedBytes: row.audioDownloadedBytes,
      videoStreamSize: row.videoStreamSize,
      audioProgress: row.audioProgress,
      pausedByUser: row.pausedByUser,
      youtubeQualityPreset: row.youtubeQualityPreset,
      notes: row.notes,
      playlistId: row.playlistId?.isNotEmpty == true ? row.playlistId : null,
      playlistTitle:
          row.playlistTitle?.isNotEmpty == true ? row.playlistTitle : null,
      thumbnailUrl: row.thumbnailUrl,
      isAppUpdate: row.isAppUpdate,
      uploadedBytes: row.uploadedBytes,
      priority: row.priority,
      expectedSha256: row.expectedSha256,
      mirrorUrls: row.mirrorUrls,
      pauseReason: pauseReason,
      totalPieces: row.totalPieces,
      completedPieces: row.completedPieces,
      ytCounterpartDownloadedBytes: row.ytCounterpartDownloadedBytes,
      cycleState: cycleState,
      previousCycleState: previousCycleState,
      totalFiles: files != null && files.isNotEmpty ? totalFiles : null,
      completedFiles:
          files != null && files.isNotEmpty ? completedFiles : null,
      totalFileBytes:
          files != null && files.isNotEmpty ? totalFileBytes : null,
      downloadedFileBytes:
          files != null && files.isNotEmpty ? downloadedFileBytes : null,
    );
  }
}
