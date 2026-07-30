import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'logging_service.dart';

final _log = LoggingService.logger('TorrentResumeStore');

/// Persistence layer for torrent resume metadata.
///
/// Since libtorrent_flutter 1.9.2 does not expose native saveResumeData/
/// loadResumeData, this store uses a JSON marker file to record:
/// - which torrents were active,
/// - their last known progress,
/// - file priorities,
/// - selected files,
/// - and last known download/upload rates.
///
/// This allows the engine to skip re-checking torrents that were cleanly
/// paused, and preserves user selections across app restarts.
///
/// NOTE: Native libtorrent resume data (fast-resume) is the gold standard.
/// If a future plugin version exposes it, migrate to::
///   TorrentService.saveResumeData(torrentId) -> Uint8List
///   TorrentService.loadResumeData(torrentId, data)
class TorrentResumeStore {
  static const _dirName = 'torrent_resume';
  static String? _basePath;

  static Future<void> init() async {
    final appDir = await getApplicationSupportDirectory();
    _basePath = p.join(appDir.path, _dirName);
    final dir = Directory(_basePath!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  static String _pathFor(int torrentId) =>
      p.join(_basePath!, 'resume_$torrentId.json');

  /// Records that a torrent was active with its last known progress,
  /// file priorities, and selected files.
  static Future<void> save(
    int torrentId, {
    double progress = 0.0,
    List<Map<String, dynamic>>? torrentFiles,
    bool seedingEnabled = false,
  }) async {
    if (_basePath == null) return;
    try {
      final data = jsonEncode({
        'torrentId': torrentId,
        'progress': progress,
        'seedingEnabled': seedingEnabled,
        'torrentFiles': torrentFiles,
        'savedAt': DateTime.now().toIso8601String(),
      });
      await File(_pathFor(torrentId)).writeAsString(data, flush: true);
    } catch (e) {
      _log.warning('save failed for $torrentId', e);
    }
  }

  /// Returns the saved metadata for a torrent, or null if no record exists.
  static Future<Map<String, dynamic>?> load(int torrentId) async {
    if (_basePath == null) return null;
    try {
      final file = File(_pathFor(torrentId));
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return data;
    } catch (e) {
      _log.warning('load failed for $torrentId', e);
      return null;
    }
  }

  /// Returns the saved progress for a torrent, or null if no record exists.
  static Future<double?> loadProgress(int torrentId) async {
    final data = await load(torrentId);
    return data?['progress'] as double?;
  }

  static Future<void> delete(int torrentId) async {
    if (_basePath == null) return;
    try {
      final file = File(_pathFor(torrentId));
      if (await file.exists()) await file.delete();
      final binFile = File(_binaryPathFor(torrentId));
      if (await binFile.exists()) await binFile.delete();
    } catch (_) {}
  }

  static String _binaryPathFor(int torrentId) =>
      p.join(_basePath!, 'resume_${torrentId}_fast.bin');

  /// Saves native fast-resume binary data for a torrent.
  ///
  /// TODO: When libtorrent_flutter exposes saveResumeData with a typed API,
  /// this method stores the raw Uint8List to disk. The native implementation
  /// should return serialized libtorrent fast-resume data (entry::bencode()
  /// or similar) that can be passed back via loadResumeData on restart.
  static Future<void> saveResumeData(int torrentId, Uint8List data) async {
    if (_basePath == null) return;
    try {
      await File(_binaryPathFor(torrentId)).writeAsBytes(data, flush: true);
    } catch (e) {
      _log.warning('saveResumeData failed for $torrentId', e);
    }
  }

  /// Loads native fast-resume binary data for a torrent.
  /// Returns null if no data was saved or if loading fails.
  static Future<Uint8List?> loadResumeData(int torrentId) async {
    if (_basePath == null) return null;
    try {
      final file = File(_binaryPathFor(torrentId));
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (e) {
      _log.warning('loadResumeData failed for $torrentId', e);
      return null;
    }
  }

  /// Saves resume data for all active torrents.
  /// [filesForId] and [seedingForId] are optional for backward compatibility.
  static Future<void> saveAll(
    Set<int> activeIds,
    double Function(int id) progressForId, [
    List<Map<String, dynamic>>? Function(int id)? filesForId,
    bool Function(int id)? seedingForId,
  ]) async {
    await Future.wait(
      activeIds.map(
        (id) => save(
          id,
          progress: progressForId(id),
          torrentFiles: filesForId != null ? filesForId(id) : null,
          seedingEnabled: seedingForId != null ? seedingForId(id) : false,
        ),
      ),
    );
  }
}
