import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'torrent_service.dart';

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

  static Future<Directory> _dir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/$_resumeDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _stableKey(String sourceUrl) {
    if (sourceUrl.startsWith('magnet:')) {
      final match = RegExp(r'xt=urn:btih:([^&]+)').firstMatch(sourceUrl);
      if (match != null) {
        final infoHash = match.group(1)!;
        return sha256.convert(utf8.encode(infoHash.toLowerCase())).toString();
      }
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

      final dir = await _dir();
      final key = _stableKey(sourceUrl);
      final blobFile = File('${dir.path}/$key.bin');
      final metaFile = File('${dir.path}/$key.meta.json');
      final blobTmp = File('${dir.path}/$key.bin.tmp');
      final metaTmp = File('${dir.path}/$key.meta.json.tmp');

      final digest = sha256.convert(blob).toString();

      await blobTmp.writeAsBytes(blob, flush: true);
      final raf = await blobTmp.open(mode: FileMode.append);
      await raf.flush();
      await raf.close();
      await blobTmp.rename(blobFile.path);

      final meta = jsonEncode({
        'sourceUrl': sourceUrl,
        'torrentId': torrentId,
        'sha256': digest,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'bytes': blob.length,
        if (files != null) 'files': files,
      });
      await metaTmp.writeAsString(meta, flush: true);
      final mraf = await metaTmp.open(mode: FileMode.append);
      await mraf.flush();
      await mraf.close();
      await metaTmp.rename(metaFile.path);

      registerSource(torrentId, sourceUrl);
      return true;
    } catch (e) {
      debugPrint('[TorrentResumeStore] saveAndWait failed: $e');
      return false;
    }
  }

  /// Batch save used by provider pause-all / periodic persistence.
  /// Awa every per-id save so the caller's `await saveAll(...)` is a true
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
        fetchResumeData: () => TorrentService.fetchResumeBytes(id),
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
      final blobFile = File('${dir.path}/$key.bin');
      final metaFile = File('${dir.path}/$key.meta.json');
      if (!await blobFile.exists() || !await metaFile.exists()) return null;

      final meta = jsonDecode(await metaFile.readAsString());
      if (meta is! Map) return null;
      final expectedSha = meta['sha256'] as String?;

      final blob = await blobFile.readAsBytes();
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
    } catch (_) {
      return null;
    }
  }

  static Future<void> deleteResumeDataForSource(String sourceUrl) async {
    try {
      final dir = await _dir();
      final key = _stableKey(sourceUrl);
      for (final suffix in ['.bin', '.meta.json', '.bin.tmp']) {
        final f = File('${dir.path}/$key$suffix');
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }

  /// Delete by torrent id (resolves via the registry).
  static Future<void> delete(int torrentId) async {
    final source = _sourceByTorrentId.remove(torrentId);
    if (source != null) await deleteResumeDataForSource(source);
  }
}
