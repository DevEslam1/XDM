import 'package:flutter/foundation.dart';
import '../../features/downloads/models/download_task.dart';
import 'logging_service.dart';

// FIX 5.1: DataStatusVerifier utility class and data status models

final _log = LoggingService.logger('DataStatusVerifier');

@immutable
class HttpPartDataStatus {
  final int partIndex;
  final int startByte;
  final int endByte;
  final int downloadedBytes;
  final bool isComplete;

  const HttpPartDataStatus({
    required this.partIndex,
    required this.startByte,
    required this.endByte,
    required this.downloadedBytes,
    required this.isComplete,
  });
}

@immutable
class HttpDataStatus {
  final double overallPercent;
  final int totalParts;
  final int completedParts;
  final int totalBytes;
  final int downloadedBytes;
  final List<HttpPartDataStatus> parts;
  final bool isConsistent; // chunks sum == downloadedBytes
  final List<String> inconsistencies;

  const HttpDataStatus({
    required this.overallPercent,
    required this.totalParts,
    required this.completedParts,
    required this.totalBytes,
    required this.downloadedBytes,
    required this.parts,
    required this.isConsistent,
    required this.inconsistencies,
  });
}

@immutable
class YtDataStatus {
  final double overallPercent;
  final double videoPercent;
  final double audioPercent;
  final int videoDownloadedBytes;
  final int audioDownloadedBytes;
  final int videoTotalBytes;
  final int audioTotalBytes;
  final int videoCompletedChunks;
  final int videoTotalChunks;
  final int audioCompletedChunks;
  final int audioTotalChunks;
  final bool isConsistent;
  final List<String> inconsistencies;

  const YtDataStatus({
    required this.overallPercent,
    required this.videoPercent,
    required this.audioPercent,
    required this.videoDownloadedBytes,
    required this.audioDownloadedBytes,
    required this.videoTotalBytes,
    required this.audioTotalBytes,
    required this.videoCompletedChunks,
    required this.videoTotalChunks,
    required this.audioCompletedChunks,
    required this.audioTotalChunks,
    required this.isConsistent,
    required this.inconsistencies,
  });
}

@immutable
class TorrentFileDataStatus {
  final String fileName;
  final int downloadedBytes;
  final int totalBytes;
  final double percent;
  final bool isComplete;

  const TorrentFileDataStatus({
    required this.fileName,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.percent,
    required this.isComplete,
  });
}

@immutable
class TorrentDataStatus {
  final double overallPercent;
  final double piecePercent;
  final int totalFiles;
  final int completedFiles;
  final int totalBytes;
  final int downloadedBytes;
  final int totalPieces;
  final int completedPieces;
  final List<TorrentFileDataStatus> files;
  final bool isConsistent;
  final List<String> inconsistencies;

  const TorrentDataStatus({
    required this.overallPercent,
    required this.piecePercent,
    required this.totalFiles,
    required this.completedFiles,
    required this.totalBytes,
    required this.downloadedBytes,
    required this.totalPieces,
    required this.completedPieces,
    required this.files,
    required this.isConsistent,
    required this.inconsistencies,
  });
}

@immutable
class TaskDataStatus {
  final String taskId;
  final String transportType;
  final bool isConsistent;
  final List<String> inconsistencies;
  final HttpDataStatus? httpStatus;
  final YtDataStatus? ytStatus;
  final TorrentDataStatus? torrentStatus;

  const TaskDataStatus({
    required this.taskId,
    required this.transportType,
    required this.isConsistent,
    required this.inconsistencies,
    this.httpStatus,
    this.ytStatus,
    this.torrentStatus,
  });
}

