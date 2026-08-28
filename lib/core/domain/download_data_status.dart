import 'package:flutter/foundation.dart';
import '../utils/file_utils.dart';

/// Sealed hierarchy of data progress statuses across all download engines.
@immutable
sealed class DataStatus {
  const DataStatus();
}

/// Download status snapshot for a torrent task.
@immutable
class TorrentDataStatus extends DataStatus {
  final int totalWanted;
  final int totalWantedDone;
  final double progress;
  final bool hasMetadata;
  final int? numSeeds;
  final int? numPeers;
  final int? numComplete;
  final int? numIncomplete;
  final String state;
  final int piecesTotal;
  final int piecesDone;
  final double distributedCopies;
  final int activeTime;
  final int seedingTime;
  final bool piecesEstimated;

  const TorrentDataStatus({
    required this.totalWanted,
    required this.totalWantedDone,
    required this.progress,
    required this.hasMetadata,
    this.numSeeds,
    this.numPeers,
    this.numComplete,
    this.numIncomplete,
    required this.state,
    this.piecesTotal = 0,
    this.piecesDone = 0,
    this.distributedCopies = 0.0,
    this.activeTime = 0,
    this.seedingTime = 0,
    this.piecesEstimated = true,
  });

  bool get sizeKnown => hasMetadata && totalWanted > 0;
  bool get isChecking => state.toLowerCase().contains('checking');
  bool get isFetchingMetadata =>
      (state.toLowerCase().contains('metadata') ||
          state.toLowerCase().contains('getting')) &&
      !hasMetadata;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TorrentDataStatus &&
          totalWanted == other.totalWanted &&
          totalWantedDone == other.totalWantedDone &&
          progress == other.progress &&
          hasMetadata == other.hasMetadata &&
          numSeeds == other.numSeeds &&
          numPeers == other.numPeers &&
          numComplete == other.numComplete &&
          numIncomplete == other.numIncomplete &&
          state == other.state &&
          piecesTotal == other.piecesTotal &&
          piecesDone == other.piecesDone &&
          distributedCopies == other.distributedCopies &&
          activeTime == other.activeTime &&
          seedingTime == other.seedingTime &&
          piecesEstimated == other.piecesEstimated;

  @override
  int get hashCode => Object.hash(
        totalWanted,
        totalWantedDone,
        progress,
        hasMetadata,
        numSeeds,
        numPeers,
        numComplete,
        numIncomplete,
        state,
        piecesTotal,
        piecesDone,
        distributedCopies,
        activeTime,
        seedingTime,
        piecesEstimated,
      );
}

/// Download status snapshot for an HTTP multipart segment.
@immutable
class HttpPartStatus extends DataStatus {
  final int partIndex;
  final int startByte;
  final int endByte;
  final int downloadedBytes;

  const HttpPartStatus({
    required this.partIndex,
    required this.startByte,
    required this.endByte,
    required this.downloadedBytes,
  });

  int get totalBytes =>
      (endByte >= startByte && endByte > 0) ? (endByte - startByte + 1) : 0;

  double get progress =>
      totalBytes > 0 ? (downloadedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HttpPartStatus &&
          partIndex == other.partIndex &&
          startByte == other.startByte &&
          endByte == other.endByte &&
          downloadedBytes == other.downloadedBytes;

  @override
  int get hashCode =>
      Object.hash(partIndex, startByte, endByte, downloadedBytes);
}

/// Download status snapshot for a YouTube stream component (video, audio, or muxed).
@immutable
class YtStreamStatus extends DataStatus {
  final String streamType; // 'video' | 'audio' | 'muxed'
  final int downloadedBytes;
  final int totalBytes;
  final double progress;

  const YtStreamStatus({
    required this.streamType,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.progress,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is YtStreamStatus &&
          streamType == other.streamType &&
          downloadedBytes == other.downloadedBytes &&
          totalBytes == other.totalBytes &&
          progress == other.progress;

  @override
  int get hashCode =>
      Object.hash(streamType, downloadedBytes, totalBytes, progress);
}

/// File-level status for multi-file torrent downloads.
@immutable
class TorrentFileStatus extends DataStatus {
  final int fileIndex;
  final String name;
  final int size;
  final int downloadedBytes;
  final int priority;
  final bool selected;
  final bool progressEstimated;

  const TorrentFileStatus({
    required this.fileIndex,
    required this.name,
    required this.size,
    required this.downloadedBytes,
    required this.priority,
    required this.selected,
    this.progressEstimated = false,
  });

  double get progress =>
      size > 0 ? (downloadedBytes / size).clamp(0.0, 1.0) : 0.0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TorrentFileStatus &&
          fileIndex == other.fileIndex &&
          name == other.name &&
          size == other.size &&
          downloadedBytes == other.downloadedBytes &&
          priority == other.priority &&
          selected == other.selected &&
          progressEstimated == other.progressEstimated;

  @override
  int get hashCode => Object.hash(fileIndex, name, size, downloadedBytes,
      priority, selected, progressEstimated);
}

/// Formats downloaded / total size into human-readable label.
/// Returns '— / —' when total size is unknown or non-positive.
String sizeProgressLabel({
  required int received,
  required int total,
  String Function(num bytes)? formatBytesFn,
}) {
  if (total <= 0) return '— / —';
  final fmt = formatBytesFn ?? formatBytes;
  return '${fmt(received)} / ${fmt(total)}';
}

/// Formats seed count into 'connected (in swarm)' or 'connected' or '—'.
String seedsLabel({int? connected, int? totalInSwarm}) {
  if (connected == null || connected < 0) {
    if (totalInSwarm != null && totalInSwarm >= 0) {
      return '0 ($totalInSwarm)';
    }
    return '—';
  }
  if (totalInSwarm != null && totalInSwarm > 0) {
    return '$connected ($totalInSwarm)';
  }
  return '$connected';
}

/// Formats peer count into 'connected (in swarm)' or 'connected' or '—'.
String peersLabel({int? connected, int? totalInSwarm}) {
  if (connected == null || connected < 0) {
    if (totalInSwarm != null && totalInSwarm >= 0) {
      return '0 ($totalInSwarm)';
    }
    return '—';
  }
  if (totalInSwarm != null && totalInSwarm > 0) {
    return '$connected ($totalInSwarm)';
  }
  return '$connected';
}
