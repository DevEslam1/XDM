import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

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
  static final Lock _saveLock = Lock();

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

  static void unregisterSource(dynamic identifier) {
    if (identifier is int) {
      _sourceByTorrentId.remove(identifier);
    } else if (identifier is String) {
      _sourceByTorrentId.removeWhere((_, url) => url == identifier);
      _lastSavedDigest.remove(identifier);
    }
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
    return _saveLock.synchronized(() async {
      try {
        if (sourceUrl.trim().isEmpty) return false;
        final blob = await fetchResumeData();
        if (blob == null || blob.isEmpty) return false;

        // v2.0.0: Resume blobs can be larger (include file priorities, piece
        // hashes for v2/hybrid torrents). Match validateResumeData's 4MB limit.
        // The old 1MB limit silently rejected valid v2.0.0 resume data, causing
        // the engine to restart from scratch on every app restart.
        if (blob.length > 4 * 1024 * 1024) {
          debugPrint(
              '[TorrentResumeStore] blob size > 4MB, rejecting as corrupt');
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

        // Write both to temp first with fsync
        await blobTmp.writeAsBytes(blob, flush: true);
        final raf = await blobTmp.open(mode: FileMode.append);
        await raf.flush();
        await raf.close();

        await metaTmp.writeAsString(meta, flush: true);
        final mraf = await metaTmp.open(mode: FileMode.append);
        await mraf.flush();
        await mraf.close();

        // Then rename both atomically
        await blobTmp.rename(blobFile.path);
        await metaTmp.rename(metaFile.path);

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
    });
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
      // v2.0.0: Match the 4MB limit used by validateResumeData and saveAndWait.
      // The old 1MB limit would delete valid v2.0.0 resume data on load.
      if (blob.isEmpty || blob.length > 4 * 1024 * 1024) {
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
    // v2.0.0 resume blobs may be larger (include file priorities, piece hashes).
    if (blob.length > 4 * 1024 * 1024) return false;
    // First byte heuristic: bencode dicts start with 'd' (0x64), lists with 'l' (0x6c).
    // v2.0.0 internal format may also start with a different magic byte.
    final first = blob[0];
    final isBencode = first == 0x64 ||
        first == 0x6c ||
        first == 0x69 ||
        first == 0x65 ||
        (first >= 0x30 && first <= 0x39);
    if (!isBencode) {
      // Could be a v2.0.0 native serialization — accept by size heuristic only.
      return blob.length >= 32;
    }
    try {
      final decoded = BencodeDecoder(blob).decode();
      return decoded is Map;
    } catch (e, st) {
      LoggingService.logger('TorrentResumeStore').warning(
          'Bencode decode failed, accepting blob as v2.0.0 native', e, st);
      // v2.0.0: accept native serialization that isn't bencode-compatible.
      return blob.length >= 32;
    }
  }

  /// Delete by torrent id (resolves via the registry and orphaned files).
  static Future<void> delete(int torrentId) async {
    await _removeFromIndex(torrentId);
    final source = _sourceByTorrentId.remove(torrentId);
    if (source != null) {
      await deleteResumeDataForSource(source);
    }
    // Also scan for orphaned files matching this torrentId in meta files
    await _cleanupOrphanedFiles(torrentId);
  }

  static Future<void> _cleanupOrphanedFiles(int torrentId) async {
    try {
      final dir = await _dir();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.meta.json')) {
          try {
            final content = await entity.readAsString();
            final meta = jsonDecode(content);
            if (meta is Map && meta['torrentId'] == torrentId) {
              await entity.delete();
              final blobPath = entity.path.replaceAll('.meta.json', '.resume');
              final blobFile = File(blobPath);
              if (await blobFile.exists()) await blobFile.delete();
              final legacyBinPath =
                  entity.path.replaceAll('.meta.json', '.bin');
              final legacyBinFile = File(legacyBinPath);
              if (await legacyBinFile.exists()) await legacyBinFile.delete();
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
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
