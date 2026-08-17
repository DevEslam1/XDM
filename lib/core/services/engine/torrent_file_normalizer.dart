/// Normalizes torrent file metadata for consistent progress tracking.
///
/// Ensures all required fields are present and properly typed.
/// Tracks per-file progress for the torrent details screen.
class TorrentFileNormalizer {
  const TorrentFileNormalizer._();

  /// Returns true if the file is selected for download.
  static bool isTorrentFileSelected(Map<String, dynamic> f) =>
      (f['selected'] as bool?) ?? true;

  /// Normalizes a single torrent file entry, ensuring all fields are present
  /// and properly typed. Mutates the input map and returns it.
  static Map<String, dynamic> normalizeTorrentFile(Map<String, dynamic> f) {
    final len = (f['length'] as num?)?.toInt() ?? 0;
    var dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
    // Clamp downloaded bytes to [0, length]
    dl = len > 0 ? dl.clamp(0, len) : 0;
    final progress = len > 0 ? (dl / len).clamp(0.0, 1.0) : (len == 0 ? 1.0 : 0.0);
    f['name'] = f['name'] as String? ?? 'file';
    f['length'] = len;
    f['downloadedBytes'] = dl;
    f['selected'] = f['selected'] as bool? ?? true;
    f['priority'] = (f['priority'] as num?)?.toInt() ?? 4;
    f['speed'] = (f['speed'] as num?)?.toDouble() ?? 0.0;
    f['progress'] = progress;
    f['isComplete'] = len == 0 || (len > 0 && dl >= len);
    f['progressEstimated'] = (f['progressEstimated'] as bool?) ?? false;
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
        downloaded += dl;
        if (len == 0 || dl >= len) {
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
        downloaded += dl;
        if (len == 0 || dl >= len) {
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
}
