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

  static Future<String> _ensureBasePath() async {
    if (_basePath != null) return _basePath!;
    await init();
    return _basePath!;
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
    await _ensureBasePath();
    try {
      final data = jsonEncode({
        'torrentId': torrentId,
        'progress': progress,
        'seedingEnabled': seedingEnabled,
        'torrentFiles': torrentFiles,
        'savedAt': DateTime.now().toIso8601String(),
      });
      // FIX(C5): Atomic write via temp file + rename to prevent corruption
      // if the app crashes mid-write. Handle Windows overwrite limitation.
      final targetPath = _pathFor(torrentId);
      final tmpPath = '$targetPath.${DateTime.now().microsecondsSinceEpoch}.tmp';
      final tmpFile = File(tmpPath);
      try {
        await tmpFile.writeAsString(data, flush: true);

        final targetFile = File(targetPath);
        if (await targetFile.exists()) {
          try {
            await targetFile.delete();
          } catch (e, st) {
            _log.warning('[torrent_resume_store] operation failed', e, st);
          }
        }

        try {
          await tmpFile.rename(targetPath);
        } catch (e) {
          await tmpFile.copy(targetPath);
          await tmpFile.delete();
        }
      } finally {
        try {
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (e, st) {
          _log.warning('[torrent_resume_store] operation failed', e, st);
        }
      }
    } catch (e) {
      _log.warning('save failed for $torrentId', e);
    }
  }

  /// Returns the saved metadata for a torrent, or null if no record exists.
  static Future<Map<String, dynamic>?> load(int torrentId) async {
    await _ensureBasePath();
    try {
      final file = File(_pathFor(torrentId));
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return data;
    } catch (e) {
      _log.warning('load failed for $torrentId, removing corrupt file', e);
      try {
        await File(_pathFor(torrentId)).delete();
      } catch (e, st) {
        _log.warning('[torrent_resume_store] operation failed', e, st);
      }
      return null;
    }
  }

  /// Returns the saved progress for a torrent, or null if no record exists.
  static Future<double?> loadProgress(int torrentId) async {
    final data = await load(torrentId);
    return (data?['progress'] as num?)?.toDouble();
  }

  static Future<void> delete(int torrentId) async {
    await _ensureBasePath();
    try {
      final file = File(_pathFor(torrentId));
      if (await file.exists()) await file.delete();
      final binFile = File(_binaryPathFor(torrentId));
      if (await binFile.exists()) await binFile.delete();
    } catch (e, st) {
      _log.warning('[torrent_resume_store] operation failed', e, st);
    }
  }

  static String _binaryPathFor(int torrentId) =>
      p.join(_basePath!, 'resume_${torrentId}_fast.bin');

  /// Saves native fast-resume binary data for a torrent using atomic temp write.
  static Future<void> saveResumeData(int torrentId, Uint8List data) async {
    await _ensureBasePath();
    try {
      final targetPath = _binaryPathFor(torrentId);
      final tmpPath = '$targetPath.${DateTime.now().microsecondsSinceEpoch}.tmp';
      final tmpFile = File(tmpPath);
      try {
        await tmpFile.writeAsBytes(data, flush: true);

        final targetFile = File(targetPath);
        if (await targetFile.exists()) {
          try {
            await targetFile.delete();
          } catch (e, st) {
            _log.warning('[torrent_resume_store] operation failed', e, st);
          }
        }

        try {
          await tmpFile.rename(targetPath);
        } catch (e, st) {
          _log.warning('[torrent_resume_store] operation failed', e, st);
          await tmpFile.copy(targetPath);
          await tmpFile.delete();
        }
      } finally {
        try {
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (e, st) {
          _log.warning('[torrent_resume_store] operation failed', e, st);
        }
      }
    } catch (e) {
      _log.warning('saveResumeData failed for $torrentId', e);
    }
  }

  /// Loads native fast-resume binary data for a torrent.
  /// Returns null if no data was saved or if loading fails.
  static Future<Uint8List?> loadResumeData(int torrentId) async {
    await _ensureBasePath();
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
    final idList = activeIds.toList();
    for (var i = 0; i < idList.length; i += 10) {
      final end = (i + 10).clamp(0, idList.length);
      final batch = idList.sublist(i, end);
      await Future.wait(batch.map((id) => save(
        id,
        progress: progressForId(id),
        torrentFiles: filesForId != null ? filesForId(id) : null,
        seedingEnabled: seedingForId != null ? seedingForId(id) : false,
      )));
    }
  }
}