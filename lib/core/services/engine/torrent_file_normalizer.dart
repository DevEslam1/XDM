/// Unified utility for normalizing torrent file entries, calculating aggregates,
/// and computing progress estimation across engine handlers.
class TorrentFileNormalizer {
  const TorrentFileNormalizer._();

  /// Determines if a torrent file entry is marked as selected for download.
  static bool isTorrentFileSelected(Map<String, dynamic> f) =>
      (f['selected'] as bool?) ?? true;

  /// Normalizes a single torrent file map, ensuring:
  /// - `downloadedBytes` is clamped to `0..length`
  /// - `progress` is in `0.0..1.0` (or 1.0 if length is 0)
  /// - `isComplete` is true if length == 0 or downloadedBytes >= length
  /// - defaults for `name`, `selected`, `priority`, `speed`, and `progressEstimated`
  static Map<String, dynamic> normalizeTorrentFile(Map<String, dynamic> f) {
    final len = (f['length'] as num?)?.toInt() ?? 0;
    var dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
    dl = len > 0 ? dl.clamp(0, len) : 0;
    final progress = len > 0 ? (dl / len).clamp(0.0, 1.0) : 1.0;

    f['name'] = f['name'] as String? ?? 'file';
    f['length'] = len;
    f['downloadedBytes'] = dl;
    f['selected'] = f['selected'] as bool? ?? true;
    f['priority'] = (f['priority'] as num?)?.toInt() ?? 4;
    f['speed'] = (f['speed'] as num?)?.toDouble() ?? 0.0;
    f['progress'] = progress;
    f['isComplete'] = len == 0 || dl >= len;
    f['progressEstimated'] = (f['progressEstimated'] as bool?) ?? false;
    return f;
  }

  /// Normalizes a list of raw torrent file maps and computes aggregates for selected files:
  /// - `total`: count of selected files
  /// - `done`: count of completed selected files
  /// - `bytes`: total byte size of selected files
  /// - `downloaded`: total downloaded bytes of selected files
  /// - `hasEstimated`: true if any file in the list has `progressEstimated == true`
  /// - `normalizedFiles`: complete normalized list of files
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

    return (
      total: total,
      done: done,
      bytes: bytes,
      downloaded: downloaded,
      hasEstimated: hasEstimated,
      normalizedFiles: normalized,
    );
  }

  /// Computes a structural hash of a torrent file list for fast deduplication.
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
}