class DataStatusVerifier {
  /// Verify HTTP task data at all levels
  static HttpDataStatus verifyHttpTask(DownloadTask task) {
    final inconsistencies = <String>[];
    final totalBytes = task.resolvedFileSize;
    final downloadedBytes = task.downloadedBytes;
    final overallPercent = task.progress >= 0 ? task.progress : 0.0;

    final parts = <HttpPartDataStatus>[];
    int chunkBytesSum = 0;
    int completedPartsCount = 0;

    if (task.httpParts != null && task.httpParts!.isNotEmpty) {
      for (final p in task.httpParts!) {
        parts.add(HttpPartDataStatus(
          partIndex: p.partIndex,
          startByte: p.startByte,
          endByte: p.endByte,
          downloadedBytes: p.downloadedBytes,
          isComplete: p.isComplete,
        ));
        chunkBytesSum += p.downloadedBytes;
        if (p.isComplete) completedPartsCount++;
      }
    } else if (task.chunks.isNotEmpty) {
      final threadCount = task.threadCount > 0 ? task.threadCount : task.chunks.length;
      final perChunkSize = totalBytes > 0 ? (totalBytes / threadCount).ceil() : 0;
      for (int i = 0; i < task.chunks.length; i++) {
        final ratio = task.chunks[i].clamp(0.0, 1.0);
        final start = i * perChunkSize;
        final end = (i == task.chunks.length - 1) ? totalBytes - 1 : (i + 1) * perChunkSize - 1;
        final size = end >= start ? (end - start + 1) : 0;
        final dl = (ratio * size).round();
        final complete = ratio >= 1.0 || (size > 0 && dl >= size);
        parts.add(HttpPartDataStatus(
          partIndex: i,
          startByte: start,
          endByte: end,
          downloadedBytes: dl,
          isComplete: complete,
        ));
        chunkBytesSum += dl;
        if (complete) completedPartsCount++;
      }
    }

    if (downloadedBytes < 0) {
      inconsistencies.add('downloadedBytes ($downloadedBytes) cannot be negative');
    }
    if (totalBytes > 0 && downloadedBytes > totalBytes) {
      inconsistencies.add('downloadedBytes ($downloadedBytes) exceeds totalBytes ($totalBytes)');
    }
    if (task.httpParts != null && task.httpParts!.isNotEmpty && totalBytes > 0) {
      if ((chunkBytesSum - downloadedBytes).abs() > 1024 * 64 && downloadedBytes > 0) {
        inconsistencies.add('Sum of chunk downloaded bytes ($chunkBytesSum) does not match task downloadedBytes ($downloadedBytes)');
      }
    }

    final isConsistent = inconsistencies.isEmpty;
    return HttpDataStatus(
      overallPercent: overallPercent.clamp(0.0, 1.0),
      totalParts: parts.length,
      completedParts: completedPartsCount,
      totalBytes: totalBytes,
      downloadedBytes: downloadedBytes,
      parts: parts,
      isConsistent: isConsistent,
      inconsistencies: inconsistencies,
    );
  }

  /// Verify YouTube task data at all levels
  static YtDataStatus verifyYtTask(DownloadTask task) {
    final inconsistencies = <String>[];
    final videoTotalBytes = task.videoStreamSize > 0
        ? task.videoStreamSize
        : (task.fileSize > task.audioSize && task.audioSize > 0
            ? task.fileSize - task.audioSize
            : task.fileSize);
    final audioTotalBytes = task.audioSize;
    final videoDownloaded = task.downloadedBytes;
    final audioDownloaded = task.audioDownloadedBytes;

    final videoPercent = videoTotalBytes > 0
        ? (videoDownloaded / videoTotalBytes).clamp(0.0, 1.0)
        : 0.0;
    final audioPercent = audioTotalBytes > 0
        ? (audioDownloaded / audioTotalBytes).clamp(0.0, 1.0)
        : task.audioProgress.clamp(0.0, 1.0);

    final combinedTotal = (videoTotalBytes > 0 ? videoTotalBytes : 0) + (audioTotalBytes > 0 ? audioTotalBytes : 0);
    final combinedDl = videoDownloaded + audioDownloaded;
    final overallPercent = combinedTotal > 0
        ? (combinedDl / combinedTotal).clamp(0.0, 1.0)
        : (task.progress >= 0 ? task.progress : 0.0);

    final videoCompletedChunks = task.chunks.where((c) => c >= 1.0).length;
    final videoTotalChunks = task.chunks.length;
    final audioCompletedChunks = task.audioChunks.where((c) => c >= 1.0).length;
    final audioTotalChunks = task.audioChunks.length;

    if (videoDownloaded < 0) {
      inconsistencies.add('videoDownloadedBytes ($videoDownloaded) cannot be negative');
    }
    if (audioDownloaded < 0) {
      inconsistencies.add('audioDownloadedBytes ($audioDownloaded) cannot be negative');
    }
    if (videoTotalBytes > 0 && videoDownloaded > videoTotalBytes) {
      inconsistencies.add('videoDownloaded ($videoDownloaded) exceeds videoTotal ($videoTotalBytes)');
    }
    if (audioTotalBytes > 0 && audioDownloaded > audioTotalBytes) {
      inconsistencies.add('audioDownloaded ($audioDownloaded) exceeds audioTotal ($audioTotalBytes)');
    }

    final isConsistent = inconsistencies.isEmpty;
    return YtDataStatus(
      overallPercent: overallPercent.clamp(0.0, 1.0),
      videoPercent: videoPercent,
      audioPercent: audioPercent,
      videoDownloadedBytes: videoDownloaded,
      audioDownloadedBytes: audioDownloaded,
      videoTotalBytes: videoTotalBytes,
      audioTotalBytes: audioTotalBytes,
      videoCompletedChunks: videoCompletedChunks,
      videoTotalChunks: videoTotalChunks,
      audioCompletedChunks: audioCompletedChunks,
      audioTotalChunks: audioTotalChunks,
      isConsistent: isConsistent,
      inconsistencies: inconsistencies,
    );
  }

