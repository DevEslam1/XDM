/// Normalizes torrent file metadata for consistent progress tracking.
///
/// Ensures all required fields are present and properly typed.
/// Tracks per-file progress for the torrent details screen.
class TorrentFileNormalizer {
  const TorrentFileNormalizer._();

  /// Returns true if the file is selected for download.
  static bool isTorrentFileSelected(Map<String, dynamic> f) =>
      (f['selected'] as bool?) ?? true;

  /// Resolves the byte length of a file entry from a fresh engine reading.
  ///
  /// A native size of `0` means *unknown* — the metadata is not parsed yet, or
  /// the loaded native bridge is not ABI-compatible with these bindings and is
  /// handing back a zeroed struct tail. It never means "this file is empty", so
  /// a length that is already known (e.g. parsed from the `.torrent` bencode)
  /// always wins over a zero.
  static int resolveFileLength(int nativeSize, {int? previousLength}) {
    if (nativeSize > 0) return nativeSize;
    if (previousLength != null && previousLength > 0) return previousLength;
    return 0;
  }

  /// Whether a file entry carries a trustworthy byte length.
  ///
  /// Sources that genuinely know a file is zero bytes long (the torrent's own
  /// metadata) mark the entry with `lengthKnown: true`; everything else leaves
  /// a `0` length as unverified.
  static bool isLengthKnown(Map<String, dynamic> f) {
    final len = (f['length'] as num?)?.toInt() ?? 0;
    if (len > 0) return true;
    if (f.containsKey('lengthKnown')) {
      return (f['lengthKnown'] as bool?) == true;
    }
    return false;
  }

  /// Normalizes a single torrent file entry, ensuring all fields are present
  /// and properly typed. Mutates and returns the normalized map.
  static Map<String, dynamic> normalizeTorrentFile(Map<String, dynamic> f) {
    final len = (f['length'] as num?)?.toInt() ?? 0;
    final selected = isTorrentFileSelected(f);
    final lengthKnown = isLengthKnown(f);
    var dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
    if (!selected) {
      dl = 0;
    } else if (len > 0) {
      dl = dl.clamp(0, len);
    } else {
      // Unknown total: keep the transferred bytes we do know, they are real.
      dl = dl < 0 ? 0 : dl;
    }
    final double progress;
    if (!selected) {
      progress = 0.0;
    } else if (len > 0) {
      progress = (dl / len).clamp(0.0, 1.0);
    } else {
      // A verified empty file is trivially complete; an unknown size is not.
      progress = lengthKnown ? 1.0 : 0.0;
    }
    final isEstimated = (f['progressEstimated'] as bool?) ?? false;
    final isExplicitlyComplete = (f['isComplete'] as bool?) == true;
    f['name'] = f['name'] as String? ?? 'file';
    f['length'] = len;
    f['lengthKnown'] = lengthKnown;
    f['downloadedBytes'] = dl;
    f['selected'] = selected;
    f['priority'] = (f['priority'] as num?)?.toInt() ?? (selected ? 4 : 0);
    f['speed'] = (f['speed'] as num?)?.toDouble() ?? 0.0;
    f['progress'] = progress;
    // Completion can only be asserted against a known length. An unverified
    // zero length used to satisfy `dl >= len` and reported every file as done.
    f['isComplete'] = selected &&
        lengthKnown &&
        (isExplicitlyComplete || (!isEstimated && dl >= len));
    f['progressEstimated'] = isEstimated;
    return f;
  }

