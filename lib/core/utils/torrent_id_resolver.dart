import '../../features/downloads/models/download_task.dart';
import '../services/torrent_service_ffi.dart';

/// Unified utility to resolve a torrent ID from a DownloadTask, source URL,
/// or known active session mappings, safely returning null rather than an
/// invalid ID or defaulting to 0 / arbitrary tasks.
class TorrentIdResolver {
  /// Resolves the integer torrent ID for a given task.
  ///
  /// A libtorrent torrent id is a handle owned by the current native session,
  /// not a durable identifier: a new session hands out fresh ids, so a value
  /// cached on the task or in [providerMap] can outlive the handle it names.
  /// Candidates are therefore gathered in priority order and the first one the
  /// live session still recognises wins, so a stale id cannot shadow a torrent
  /// that is actually running under a different handle.
  static int? resolve(DownloadTask? task, {Map<String, int>? providerMap}) {
    if (task == null) return null;

    final candidates = <int>[];
    void addCandidate(int? id) {
      if (id != null && id >= 0 && !candidates.contains(id)) {
        candidates.add(id);
      }
    }

    // 0. Stored task.torrentId
    addCandidate(task.torrentId);
    // 1. Lookup by task.id in providerMap
    addCandidate(providerMap?[task.id]);
    // 2. Lookup by task.url in TorrentService
    if (task.url.isNotEmpty) {
      addCandidate(TorrentService.idForSource(task.url));
    }

    // Presence in the status snapshot is used as the liveness test rather than
    // isTorrentAlive(): this resolver runs from widget builds, and
    // isTorrentAlive() issues a blocking synchronous FFI status query.
    final stats = TorrentService.latestStats;
    for (final candidate in candidates) {
      if (stats.containsKey(candidate)) return candidate;
    }
    if (candidates.isNotEmpty) return candidates.first;

    // 3. Integer taskId fallback — only when the session actually holds that
    //    handle. Returning an unverified numeric task id aliases an unrelated
    //    torrent's stats onto this task.
    final numericId = int.tryParse(task.id);
    if (numericId != null && numericId >= 0 && stats.containsKey(numericId)) {
      return numericId;
    }

    return null;
  }

  /// Resolves the integer torrent ID from a source URL or magnet link.
  static int? resolveFromSource(String? source) {
    if (source == null || source.isEmpty) return null;
    return TorrentService.idForSource(source);
  }
}
