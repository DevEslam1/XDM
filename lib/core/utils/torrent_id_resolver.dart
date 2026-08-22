import '../../features/downloads/models/download_task.dart';
import '../services/torrent_service_ffi.dart';

/// Unified utility to resolve a torrent ID from a DownloadTask, source URL,
/// or known active session mappings, safely returning null rather than an
/// invalid ID or defaulting to 0 / arbitrary tasks.
class TorrentIdResolver {
  /// Resolves the integer torrent ID for a given task.
  static int? resolve(DownloadTask? task, {Map<String, int>? providerMap}) {
    if (task == null) return null;

    // 0. Stored task.torrentId
    if (task.torrentId != null && task.torrentId! >= 0) {
      return task.torrentId;
    }

    // 1. Lookup by task.id in providerMap
    if (providerMap != null && providerMap.containsKey(task.id)) {
      final pid = providerMap[task.id];
      if (pid != null && pid >= 0) return pid;
    }

    // 2. Lookup by task.url in TorrentService
    if (task.url.isNotEmpty) {
      final sid = TorrentService.idForSource(task.url);
      if (sid != null && sid >= 0) return sid;
    }

    // 3. Integer taskId fallback if numeric and < 100000
    final numericId = int.tryParse(task.id);
    if (numericId != null && numericId >= 0 && numericId < 100000) {
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
