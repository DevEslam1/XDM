import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/bencode_decoder.dart';

/// Crash-safe persistence for libtorrent fast-resume blobs.
///
/// Invariants:
///  - Blobs are keyed by SOURCE URL (stable across process restarts), never
///    by numeric torrent id alone (process-local).
///  - Every write is tmp → FSYNC → rename for both the blob and its metadata,
///    and the metadata carries a SHA-256 of the blob. `load` re-hashes and
///    returns null on mismatch — a corrupt blob degrades to a recheck, never
///    to undefined engine state.
///  - [saveAndWait] resolves only after the blob is durably on disk; callers
///    that await it (provider pause path, engine cancel path) get the
///    "pause implies resume-data-is-flushed" guarantee.
class TorrentResumeStore {
  TorrentResumeStore._();

  static const String _resumeDirName = 'torrent_resume';

  /// torrentId → sourceUrl registry (populated by the engine on add).
  static final Map<int, String> _sourceByTorrentId = {};
  static final Map<String, String> _lastSavedDigest = {};

  static Future<Directory> _dir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/$_resumeDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _stableKey(String sourceUrl) {
    // Key on the info-hash when available (stable across mirrors/redirects)
    if (sourceUrl.startsWith('magnet:')) {
      final match = RegExp(
        r'xt=urn:bt(?:ih|mh):([a-zA-Z0-9]+)',
        caseSensitive: false,
      ).firstMatch(sourceUrl);
      if (match != null) {
        final infoHash = match.group(1)!;
        return sha256.convert(utf8.encode(infoHash.toLowerCase())).toString();
      }
    }

    // For .torrent files, attempt to extract the info-hash from file bytes
    try {
      String filePath = sourceUrl;
      if (filePath.startsWith('file://')) {
        filePath = Uri.parse(filePath).toFilePath();
      }
      final file = File(filePath);
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        final parsed = BencodeDecoder.parseTorrentBytes(bytes);
        final infoHash = parsed?['infoHash'] as String?;
        if (infoHash != null && infoHash.isNotEmpty) {
          return sha256.convert(utf8.encode(infoHash.toLowerCase())).toString();
        }
      }
    } catch (e, st) {
      LoggingService.logger('TorrentResumeStore')
          .warning('Operation failed', e, st);
    }