  /// Verify Torrent task data at all levels
  static TorrentDataStatus verifyTorrentTask(DownloadTask task) {
    final inconsistencies = <String>[];
    final files = <TorrentFileDataStatus>[];
    int totalBytes = 0;
    int downloadedBytes = 0;
    int completedFiles = 0;

    if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
      for (final f in task.torrentFiles!) {
        final name = (f['name'] as String?) ?? 'file';
        final len = (f['length'] as num?)?.toInt() ?? 0;
        final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        final selected = (f['selected'] as bool?) ?? true;
        if (selected) {
          totalBytes += len;
          downloadedBytes += dl.clamp(0, len > 0 ? len : dl);
        }
        final percent = len > 0 ? (dl / len).clamp(0.0, 1.0) : 0.0;
        final isComplete = len > 0 ? dl >= len : false;
        if (isComplete && selected) completedFiles++;

        files.add(TorrentFileDataStatus(
          fileName: name,
          downloadedBytes: dl,
          totalBytes: len,
          percent: percent,
          isComplete: isComplete,
        ));
      }
    } else {
      totalBytes = task.resolvedFileSize;
      downloadedBytes = task.downloadedBytes;
    }

    final totalPieces = task.totalPieces ?? 0;
    final completedPieces = task.completedPieces ?? 0;
    final piecePercent = totalPieces > 0
        ? (completedPieces / totalPieces).clamp(0.0, 1.0)
        : (task.torrentPieceProgress ?? 0.0).clamp(0.0, 1.0);

    final overallPercent = totalBytes > 0
        ? (downloadedBytes / totalBytes).clamp(0.0, 1.0)
        : (task.progress >= 0 ? task.progress : 0.0);

    if (task.torrentFiles != null && task.torrentFiles!.isNotEmpty) {
      if ((downloadedBytes - task.downloadedBytes).abs() > 1024 * 1024 && task.downloadedBytes > 0) {
        inconsistencies.add('Sum of torrent file bytes ($downloadedBytes) does not match task.downloadedBytes (${task.downloadedBytes})');
      }
    }
    if (completedPieces > totalPieces && totalPieces > 0) {
      inconsistencies.add('completedPieces ($completedPieces) exceeds totalPieces ($totalPieces)');
    }

    final isConsistent = inconsistencies.isEmpty;
    return TorrentDataStatus(
      overallPercent: overallPercent.clamp(0.0, 1.0),
      piecePercent: piecePercent,
      totalFiles: files.isNotEmpty ? files.length : (task.totalFiles ?? 0),
      completedFiles: completedFiles > 0 ? completedFiles : (task.completedFiles ?? 0),
      totalBytes: totalBytes > 0 ? totalBytes : task.resolvedFileSize,
      downloadedBytes: downloadedBytes > 0 ? downloadedBytes : task.downloadedBytes,
      totalPieces: totalPieces,
      completedPieces: completedPieces,
      files: files,
      isConsistent: isConsistent,
      inconsistencies: inconsistencies,
    );
  }

  /// Verify any task based on its type
  static TaskDataStatus verifyTask(DownloadTask task) {
    if (task.isTorrent) {
      final tStatus = verifyTorrentTask(task);
      if (!tStatus.isConsistent) {
        _log.warning('[DataStatusVerifier] Inconsistencies for torrent task ${task.id}: ${tStatus.inconsistencies.join('; ')}');
      }
      return TaskDataStatus(
        taskId: task.id,
        transportType: 'torrent',
        isConsistent: tStatus.isConsistent,
        inconsistencies: tStatus.inconsistencies,
        torrentStatus: tStatus,
      );
    } else if (task.hasMergedAudio || task.audioSize > 0 || task.youtubeQualityPreset != null) {
      final ytStatus = verifyYtTask(task);
      if (!ytStatus.isConsistent) {
        _log.warning('[DataStatusVerifier] Inconsistencies for YouTube task ${task.id}: ${ytStatus.inconsistencies.join('; ')}');
      }
      return TaskDataStatus(
        taskId: task.id,
        transportType: 'youtube',
        isConsistent: ytStatus.isConsistent,
        inconsistencies: ytStatus.inconsistencies,
        ytStatus: ytStatus,
      );
    } else {
      final httpStatus = verifyHttpTask(task);
      if (!httpStatus.isConsistent) {
        _log.warning('[DataStatusVerifier] Inconsistencies for HTTP task ${task.id}: ${httpStatus.inconsistencies.join('; ')}');
      }
      return TaskDataStatus(
        taskId: task.id,
        transportType: 'http',
        isConsistent: httpStatus.isConsistent,
        inconsistencies: httpStatus.inconsistencies,
        httpStatus: httpStatus,
      );
    }
  }
}
