import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persistence layer for torrent resume metadata.
///
/// Since libtorrent_flutter 1.9.2 does not expose native saveResumeData/
/// loadResumeData, this store uses a JSON marker file to record which
/// torrents were active and their last known progress. This allows the
/// engine to skip re-checking torrents that were cleanly paused.
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

  /// Records that a torrent was active with its last known progress.
  /// Called on pause, app background, and dispose.
  static Future<void> save(int torrentId, {double progress = 0.0}) async {
    if (_basePath == null) return;
    try {
      final data = jsonEncode({
        'torrentId': torrentId,
        'progress': progress,
        'savedAt': DateTime.now().toIso8601String(),
      });
      await File(_pathFor(torrentId)).writeAsString(data, flush: true);
    } catch (e) {
      debugPrint('[TorrentResumeStore] save failed for $torrentId: $e');
    }
  }

  /// Returns the saved progress for a torrent, or null if no record exists.
  static Future<double?> load(int torrentId) async {
    if (_basePath == null) return null;
    try {
      final file = File(_pathFor(torrentId));
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return (data['progress'] as num?)?.toDouble();
    } catch (e) {
      debugPrint('[TorrentResumeStore] load failed for $torrentId: $e');
      return null;
    }
  }

  static Future<void> delete(int torrentId) async {
    if (_basePath == null) return;
    try {
      final file = File(_pathFor(torrentId));
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static Future<void> saveAll(
    Set<int> activeIds,
    double Function(int id) progressForId,
  ) async {
    await Future.wait(
      activeIds.map((id) => save(id, progress: progressForId(id))),
    );
  }
}