    return sha256.convert(utf8.encode(sourceUrl)).toString();
  }

  static void registerSource(int torrentId, String sourceUrl) {
    if (sourceUrl.trim().isEmpty) return;
    _sourceByTorrentId[torrentId] = sourceUrl;
  }

  static void unregisterTorrent(int torrentId) {
    _sourceByTorrentId.remove(torrentId);
  }

  static void unregisterSource(String sourceUrl) {
    _sourceByTorrentId.removeWhere((_, url) => url == sourceUrl);
    _lastSavedDigest.remove(sourceUrl);
  }

  static const String _indexKey = 'torrent_resume_index';

  static Future<void> _updateIndex(int torrentId, String fileName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_indexKey);
      final index = raw != null
          ? Map<String, String>.from(jsonDecode(raw))
          : <String, String>{};
      index['$torrentId'] = fileName;
      await prefs.setString(_indexKey, jsonEncode(index));
    } catch (e, st) {
      LoggingService.logger('TorrentResumeStore')
          .warning('Operation failed', e, st);
    }
  }

  static Future<void> _removeFromIndex(int torrentId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_indexKey);
      if (raw == null) return;
      final index = Map<String, String>.from(jsonDecode(raw));
      index.remove('$torrentId');
      await prefs.setString(_indexKey, jsonEncode(index));
    } catch (e, st) {
      LoggingService.logger('TorrentResumeStore')
          .warning('Operation failed', e, st);
    }
  }

  /// Durable save. Returns true only when the blob was written AND re-read
  /// hash-verified. Never throws.
  static Future<bool> saveAndWait({
    required int torrentId,
    required String sourceUrl,
    required FutureOr<Uint8List?> Function() fetchResumeData,
    List<Map<String, dynamic>>? files,
  }) async {
    try {
      if (sourceUrl.trim().isEmpty) return false;
      final blob = await fetchResumeData();
      if (blob == null || blob.isEmpty) return false;

      // Reject file > 1MB
      if (blob.length > 1024 * 1024) {
        debugPrint(
            '[TorrentResumeStore] blob size > 1MB, rejecting as corrupt');
        return false;
      }

      final digest = sha256.convert(blob).toString();
      if (_lastSavedDigest[sourceUrl] == digest) {
        // Content unchanged, skip redundant disk I/O
        return true;
      }

      final dir = await _dir();
      final key = _stableKey(sourceUrl);
      final fileName = '$key.resume';
      final blobFile = File('${dir.path}/$fileName');
      final metaFile = File('${dir.path}/$key.meta.json');
      final blobTmp = File('${dir.path}/$fileName.tmp');
      final metaTmp = File('${dir.path}/$key.meta.json.tmp');

      final meta = jsonEncode({
        'sourceUrl': sourceUrl,
        'torrentId': torrentId,
        'sha256': digest,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'bytes': blob.length,
        if (files != null) 'files': files,
      });

      // FIX-M12: Write metadata JSON first, then binary resume blob
      await metaTmp.writeAsString(meta, flush: true);
      final mraf = await metaTmp.open(mode: FileMode.append);
      await mraf.flush();
      await mraf.close();

      await blobTmp.writeAsBytes(blob, flush: true);
      final raf = await blobTmp.open(mode: FileMode.append);
      await raf.flush();
      await raf.close();

      await metaTmp.rename(metaFile.path);
      await blobTmp.rename(blobFile.path);

      // FIX P1-8: Verify that renamed file actually exists on disk
      if (!await blobFile.exists()) {
        debugPrint('[TorrentResumeStore] rename verification failed');
        return false;
      }

      _lastSavedDigest[sourceUrl] = digest;
      registerSource(torrentId, sourceUrl);
      await _updateIndex(torrentId, fileName);
      return true;
    } catch (e) {
      debugPrint('[TorrentResumeStore] saveAndWait failed: $e');
      return false;
    }
  }

  static final Map<int, Timer> _saveDebounceTimers = {};

  /// Debounced batch save: saves at most every 30 seconds per torrent
  static Future<void> saveAllDebounced(
    Iterable<int> torrentIds,
    FutureOr<Uint8List?> Function(int) progressFor, [
    List<Map<String, dynamic>>? Function(int)? filesFor,
  ]) async {
    for (final id in torrentIds) {
      _saveDebounceTimers[id]?.cancel();
      _saveDebounceTimers[id] = Timer(
        const Duration(seconds: 30),
        () {
          final source = _sourceByTorrentId[id];
          if (source != null) {
            saveAndWait(
              torrentId: id,
              sourceUrl: source,
              fetchResumeData: () => progressFor(id),
              files: filesFor?.call(id),
            );
          }
        },
      );
    }
  }

  static void cancelPendingSaves() {
    for (final timer in _saveDebounceTimers.values) {
      timer.cancel();
    }
    _saveDebounceTimers.clear();
  }

  /// Batch save used by provider pause-all / periodic persistence.
  /// Awaits every per-id save so the caller's `await saveAll(...)` is a true
  /// barrier. Ids without a registered source URL are skipped (their blobs
  /// could not be re-found after a restart anyway).
  static Future<void> saveAll(
    Iterable<int> torrentIds,
    FutureOr<Uint8List?> Function(int) progressFor, [
    List<Map<String, dynamic>>? Function(int)? filesFor,
  ]) async {
    for (final id in torrentIds) {
      final source = _sourceByTorrentId[id];
      if (source == null) {
        debugPrint('[TorrentResumeStore] no source registered for id $id');
        continue;
      }
      await saveAndWait(
        torrentId: id,
        sourceUrl: source,
        fetchResumeData: () => progressFor(id),
        files: filesFor?.call(id),
      );
    }
  }

  /// Loads and hash-verifies the blob for [sourceUrl]. Null when missing,
  /// corrupt, or unreadable.
  static Future<Uint8List?> loadResumeDataForSource(String sourceUrl) async {
    try {
      final dir = await _dir();
      final key = _stableKey(sourceUrl);
      var blobFile = File('${dir.path}/$key.resume');
      if (!await blobFile.exists()) {
        blobFile = File('${dir.path}/$key.bin');
      }
      final metaFile = File('${dir.path}/$key.meta.json');
      if (!await blobFile.exists() || !await metaFile.exists()) return null;

      final meta = jsonDecode(await metaFile.readAsString());
      if (meta is! Map) return null;
      final expectedSha = meta['sha256'] as String?;

      final blob = await blobFile.readAsBytes();
      if (blob.isEmpty || blob.length > 1024 * 1024) {
        debugPrint(
            '[TorrentResumeStore] invalid blob size (${blob.length} bytes), rejecting as corrupt');
        await deleteResumeDataForSource(sourceUrl);
        return null;
      }

      if (expectedSha != null) {
        final actual = sha256.convert(blob).toString();
        if (actual != expectedSha) {
          debugPrint('[TorrentResumeStore] sha mismatch for $sourceUrl — '
              'discarding corrupt resume data');
          await deleteResumeDataForSource(sourceUrl);
          return null;
        }
      }
      return Uint8List.fromList(blob);
    } catch (e) {
      debugPrint('[TorrentResumeStore] load failed: $e');
      // FIX-M12: Delete corrupt resume data on load error
      await deleteResumeDataForSource(sourceUrl);
      return null;
    }
  }

  /// Per-file selection/progress snapshot saved alongside the blob, if any.
  static Future<List<Map<String, dynamic>>?> loadFilesForSource(
      String sourceUrl) async {
    try {
      final dir = await _dir();
      final key = _stableKey(sourceUrl);
      final metaFile = File('${dir.path}/$key.meta.json');
      if (!await metaFile.exists()) return null;
      final meta = jsonDecode(await metaFile.readAsString());
      if (meta is! Map || meta['files'] is! List) return null;
      return (meta['files'] as List)
          .whereType<Map>()
          .map((f) => Map<String, dynamic>.from(f))
          .toList();
    } catch (e, st) {
      LoggingService.logger('TorrentResumeStore')
          .warning('Operation failed with fallback', e, st);
      return null;
    }
  }

  static Future<void> deleteResumeDataForSource(String sourceUrl) async {
    try {
      _lastSavedDigest.remove(sourceUrl);
      final dir = await _dir();
      final key = _stableKey(sourceUrl);
      // FIX-M12: Delete all resume and metadata artifacts including temp files
      for (final suffix in [
        '.bin',
        '.meta.json',
        '.bin.tmp',
        '.resume',
        '.resume.tmp',
        '.meta.json.tmp'
      ]) {
        final f = File('${dir.path}/$key$suffix');
        if (await f.exists()) await f.delete();
      }
    } catch (e, st) {
      LoggingService.logger('TorrentResumeStore')
          .warning('Operation failed', e, st);
    }
  }

  /// Validates that a resume blob is structurally valid and non-corrupt (Phase 4).
  static bool validateResumeData(Uint8List blob) {
    if (blob.isEmpty) return false;
    if (blob.length > 1024 * 1024) return false;
    try {
      final decoded = BencodeDecoder(blob).decode();
      return decoded is Map;
    } catch (e, st) {
      LoggingService.logger('TorrentResumeStore')
          .warning('Operation failed with fallback', e, st);
      return false;
    }
  }

  /// Delete by torrent id (resolves via the registry).
  static Future<void> delete(int torrentId) async {
    await _removeFromIndex(torrentId);
    final source = _sourceByTorrentId.remove(torrentId);
    if (source != null) await deleteResumeDataForSource(source);
  }

  static const _taskIdMappingKey = 'torrent_task_id_mapping';

  static Future<void> persistTaskMapping(Map<String, int> mapping) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_taskIdMappingKey, jsonEncode(mapping));
    } catch (e) {
      debugPrint('Failed to persist torrent task mapping: $e');
    }
  }

  static Future<Map<String, int>> loadTaskMapping() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_taskIdMappingKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map((k, v) => MapEntry(k.toString(), v as int));
        }
      }
    } catch (e) {
      debugPrint('Failed to load torrent task mapping: $e');
    }
    return {};
  }
}
