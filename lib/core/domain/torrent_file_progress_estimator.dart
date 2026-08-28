import 'dart:math' as math;

import '../services/engine/torrent_file_normalizer.dart';

/// Pure domain utility for calculating, estimating, and reconciling
/// per-file progress within BitTorrent transfers.
class TorrentFileProgressEstimator {
  const TorrentFileProgressEstimator._();

  static double priorityWeight(int priority) {
    if (priority <= 0) return 0.0;
    if (priority == 4) return 1.0;
    if (priority >= 7) return 1.5;
    return 1.0 + ((priority - 4) / 6.0);
  }

  /// Updates a list of file maps using native aggregate progress and total downloaded bytes.
  static void updateFilesWithNativeProgress(
    List<Map<String, dynamic>> files,
    double progress,
    int totalDownloadedBytes, {
    bool sequential = false,
  }) {
    if (files.isEmpty) return;
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      if (!TorrentFileNormalizer.isTorrentFileSelected(f)) {
        f['downloadedBytes'] = 0;
        f['progress'] = 0.0;
        f['isComplete'] = false;
        f['progressEstimated'] = false;
        continue;
      }
      final len = (f['length'] as num?)?.toInt() ?? 0;
      if (len <= 0) {
        f['downloadedBytes'] = 0;
        f['progress'] = 0.0;
        f['isComplete'] = false;
        f['progressEstimated'] = true;
        continue;
      }
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? -1;
      if (dl > 0 && dl <= len) {
        f['progress'] = (dl / len).clamp(0.0, 1.0);
        f['isComplete'] = dl >= len;
        f['progressEstimated'] = false;
      } else if (dl == 0 && totalDownloadedBytes > 0) {
        final est = (len * progress).clamp(0.0, len.toDouble()).toInt();
        f['downloadedBytes'] = est;
        f['progress'] = len > 0 ? (est / len).clamp(0.0, 1.0) : 0.0;
        f['isComplete'] = false;
        f['progressEstimated'] = true;
      } else if (dl >= 0 && dl <= len) {
        f['progress'] = len > 0 ? (dl / len).clamp(0.0, 1.0) : 0.0;
        f['isComplete'] = len > 0 && dl >= len;
        f['progressEstimated'] = false;
      } else {
        final est = (len * progress).clamp(0.0, len.toDouble()).toInt();
        f['downloadedBytes'] = est;
        f['progress'] = len > 0 ? (est / len).clamp(0.0, 1.0) : 0.0;
        f['isComplete'] = false;
        f['progressEstimated'] = true;
      }
    }
    if (totalDownloadedBytes == 0) return;
    if (sequential) {
      distributeEstimatedBytesSequential(files, totalDownloadedBytes);
    } else {
      distributeEstimatedBytes(files, totalDownloadedBytes);
    }
  }

  /// Applies native per-file downloaded bytes from the engine.
  /// When native data is available, this provides exact progress
  /// without estimation. Falls back to [updateFilesWithNativeProgress]
  /// when [nativeFileProgress] is empty.
  static void applyNativeFileProgress(
    List<Map<String, dynamic>> files,
    List<int> nativeFileProgress,
    double overallProgress,
    int totalDownloadedBytes, {
    bool sequential = false,
  }) {
    // If native data is available and matches file count, use it directly
    if (nativeFileProgress.isNotEmpty &&
        nativeFileProgress.length >= files.length) {
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        if (!TorrentFileNormalizer.isTorrentFileSelected(f)) {
          f['downloadedBytes'] = 0;
          f['progress'] = 0.0;
          f['isComplete'] = false;
          f['progressEstimated'] = false;
          continue;
        }
        final len = (f['length'] as num?)?.toInt() ?? 0;
        final dl = nativeFileProgress[i]
            .clamp(0, len > 0 ? len : nativeFileProgress[i]);
        f['downloadedBytes'] = dl;
        f['progress'] = len > 0 ? (dl / len).clamp(0.0, 1.0) : 0.0;
        f['isComplete'] = len > 0 && dl >= len;
        f['progressEstimated'] = false;
      }
      return;
    }
    // Fall back to estimation
    updateFilesWithNativeProgress(files, overallProgress, totalDownloadedBytes,
        sequential: sequential);
  }

  /// Distributes estimated downloaded bytes sequentially (file-by-file).
  static void distributeEstimatedBytesSequential(
    List<Map<String, dynamic>> files,
    int totalDownloadedBytes,
  ) {
    int remaining = totalDownloadedBytes;
    for (final f in files) {
      if (!TorrentFileNormalizer.isTorrentFileSelected(f)) continue;
      final len = (f['length'] as num?)?.toInt() ?? 0;
      if (len <= 0) continue;
      final priorDl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final calculatedDl = remaining >= len ? len : remaining;
      final dl = math.max(priorDl, calculatedDl).clamp(0, len);
      f['downloadedBytes'] = dl;
      f['progress'] = len > 0 ? (dl / len).clamp(0.0, 1.0) : 0.0;
      f['isComplete'] = len > 0 && dl >= len;
      f['progressEstimated'] = true;
      remaining -= calculatedDl;
      if (remaining <= 0) remaining = 0;
    }
  }

  /// Distributes estimated downloaded bytes proportionally across files needing estimation.
  static void distributeEstimatedBytes(
    List<Map<String, dynamic>> files,
    int totalDownloadedBytes,
  ) {
    int confirmedBytes = 0;
    double totalWeightedNeedingSize = 0;
    final needing = <Map<String, dynamic>>[];
    for (final f in files) {
      if (!TorrentFileNormalizer.isTorrentFileSelected(f)) {
        f['downloadedBytes'] = 0;
        f['progress'] = 0.0;
        f['isComplete'] = false;
        f['progressEstimated'] = false;
        continue;
      }
      final estimated = (f['progressEstimated'] as bool?) ?? true;
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final len = (f['length'] as num?)?.toInt() ?? 0;
      final priority = (f['priority'] as num?)?.toInt() ?? 4;
      if (!estimated) {
        confirmedBytes += dl;
      } else if (dl < len && len > 0) {
        needing.add(f);
        totalWeightedNeedingSize += len * priorityWeight(priority);
      }
    }
    if (needing.isEmpty) return;
    final remaining = math.max(0, totalDownloadedBytes - confirmedBytes);

    if (totalWeightedNeedingSize <= 0) {
      final evenShare = needing.isNotEmpty ? (remaining ~/ needing.length) : 0;
      var leftover = remaining - (evenShare * needing.length);
      for (var i = 0; i < needing.length; i++) {
        final f = needing[i];
        final length = (f['length'] as num?)?.toInt() ?? 0;
        if (length <= 0) {
          f['downloadedBytes'] = 0;
          continue;
        }
        final extra = leftover > 0 ? 1 : 0;
        if (leftover > 0) leftover--;
        final est = (evenShare + extra).clamp(0, length);
        f['downloadedBytes'] = est;
        f['progressEstimated'] = true;
        f['progress'] = length > 0 ? (est / length).clamp(0.0, 1.0) : 0.0;
        f['isComplete'] = length > 0 && est >= length;
      }
      reconcileEstimatedFiles(files, totalDownloadedBytes);
      return;
    }

    for (final f in needing) {
      final length = (f['length'] as num?)?.toInt() ?? 0;
      final priority = (f['priority'] as num?)?.toInt() ?? 4;
      if (length <= 0) {
        f['downloadedBytes'] = 0;
        continue;
      }
      final weight = totalWeightedNeedingSize > 0 && remaining > 0
          ? (length * priorityWeight(priority)) / totalWeightedNeedingSize
          : 0.0;
      final est = (weight * remaining).round().clamp(0, length);
      f['downloadedBytes'] = est;
      f['progressEstimated'] = true;
      f['progress'] = length > 0 ? (est / length).clamp(0.0, 1.0) : 0.0;
      f['isComplete'] = length > 0 && est >= length;
    }
    reconcileEstimatedFiles(files, totalDownloadedBytes);
  }

  /// Reconciles estimated per-file downloaded bytes against [totalDownloadedBytes].
  static void reconcileEstimatedFiles(
    List<Map<String, dynamic>> files,
    int totalDownloadedBytes,
  ) {
    if (totalDownloadedBytes <= 0 || files.isEmpty) return;
    int currentSum = 0;
    final estimatedFiles = <Map<String, dynamic>>[];
    int totalRemainingNeeded = 0;
    for (final f in files) {
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      final len = (f['length'] as num?)?.toInt() ?? 0;
      currentSum += dl;
      final estimated = (f['progressEstimated'] as bool?) ?? false;
      if (estimated && dl < len) {
        estimatedFiles.add(f);
        totalRemainingNeeded += (len - dl);
      }
    }
    final diff = totalDownloadedBytes - currentSum;
    if (diff == 0) return;
    if (diff > 0 && totalRemainingNeeded > 0 && estimatedFiles.isNotEmpty) {
      int applied = 0;
      for (int i = 0; i < estimatedFiles.length; i++) {
        final f = estimatedFiles[i];
        final len = (f['length'] as num?)?.toInt() ?? 0;
        final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
        final remainingNeeded = len - dl;
        final share = (i == estimatedFiles.length - 1)
            ? (diff - applied)
            : ((remainingNeeded / totalRemainingNeeded) * diff).round();
        applied += share;
        final newDl = (dl + share).clamp(0, len);
        f['downloadedBytes'] = newDl;
        // FIX: [Audit] Empty / zero-length files must have 0.0 progress, not 1.0
        f['progress'] = len > 0 ? (newDl / len).clamp(0.0, 1.0) : 0.0;
        f['isComplete'] = len > 0 && newDl >= len;
      }
    } else if (diff < 0) {
      final filesWithDl = files
          .where((f) =>
              ((f['downloadedBytes'] as num?)?.toInt() ?? 0) > 0 &&
              ((f['progressEstimated'] as bool?) ?? false))
          .toList();
      final totalEstimatedDl = filesWithDl.fold(
          0, (sum, f) => sum + ((f['downloadedBytes'] as num?)?.toInt() ?? 0));
      if (totalEstimatedDl > 0) {
        final excess = -diff;
        int subtracted = 0;
        for (int i = 0; i < filesWithDl.length; i++) {
          final f = filesWithDl[i];
          final len = (f['length'] as num?)?.toInt() ?? 0;
          final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
          final share = (i == filesWithDl.length - 1)
              ? (excess - subtracted)
              : ((dl / totalEstimatedDl) * excess).round();
          subtracted += share;
          final newDl = math.max(0, dl - share);
          f['downloadedBytes'] = newDl;
          f['progress'] = len > 0 ? (newDl / len).clamp(0.0, 1.0) : 0.0;
          f['isComplete'] = len > 0 && newDl >= len;
        }
      }
    }
  }
}