  /// Normalizes a list of torrent files and computes aggregate stats.
  ///
  /// Returns a record with:
  /// - [total]: count of selected files
  /// - [done]: count of completed selected files
  /// - [bytes]: total bytes of selected files
  /// - [downloaded]: total downloaded bytes of selected files
  /// - [hasEstimated]: true if any file uses estimated progress
  /// - [normalizedFiles]: the normalized file list
  static ({
    int total,
    int done,
    int bytes,
    int downloaded,
    bool hasEstimated,
    List<Map<String, dynamic>> normalizedFiles,
  }) normalizeTorrentFileList(List<dynamic>? rawList) {
    if (rawList == null || rawList.isEmpty) {
      return (
        total: 0,
        done: 0,
        bytes: 0,
        downloaded: 0,
        hasEstimated: false,
        normalizedFiles: <Map<String, dynamic>>[],
      );
    }

    int total = 0;
    int done = 0;
    int bytes = 0;
    int downloaded = 0;
    bool hasEstimated = false;
    final normalized = <Map<String, dynamic>>[];

    for (final item in rawList) {
      if (item is! Map) continue;
      final map = normalizeTorrentFile(Map<String, dynamic>.from(item));
      normalized.add(map);

      if ((map['progressEstimated'] as bool?) == true) {
        hasEstimated = true;
      }

      // Only count selected files in aggregate stats
      if (isTorrentFileSelected(map)) {
        final len = (map['length'] as num?)?.toInt() ?? 0;
        final dl = (map['downloadedBytes'] as num?)?.toInt() ?? 0;
        total++;
        bytes += len;
        // Skip bytes for unknown-length entries so `downloaded / bytes` cannot
        // exceed 1.0 when a file's total is not resolved yet.
        downloaded += len > 0 ? dl.clamp(0, len) : 0;
        if (map['isComplete'] == true) {
          done++;
        }
      }
    }

    // FIX v2.0.0: If no files are selected (e.g. all priority == 0), fall back to
    // computing aggregates across all files to avoid 0-byte totals in UI.
    if (total == 0 && normalized.isNotEmpty) {
      for (final map in normalized) {
        final len = (map['length'] as num?)?.toInt() ?? 0;
        final dl = (map['downloadedBytes'] as num?)?.toInt() ?? 0;
        total++;
        bytes += len;
        downloaded += len > 0 ? dl.clamp(0, len) : 0;
        // Reuse the normalized verdict instead of re-deriving it from a length
        // that may be unknown (`len == 0` is not evidence of completion).
        if (isLengthKnown(map) && dl >= len) {
          done++;
        }
      }
    }

    return (
      total: total,
      done: done,
      bytes: bytes,
      downloaded: downloaded,
      hasEstimated: hasEstimated,
      normalizedFiles: normalized,
    );
  }

  /// Computes a hash of the torrent file list for change detection.
  static int computeFileListHash(List<dynamic>? rawList) {
    if (rawList == null || rawList.isEmpty) return 0;
    int h = 17;
    for (final item in rawList) {
      if (item is! Map) continue;
      h = 37 * h + (item['name']?.hashCode ?? 0);
      h = 37 * h + ((item['downloadedBytes'] as num?)?.toInt() ?? 0);
      h = 37 * h + ((item['length'] as num?)?.toInt() ?? 0);
      h = 37 * h + ((item['selected'] as bool?) == false ? 0 : 1);
      h = 37 * h + ((item['priority'] as num?)?.toInt() ?? 4);
    }
    return h;
  }

  /// Computes the overall percentage for a list of torrent files.
  /// Returns a value between 0.0 and 1.0.
  static double computeOverallProgress(List<Map<String, dynamic>>? files) {
    if (files == null || files.isEmpty) return 0.0;
    final selected = files.where(isTorrentFileSelected).toList();
    if (selected.isEmpty) return 0.0;

    int totalBytes = 0;
    int downloadedBytes = 0;
    for (final f in selected) {
      final len = (f['length'] as num?)?.toInt() ?? 0;
      final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
      totalBytes += len;
      downloadedBytes += len > 0 ? dl.clamp(0, len) : 0;
    }

    if (totalBytes <= 0) return 0.0;
    return (downloadedBytes / totalBytes).clamp(0.0, 1.0);
  }

  /// Computes the percentage for a single torrent file.
  /// Returns a value between 0.0 and 1.0.
  static double computeFileProgress(Map<String, dynamic> f) {
    final len = (f['length'] as num?)?.toInt() ?? 0;
    final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
    if (len <= 0) return 0.0;
    return (dl / len).clamp(0.0, 1.0);
  }

  // FIX: [Audit] Centralized helper for formatting torrent files summary stats (e.g. "5/10 FILES").
  static String formatFilesSummary({
    required int totalFiles,
    required int completedFiles,
    int? selectedFiles,
  }) {
    if (totalFiles <= 0) return '—';
    final done = completedFiles.clamp(0, totalFiles);
    return '$done/$totalFiles FILES';
  }

  // FIX: [Audit] Convenience helper to extract summary directly from raw or normalized file list.
  static String formatSummaryFromFiles(List<dynamic>? rawList) {
    if (rawList == null || rawList.isEmpty) return '—';
    final normalized = normalizeTorrentFileList(rawList);
    if (normalized.total == 0) return '—';
    return formatFilesSummary(
      totalFiles: normalized.total,
      completedFiles: normalized.done,
    );
  }
}
