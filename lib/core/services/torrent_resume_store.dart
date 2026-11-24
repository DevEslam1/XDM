import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/bencode_decoder.dart';
import '../utils/url_utils.dart';

/// Reconciliation snapshot loaded for a torrent task on startup / UI refresh.
class TorrentTaskReconciliationSnapshot {
  final List<Map<String, dynamic>> files;
  final int selectedTotalBytes;
  final int selectedDownloadedBytes;
  final int totalUploaded;
  final bool hasNativeResumeBlob;
  final bool isComplete;

  const TorrentTaskReconciliationSnapshot({
    required this.files,
    required this.selectedTotalBytes,
    required this.selectedDownloadedBytes,
    this.totalUploaded = 0,
    required this.hasNativeResumeBlob,
    required this.isComplete,
  });
}

/// B15: readable degraded snapshot for engines whose native binary cannot
/// produce a fast-resume blob (libtorrent_flutter 1.9.2 has no
/// lt_save_resume_data export, so [TorrentResumeStore.saveAndWait] persists a
/// meta-only degraded fallback). The handler reads this back on re-add to
/// re-arm progress and drive the recovery recheck instead of silently
/// restarting from scratch.
class TorrentDegradedSnapshot {
  /// Per-file rows as persisted (name, length, selected, priority,
  /// downloadedBytes, …).
  final List<Map<String, dynamic>> files;

  /// Stored piece bitfield. Empty when the engine could not report pieces at
  /// save time.
  final List<bool> piecesBitfield;
  final int piecesTotal;
  final int piecesDone;

  /// Best-effort byte total the store claimed at pause time. Under 1.9.2
  /// per-file byte counts are unavailable, so this is derived by mapping the
  /// piece bitfield onto the selected file sizes.
  final int downloadedBytes;

  const TorrentDegradedSnapshot({
    required this.files,
    required this.piecesBitfield,
    required this.piecesTotal,
    required this.piecesDone,
    required this.downloadedBytes,
  });
}

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

  /// sourceUrl → normalized canonical infoHash (hex lowercase).
  static final Map<String, String> _infoHashBySource = {};
  static String? _loadedHashIndexPath;

  static const List<String> _artifactSuffixes = [
    '.bin',
    '.meta.json',
    '.bin.tmp',
    '.resume',
    '.resume.tmp',
    '.meta.json.tmp',
    '.torrent',
    '.torrent.tmp',
  ];

  static Future<Directory> _dir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/$_resumeDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static int _fileRowLength(Map<String, dynamic> row) =>
      (row['length'] as num?)?.toInt() ?? (row['size'] as num?)?.toInt() ?? 0;

  static List<Map<String, dynamic>> _normalizeFileRows(
      List<Map<String, dynamic>> rows) {
    return rows.map((row) {
      final len = _fileRowLength(row);
      final dl = (row['downloadedBytes'] as num?)?.toInt() ?? 0;
      final selected = (row['selected'] as bool?) ?? true;
      final priority = (row['priority'] as num?)?.toInt() ?? (selected ? 4 : 0);
      final isComplete = (row['isComplete'] as bool?) ?? (len > 0 && dl >= len);
      return <String, dynamic>{
        ...row,
        'length': len,
        'size': len,
        'lengthKnown': (row['lengthKnown'] as bool?) ?? (len > 0),
        'selected': selected,
        'priority': priority,
        'downloadedBytes': len > 0 ? dl.clamp(0, len) : (dl < 0 ? 0 : dl),
        'isComplete': isComplete,
      };
    }).toList();
  }

  /// Normalizes a v1 hex (40-char), v2 hex (64-char), or v1 base32 (32-char)
  /// infoHash to lowercase hex. Returns `null` when [raw] is empty or invalid.
  static String? normalizeInfoHash(String? raw) {
    if (raw == null) return null;
    final cleaned = raw.trim();
    if (cleaned.isEmpty) return null;
    if (RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(cleaned) ||
        RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(cleaned)) {
      return cleaned.toLowerCase();
    }
    if (RegExp(r'^[A-Za-z2-7]{32}$').hasMatch(cleaned)) {
      final decoded = _decodeBase32(cleaned.toUpperCase());
      if (decoded != null && decoded.length == 20) {
        return decoded.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      }
    }
    return null;
  }

  static List<int>? _decodeBase32(String input) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    var buffer = 0;
    var bitsLeft = 0;
    final out = <int>[];
    for (var i = 0; i < input.length; i++) {
      final val = alphabet.indexOf(input[i]);
      if (val < 0) return null;
      buffer = (buffer << 5) | val;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        out.add((buffer >> (bitsLeft - 8)) & 0xFF);
        bitsLeft -= 8;
      }
    }
    return out;
  }

  /// Extracts a canonical lowercase hex infoHash from [infoHash], the
  /// persistent/in-memory source registry, a magnet URI (v1 hex/base32 or v2),
  /// or a local `.torrent` file path.
  static String? extractCanonicalInfoHash(
    String sourceUrl, {
    String? infoHash,
  }) {
    final explicit = normalizeInfoHash(infoHash);
    if (explicit != null) return explicit;

    final cached = _infoHashBySource[sourceUrl];
    if (cached != null) return cached;

    if (sourceUrl.toLowerCase().startsWith('magnet:')) {
      final parsed = parseMagnetUrl(sourceUrl);
      final fromParsed =
          normalizeInfoHash(parsed['infoHashV1'] ?? parsed['infoHash']) ??
              normalizeInfoHash(parsed['infoHashV2']);
      if (fromParsed != null) return fromParsed;

      final match = RegExp(
        r'xt=urn:bt(?:ih|mh):([a-zA-Z0-9]+)',
        caseSensitive: false,
      ).firstMatch(sourceUrl);
      if (match != null) {
        final normalized = normalizeInfoHash(match.group(1)!);
        if (normalized != null) return normalized;
        return match.group(1)!.toLowerCase();
      }
    }

    try {
      var filePath = sourceUrl;
      if (filePath.startsWith('file://')) {
        filePath = Uri.parse(filePath).toFilePath();
      }
      final file = File(filePath);
      if (file.existsSync() && file.lengthSync() < 2 * 1024 * 1024) {
        final bytes = file.readAsBytesSync();
        final parsed = BencodeDecoder.parseTorrentBytes(bytes);
        final parsedHash = normalizeInfoHash(
              parsed?['infoHashV1'] as String? ??
                  parsed?['infoHash'] as String?,
            ) ??
            normalizeInfoHash(parsed?['infoHashV2'] as String?);
        if (parsedHash != null) return parsedHash;
      }
    } catch (_) {}

    return null;
  }

  static Future<void> _ensureHashIndexLoaded(Directory dir) async {
    final indexPath = '${dir.path}/source_hashes.json';
    if (_loadedHashIndexPath == indexPath) return;
    try {
      final f = File(indexPath);
      if (await f.exists()) {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final normalized = normalizeInfoHash(entry.value?.toString());
            if (entry.key is String && normalized != null) {
              _infoHashBySource.putIfAbsent(
                  entry.key as String, () => normalized);
            }
          }
        }
      }
      _loadedHashIndexPath = indexPath;
    } catch (_) {}
  }

  static Future<void> _saveHashIndex(Directory dir) async {
    try {
      final indexPath = '${dir.path}/source_hashes.json';
      final tmp = File('$indexPath.tmp');
      await tmp.writeAsString(jsonEncode(_infoHashBySource), flush: true);
      await _safeRenameFile(tmp, indexPath);
      _loadedHashIndexPath = indexPath;
    } catch (_) {}
  }

  static String _urlHashKey(String sourceUrl) =>
      sha256.convert(utf8.encode(sourceUrl)).toString();

  static String _stableKey(String sourceUrl, {String? infoHash}) {
    final canonical = extractCanonicalInfoHash(sourceUrl, infoHash: infoHash);
    if (canonical != null && canonical.isNotEmpty) {
      return sha256.convert(utf8.encode(canonical)).toString();
    }
    return _urlHashKey(sourceUrl);
  }

  static Future<String> _primaryKey(
    Directory dir,
    String sourceUrl, {
    String? infoHash,
  }) async {
    await _ensureHashIndexLoaded(dir);
    return _stableKey(sourceUrl, infoHash: infoHash);
  }

  static Future<List<String>> _candidateKeys(
    Directory dir,
    String sourceUrl, {
    String? infoHash,
  }) async {
    await _ensureHashIndexLoaded(dir);
    final keys = <String>[];
    final primary = _stableKey(sourceUrl, infoHash: infoHash);
    keys.add(primary);
    final legacy = _urlHashKey(sourceUrl);
    if (legacy != primary) {
      keys.add(legacy);
    }
    return keys;
  }

  /// Associates [infoHash] with [sourceUrl] across app restarts and migrates any
  /// legacy URL-keyed artifacts to the canonical infoHash key.
  static Future<void> registerInfoHash(
    String sourceUrl,
    String infoHash,
  ) async {
    final normalized = normalizeInfoHash(infoHash);
    if (sourceUrl.trim().isEmpty || normalized == null) return;
    try {
      final dir = await _dir();
      await _ensureHashIndexLoaded(dir);
      final prev = _infoHashBySource[sourceUrl];
      _infoHashBySource[sourceUrl] = normalized;
      if (prev != normalized) {
        await _saveHashIndex(dir);
      }

      final canonicalKey = sha256.convert(utf8.encode(normalized)).toString();
      final legacyKey = _urlHashKey(sourceUrl);
      if (legacyKey != canonicalKey) {
        final legacyMeta = File('${dir.path}/$legacyKey.meta.json');
        final canonicalMeta = File('${dir.path}/$canonicalKey.meta.json');
        if (await legacyMeta.exists() && !await canonicalMeta.exists()) {
          await _copyOrMoveArtifacts(
            dir,
            fromKey: legacyKey,
            toKey: canonicalKey,
            updatedSourceUrl: sourceUrl,
            infoHash: normalized,
            deleteOriginals: true,
          );
        } else {
          final legacyTorrent = File('${dir.path}/$legacyKey.torrent');
          final canonicalTorrent = File('${dir.path}/$canonicalKey.torrent');
          if (await legacyTorrent.exists() &&
              !await canonicalTorrent.exists()) {
            await legacyTorrent.copy(canonicalTorrent.path);
          }
        }
      }
    } catch (e) {
      debugPrint('[TorrentResumeStore] registerInfoHash failed: $e');
    }
  }

  /// Migrates stored resume artifacts, cached `.torrent` file, and source
  /// registry from [oldSourceUrl] to [newSourceUrl] without losing bytes.
  static Future<bool> migrateSourceKey(
    String oldSourceUrl,
    String newSourceUrl, {
    String? infoHash,
  }) async {
    if (oldSourceUrl.trim().isEmpty || newSourceUrl.trim().isEmpty) {
      return false;
    }
    try {
      final dir = await _dir();
      await _ensureHashIndexLoaded(dir);

      final effectiveHash = normalizeInfoHash(infoHash) ??
          extractCanonicalInfoHash(newSourceUrl) ??
          extractCanonicalInfoHash(oldSourceUrl);
      if (effectiveHash != null) {
        _infoHashBySource[oldSourceUrl] = effectiveHash;
        _infoHashBySource[newSourceUrl] = effectiveHash;
        await _saveHashIndex(dir);
      }

      for (final entry in List<MapEntry<int, String>>.from(
        _sourceByTorrentId.entries,
      )) {
        if (entry.value == oldSourceUrl) {
          _sourceByTorrentId[entry.key] = newSourceUrl;
        }
      }

      final targetKey = _stableKey(newSourceUrl, infoHash: effectiveHash);
      final candidates =
          await _candidateKeys(dir, oldSourceUrl, infoHash: effectiveHash);
      String? sourceKey;
      for (final candidate in candidates) {
        if (await File('${dir.path}/$candidate.meta.json').exists() ||
            await File('${dir.path}/$candidate.resume').exists() ||
            await File('${dir.path}/$candidate.torrent').exists()) {
          sourceKey = candidate;
          break;
        }
      }
      if (sourceKey == null) {
        return effectiveHash != null;
      }

      await _copyOrMoveArtifacts(
        dir,
        fromKey: sourceKey,
        toKey: targetKey,
        updatedSourceUrl: newSourceUrl,
        infoHash: effectiveHash,
        deleteOriginals: sourceKey != targetKey,
      );
      return true;
    } catch (e) {
      debugPrint('[TorrentResumeStore] migrateSourceKey failed: $e');
      return false;
    }
  }

  static Future<void> _copyOrMoveArtifacts(
    Directory dir, {
    required String fromKey,
    required String toKey,
    required String updatedSourceUrl,
    String? infoHash,
    bool deleteOriginals = false,
  }) async {
    for (final ext in ['.resume', '.bin', '.torrent']) {
      final src = File('${dir.path}/$fromKey$ext');
      final dst = File('${dir.path}/$toKey$ext');
      if (fromKey != toKey && await src.exists()) {
        if (deleteOriginals) {
          await _safeRenameFile(src, dst.path);
        } else {
          await src.copy(dst.path);
        }
      }
    }

    final srcMeta = File('${dir.path}/$fromKey.meta.json');
    final dstMeta = File('${dir.path}/$toKey.meta.json');
    if (await srcMeta.exists()) {
      try {
        final decoded = jsonDecode(await srcMeta.readAsString());
        if (decoded is Map) {
          final updated = Map<String, dynamic>.from(decoded);
          updated['sourceUrl'] = updatedSourceUrl;
          if (infoHash != null) updated['infoHash'] = infoHash;
          final tmp = File('${dstMeta.path}.tmp');
          await tmp.writeAsString(jsonEncode(updated), flush: true);
          await _safeRenameFile(tmp, dstMeta.path);
          if (fromKey != toKey && deleteOriginals && await srcMeta.exists()) {
            try {
              await srcMeta.delete();
            } catch (_) {}
          }
          return;
        }
      } catch (_) {}
      if (fromKey != toKey) {
        if (deleteOriginals) {
          await _safeRenameFile(srcMeta, dstMeta.path);
        } else {
          await srcMeta.copy(dstMeta.path);
        }
      }
    }
  }

  static void registerSource(int torrentId, String sourceUrl) {
    if (sourceUrl.trim().isEmpty) return;
    _sourceByTorrentId[torrentId] = sourceUrl;
  }

  static void unregisterTorrent(int torrentId) {
    _sourceByTorrentId.remove(torrentId);
    _saveDebounceTimers.remove(torrentId)?.cancel();
  }

  /// B9 test hook: whether [torrentId] still has a source registration —
  /// recoverable failures (stall / handle lost) must keep it.
  @visibleForTesting
  static bool isRegisteredForTesting(int torrentId) =>
      _sourceByTorrentId.containsKey(torrentId);

  static void unregisterSource(String sourceUrl) {
    _sourceByTorrentId.removeWhere((id, url) {
      if (url == sourceUrl) {
        _saveDebounceTimers.remove(id)?.cancel();
        return true;
      }
      return false;
    });
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
    } catch (_) {}
  }

  static Future<void> _removeFromIndex(int torrentId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_indexKey);
      if (raw == null) return;
      final index = Map<String, String>.from(jsonDecode(raw));
      index.remove('$torrentId');
      await prefs.setString(_indexKey, jsonEncode(index));
    } catch (_) {}
  }

  /// Durable save. Returns true only when the blob was written AND re-read
  /// hash-verified. Never throws.
  static Future<bool> saveAndWait({
    required int torrentId,
    required String sourceUrl,
    required FutureOr<Uint8List?> Function() fetchResumeData,
    List<Map<String, dynamic>>? files,
    List<bool>? pieceBitfield,
    List<int>? fileProgress,
    int? piecesTotal,
    int? piecesDone,
    bool degradedFallback = false,
    String? infoHash,
  }) async {
    try {
      if (sourceUrl.trim().isEmpty) return false;
      final blob = await fetchResumeData();
      final hasNativeResumeData = blob != null && blob.isNotEmpty;

      // FIX: [Audit] Raised fast-resume blob cap to 16MB for large multi-piece torrents.
      if (hasNativeResumeData && blob.length > 16 * 1024 * 1024) {
        debugPrint(
            '[TorrentResumeStore] blob size > 16MB, rejecting as corrupt');
        return false;
      }

      final actualBlob = blob ?? Uint8List(0);
      if (actualBlob.isEmpty &&
          !degradedFallback &&
          files == null &&
          pieceBitfield == null) {
        return false;
      }

      final dir = await _dir();
      final normalizedHash = normalizeInfoHash(infoHash);
      if (normalizedHash != null) {
        _infoHashBySource[sourceUrl] = normalizedHash;
        await _saveHashIndex(dir);
      }
      final key = await _primaryKey(dir, sourceUrl, infoHash: infoHash);
      final normalizedFiles = files != null ? _normalizeFileRows(files) : null;
      final fileName = '$key.resume';
      final blobFile = File('${dir.path}/$fileName');
      final metaFile = File('${dir.path}/$key.meta.json');
      final blobTmp = File('${dir.path}/$fileName.tmp');
      final metaTmp = File('${dir.path}/$key.meta.json.tmp');

      // FIX P0-3/P0-4: Correct crash-safe order is blob-first, meta-second.
      // Previously meta was written/renamed first - crash between renames left
      // new meta (sha=empty) pointing at old blob -> sha mismatch -> valid
      // resume deleted. Also avoid overwriting valid blob with 0-byte degraded file.
      String effectiveDigest;
      bool shouldWriteBlob = hasNativeResumeData && actualBlob.isNotEmpty;
      Uint8List effectiveBlob = actualBlob;

      if (!shouldWriteBlob && degradedFallback) {
        if (await blobFile.exists()) {
          try {
            final existing = await blobFile.readAsBytes();
            if (existing.isNotEmpty && existing.length <= 16 * 1024 * 1024) {
              effectiveDigest = sha256.convert(existing).toString();
              shouldWriteBlob = false;
              effectiveBlob = existing;
            } else {
              effectiveDigest = sha256.convert(actualBlob).toString();
            }
          } catch (_) {
            effectiveDigest = sha256.convert(actualBlob).toString();
          }
        } else {
          effectiveDigest = sha256.convert(actualBlob).toString();
        }
      } else {
        effectiveDigest = sha256.convert(actualBlob).toString();
      }

      // Merge with existing meta so partial callers (e.g. saveResumeData) do
      // not drop stored files, bitfield, or infoHash.
      Map<String, dynamic> existingMeta = {};
      if (await metaFile.exists()) {
        try {
          final decoded = jsonDecode(await metaFile.readAsString());
          if (decoded is Map) {
            existingMeta = Map<String, dynamic>.from(decoded);
          }
        } catch (_) {}
      }

      // Re-encode meta with effective digest (preserve existing blob digest when degraded)
      final correctedMeta = jsonEncode({
        ...existingMeta,
        'sourceUrl': sourceUrl,
        if (normalizedHash != null) 'infoHash': normalizedHash,
        'torrentId': torrentId,
        'sha256': effectiveDigest,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'bytes': shouldWriteBlob ? actualBlob.length : effectiveBlob.length,
        'hasNativeResumeData': hasNativeResumeData && shouldWriteBlob,
        if (hasNativeResumeData && shouldWriteBlob)
          'nativeResumeBlob': base64Encode(actualBlob),
        if (normalizedFiles != null) 'files': normalizedFiles,
        if (pieceBitfield != null)
          'piecesBitfield': pieceBitfield.map((b) => b ? 1 : 0).toList(),
        if (fileProgress != null) 'fileProgress': fileProgress,
        if (piecesTotal != null) 'piecesTotal': piecesTotal,
        if (piecesDone != null) 'piecesDone': piecesDone,
        if (degradedFallback)
          'degradedFallback': true
        else if (hasNativeResumeData && shouldWriteBlob)
          'degradedFallback': false,
      });

      // Write blob FIRST (crash-safe: meta references blob sha)
      if (shouldWriteBlob) {
        await blobTmp.writeAsBytes(actualBlob, flush: true);
        final raf = await blobTmp.open(mode: FileMode.append);
        await raf.flush();
        await raf.close();
      }

      await metaTmp.writeAsString(correctedMeta, flush: true);
      final mraf = await metaTmp.open(mode: FileMode.append);
      await mraf.flush();
      await mraf.close();

      // Rename blob first, then meta (meta references blob)
      if (shouldWriteBlob) {
        await _safeRenameFile(blobTmp, blobFile.path);
      } else {
        try {
          if (await blobTmp.exists()) await blobTmp.delete();
        } catch (_) {}
      }
      await _safeRenameFile(metaTmp, metaFile.path);

      if (shouldWriteBlob && !await blobFile.exists()) {
        debugPrint('[TorrentResumeStore] rename verification failed');
        return false;
      }
      if (!await metaFile.exists()) {
        // The meta rename failed after the blob was already renamed into place.
        // Without a meta file the blob can never be loaded (loadResumeDataForSource
        // checks meta first), so it would linger forever as an orphan. Delete the
        // blob we just wrote to avoid leaking disk space.
        if (shouldWriteBlob) {
          try {
            if (await blobFile.exists()) await blobFile.delete();
          } catch (_) {}
        }
        debugPrint('[TorrentResumeStore] meta rename verification failed');
        return false;
      }

      registerSource(torrentId, sourceUrl);
      await _updateIndex(torrentId, fileName);
      return true;
    } catch (e) {
      debugPrint('[TorrentResumeStore] saveAndWait failed: $e');
      return false;
    }
  }

  /// Crash-safe rename used by every meta/blob write: retried, and falls
  /// back to a copy+rename when Windows holds the target open. Extracted so
  /// saveMetadataSnapshot uses the same durable handling as saveAndWait (B22).
  static Future<void> _safeRenameFile(File tempFile, String targetPath) async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final targetFile = File(targetPath);
        if (await targetFile.exists() && Platform.isWindows) {
          try {
            await targetFile.delete();
          } catch (_) {}
        }
        await tempFile.rename(targetPath);
        return;
      } catch (e) {
        if (attempt == 3) {
          final tmp2 = File('$targetPath.tmp2');
          try {
            final bytes = await tempFile.readAsBytes();
            await tmp2.writeAsBytes(bytes, flush: true);
            final targetFile = File(targetPath);
            if (await targetFile.exists()) {
              try {
                await targetFile.delete();
              } catch (_) {}
            }
            await tmp2.rename(targetPath);
          } finally {
            try {
              if (await tmp2.exists()) await tmp2.delete();
            } catch (_) {}
          }
        } else {
          await Future.delayed(Duration(milliseconds: 50 * attempt));
        }
      } finally {
        if (attempt == 3) {
          try {
            if (await tempFile.exists()) await tempFile.delete();
          } catch (_) {}
        }
      }
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
    final ids = List<int>.from(torrentIds);
    try {
      for (final id in ids) {
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
    } catch (e, st) {
      debugPrint(
          '[TorrentResumeStore] saveAll failed, scheduling retry: $e\n$st');
      // FIX-2: Retry once after 5s if batch save fails.
      // B23: the retry timer is registered in _saveDebounceTimers so
      // cancelPendingSaves() / unregisterTorrent() can stop it — an orphaned
      // timer must not write resume data after dispose. (One Timer object is
      // registered under every id; cancelling any of them cancels the batch
      // retry, which is safe — a lost retry degrades to a recheck, never to
      // corrupt state.)
      final retryTimer = Timer(const Duration(seconds: 5), () async {
        try {
          for (final id in ids) {
            final source = _sourceByTorrentId[id];
            if (source != null) {
              await saveAndWait(
                torrentId: id,
                sourceUrl: source,
                fetchResumeData: () => progressFor(id),
                files: filesFor?.call(id),
              );
            }
          }
        } catch (e2) {
          debugPrint('[TorrentResumeStore] saveAll retry failed: $e2');
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('torrent_resume_stale', true);
          } catch (_) {}
        }
      });
      for (final id in ids) {
        _saveDebounceTimers.remove(id)?.cancel();
        _saveDebounceTimers[id] = retryTimer;
      }
    }
  }

  /// Loads and hash-verifies the blob for [sourceUrl]. Null when missing,
  /// corrupt, or unreadable.
  static Future<Uint8List?> loadResumeDataForSource(
    String sourceUrl, {
    String? infoHash,
  }) async {
    try {
      final dir = await _dir();
      final keys = await _candidateKeys(dir, sourceUrl, infoHash: infoHash);
      for (final key in keys) {
        var blobFile = File('${dir.path}/$key.resume');
        if (!await blobFile.exists()) {
          blobFile = File('${dir.path}/$key.bin');
        }
        final metaFile = File('${dir.path}/$key.meta.json');
        if (!await metaFile.exists()) continue;

        final metaStr = await metaFile.readAsString();
        final meta = jsonDecode(metaStr);
        if (meta is! Map) continue;

        if (!await blobFile.exists()) continue;

        final expectedSha = meta['sha256'] as String?;

        final blob = await blobFile.readAsBytes();
        // FIX: [Audit] Cap at 16MB
        if (blob.isEmpty || blob.length > 16 * 1024 * 1024) {
          debugPrint(
              '[TorrentResumeStore] invalid blob size (${blob.length} bytes), rejecting as corrupt');
          await deleteResumeDataForSource(sourceUrl, infoHash: infoHash);
          return null;
        }

        if (expectedSha != null) {
          final actual = sha256.convert(blob).toString();
          if (actual != expectedSha) {
            debugPrint('[TorrentResumeStore] sha mismatch for $sourceUrl — '
                'discarding corrupt resume data');
            await deleteResumeDataForSource(sourceUrl, infoHash: infoHash);
            return null;
          }
        }
        return Uint8List.fromList(blob);
      }
      return null;
    } catch (e) {
      debugPrint('[TorrentResumeStore] load failed: $e');
      // FIX-M12: Delete corrupt resume data on load error
      await deleteResumeDataForSource(sourceUrl, infoHash: infoHash);
      return null;
    }
  }

  /// B15: loads the degraded (meta-only) snapshot for [sourceUrl] when no
  /// native blob exists.
  static Future<TorrentDegradedSnapshot?> loadDegradedSnapshotForSource(
    String sourceUrl, {
    String? infoHash,
  }) async {
    try {
      final dir = await _dir();
      final keys = await _candidateKeys(dir, sourceUrl, infoHash: infoHash);
      Map<dynamic, dynamic>? meta;
      for (final key in keys) {
        final metaFile = File('${dir.path}/$key.meta.json');
        if (!await metaFile.exists()) continue;
        final decoded = jsonDecode(await metaFile.readAsString());
        if (decoded is Map) {
          meta = decoded;
          break;
        }
      }
      if (meta == null) return null;
      // A native blob is handled by loadResumeDataForSource; this path is
      // exclusively for degraded (meta-only) snapshots.
      if (meta['degradedFallback'] != true) return null;

      final files = (meta['files'] as List?)
          ?.whereType<Map>()
          .map((f) => Map<String, dynamic>.from(f))
          .toList();
      final bitfield = (meta['piecesBitfield'] as List?)
          ?.map((b) => (b as num).toInt() != 0)
          .toList();
      final storedPiecesDone = (meta['piecesDone'] as num?)?.toInt();
      final piecesDone =
          storedPiecesDone ?? (bitfield?.where((b) => b).length ?? 0);
      final piecesTotal =
          (meta['piecesTotal'] as num?)?.toInt() ?? bitfield?.length ?? 0;

      final hasSnapshot =
          (files != null && files.isNotEmpty) || (bitfield != null);
      if (!hasSnapshot) return null;

      var selectedBytesTotal = 0;
      var storedFileBytes = 0;
      if (files != null) {
        for (final f in files) {
          final selected = (f['selected'] as bool?) ?? true;
          if (!selected) continue;
          final len = _fileRowLength(f);
          final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
          selectedBytesTotal += len;
          storedFileBytes += len > 0 ? dl.clamp(0, len) : 0;
        }
      }
      var downloadedBytes = storedFileBytes;
      if (bitfield != null && bitfield.isNotEmpty && selectedBytesTotal > 0) {
        final estimated =
            (selectedBytesTotal * piecesDone / bitfield.length).round();
        if (estimated > downloadedBytes) downloadedBytes = estimated;
      }

      return TorrentDegradedSnapshot(
        files: files != null ? _normalizeFileRows(files) : const [],
        piecesBitfield: bitfield ?? const [],
        piecesTotal: piecesTotal,
        piecesDone: piecesDone,
        downloadedBytes: downloadedBytes,
      );
    } catch (_) {
      return null;
    }
  }

  /// Loads persisted file selection & byte-progress state for task
  /// reconciliation at app startup.
  static Future<TorrentTaskReconciliationSnapshot?>
      loadTaskReconciliationSnapshot(
    String sourceUrl, {
    String? infoHash,
  }) async {
    try {
      final dir = await _dir();
      final keys = await _candidateKeys(dir, sourceUrl, infoHash: infoHash);
      for (final key in keys) {
        final metaFile = File('${dir.path}/$key.meta.json');
        if (!await metaFile.exists()) continue;
        final decoded = jsonDecode(await metaFile.readAsString());
        if (decoded is! Map) continue;
        final meta = Map<String, dynamic>.from(decoded);

        final rawFiles = (meta['files'] as List?)
                ?.whereType<Map>()
                .map((f) => Map<String, dynamic>.from(f))
                .toList() ??
            const <Map<String, dynamic>>[];
        final files = _normalizeFileRows(rawFiles);
        final hasNativeResumeBlob =
            await File('${dir.path}/$key.resume').exists() ||
                await File('${dir.path}/$key.bin').exists();

        var selectedTotal = 0;
        var selectedDone = 0;
        for (final f in files) {
          if ((f['selected'] as bool?) == false) continue;
          final len = _fileRowLength(f);
          final dl = (f['downloadedBytes'] as num?)?.toInt() ?? 0;
          selectedTotal += len;
          selectedDone += len > 0 ? dl.clamp(0, len) : dl;
        }

        if (selectedDone == 0 && selectedTotal > 0) {
          final bitfield = (meta['piecesBitfield'] as List?)
              ?.map((b) => (b as num).toInt() != 0)
              .toList();
          final piecesDone = (meta['piecesDone'] as num?)?.toInt() ??
              (bitfield?.where((b) => b).length ?? 0);
          final piecesTotal =
              (meta['piecesTotal'] as num?)?.toInt() ?? bitfield?.length ?? 0;
          if (piecesTotal > 0 && piecesDone > 0) {
            selectedDone = (selectedTotal * piecesDone / piecesTotal)
                .round()
                .clamp(0, selectedTotal);
          }
        }

        final isComplete = files.isNotEmpty &&
            selectedTotal > 0 &&
            selectedDone >= selectedTotal;

        if (files.isEmpty && !hasNativeResumeBlob) continue;

        return TorrentTaskReconciliationSnapshot(
          files: files,
          selectedTotalBytes: selectedTotal,
          selectedDownloadedBytes: selectedTotal > 0
              ? selectedDone.clamp(0, selectedTotal)
              : selectedDone,
          hasNativeResumeBlob: hasNativeResumeBlob,
          isComplete: isComplete,
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // FIX: [Audit] Save metadata/files snapshot discovered by probe without requiring binary resume data.
  // B22: this must MERGE with any existing meta rather than replace it — a
  // bare rewrite dropped the sha256/native blob digest and the pieces
  // bitfield, corrupting (or discarding) the resume data saved alongside it.
  static Future<bool> saveMetadataSnapshot({
    required String sourceUrl,
    required List<Map<String, dynamic>> files,
    String? name,
    int torrentId = -1,
    String? infoHash,
  }) async {
    try {
      if (sourceUrl.trim().isEmpty || files.isEmpty) return false;
      final dir = await _dir();
      final normalizedHash = normalizeInfoHash(infoHash);
      if (normalizedHash != null) {
        _infoHashBySource[sourceUrl] = normalizedHash;
        await _saveHashIndex(dir);
      }
      final key = await _primaryKey(dir, sourceUrl, infoHash: infoHash);
      final metaFile = File('${dir.path}/$key.meta.json');
      final metaTmp = File('${dir.path}/$key.meta.json.tmp');

      // Preserve everything a previous saveAndWait wrote (blob digest, native
      // blob copy, piece bitfield/counts, degraded flag); refresh the
      // mutable snapshot fields.
      Map<String, dynamic> existing = {};
      try {
        if (await metaFile.exists()) {
          final decoded = jsonDecode(await metaFile.readAsString());
          if (decoded is Map) existing = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}

      final merged = <String, dynamic>{
        ...existing,
        'sourceUrl': sourceUrl,
        if (normalizedHash != null) 'infoHash': normalizedHash,
        'torrentId': torrentId,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        if (name != null && name.isNotEmpty) 'name': name,
        'files': _normalizeFileRows(files),
      };

      await metaTmp.writeAsString(jsonEncode(merged), flush: true);
      final mraf = await metaTmp.open(mode: FileMode.append);
      await mraf.flush();
      await mraf.close();

      // Aligned with saveAndWait's durable rename (3-attempt retry + copy
      // fallback) instead of the bare delete+rename that previously raced.
      await _safeRenameFile(metaTmp, metaFile.path);
      return true;
    } catch (e) {
      debugPrint('[TorrentResumeStore] saveMetadataSnapshot failed: $e');
      return false;
    }
  }

  /// Per-file selection/progress snapshot saved alongside the blob, if any.
  static Future<List<Map<String, dynamic>>?> loadFilesForSource(
    String sourceUrl, {
    String? infoHash,
  }) async {
    try {
      final dir = await _dir();
      final keys = await _candidateKeys(dir, sourceUrl, infoHash: infoHash);
      for (final key in keys) {
        final metaFile = File('${dir.path}/$key.meta.json');
        if (!await metaFile.exists()) continue;
        final meta = jsonDecode(await metaFile.readAsString());
        if (meta is! Map || meta['files'] is! List) continue;
        final raw = (meta['files'] as List)
            .whereType<Map>()
            .map((f) => Map<String, dynamic>.from(f))
            .toList();
        return _normalizeFileRows(raw);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Persistently caches the raw bytes of a remote .torrent file so that subsequent
  /// resumes or re-adds can access a valid local file instead of failing HTTP fopen.
  static Future<File> saveTorrentFile(
    String sourceUrl,
    List<int> bytes, {
    String? infoHash,
  }) async {
    final dir = await _dir();
    String? extractedHash = normalizeInfoHash(infoHash);
    if (extractedHash == null && bytes.isNotEmpty) {
      try {
        final parsed = BencodeDecoder.parseTorrentBytes(
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        );
        extractedHash = normalizeInfoHash(
              parsed?['infoHashV1'] as String? ??
                  parsed?['infoHash'] as String?,
            ) ??
            normalizeInfoHash(parsed?['infoHashV2'] as String?);
      } catch (_) {}
    }
    if (extractedHash != null) {
      await registerInfoHash(sourceUrl, extractedHash);
    }
    final key = await _primaryKey(dir, sourceUrl, infoHash: extractedHash);
    final torrentFile = File('${dir.path}/$key.torrent');
    final tmpFile = File('${dir.path}/$key.torrent.tmp');
    await tmpFile.writeAsBytes(bytes, flush: true);
    final raf = await tmpFile.open(mode: FileMode.append);
    await raf.flush();
    await raf.close();
    await _safeRenameFile(tmpFile, torrentFile.path);
    return torrentFile;
  }

  /// Returns the persistent local .torrent file for [sourceUrl] if it exists on disk.
  static Future<File?> getTorrentFile(
    String sourceUrl, {
    String? infoHash,
  }) async {
    try {
      final dir = await _dir();
      final keys = await _candidateKeys(dir, sourceUrl, infoHash: infoHash);
      for (final key in keys) {
        final file = File('${dir.path}/$key.torrent');
        if (await file.exists() && await file.length() > 0) {
          return file;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<void> deleteResumeDataForSource(
    String sourceUrl, {
    String? infoHash,
  }) async {
    try {
      final dir = await _dir();
      final keys = await _candidateKeys(dir, sourceUrl, infoHash: infoHash);
      for (final key in keys) {
        // FIX-M12: Delete all resume, metadata and cached torrent artifacts including temp files
        for (final suffix in _artifactSuffixes) {
          final f = File('${dir.path}/$key$suffix');
          if (await f.exists()) await f.delete();
        }
      }
      if (_infoHashBySource.remove(sourceUrl) != null) {
        await _saveHashIndex(dir);
      }
    } catch (_) {}
  }

  /// Delete by torrent id (resolves via the registry).
  static Future<void> delete(int torrentId) async {
    _saveDebounceTimers.remove(torrentId)?.cancel();
    await _removeFromIndex(torrentId);
    final source = _sourceByTorrentId.remove(torrentId);
    if (source != null) await deleteResumeDataForSource(source);
  }

  static const String _taskMappingKey = 'torrent_task_mapping';

  static Future<Map<String, int>> loadTaskMapping() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_taskMappingKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((key, value) => MapEntry(key, (value as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  static Future<void> persistTaskMapping(Map<String, int> mapping) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_taskMappingKey, jsonEncode(mapping));
    } catch (_) {}
  }

  static bool validateResumeData(Uint8List blob) {
    if (blob.isEmpty || blob.length > 16 * 1024 * 1024) return false;
    return true;
  }

  /// FIX-4: Verify on-disk resume data validity for a given torrent ID.
  static Future<bool> verify(int torrentId) async {
    final source = _sourceByTorrentId[torrentId];
    if (source == null) return false;
    return verifySource(source);
  }

  /// FIX-4: Verify on-disk resume data validity for a given source URL.
  static Future<bool> verifySource(String sourceUrl, {String? infoHash}) async {
    try {
      final data = await loadResumeDataForSource(sourceUrl, infoHash: infoHash);
      return data != null && validateResumeData(data);
    } catch (_) {
      return false;
    }
  }

  /// Parses saved pieces metadata. If a bitfield exists and [piecesTotal] > 0,
  /// validates whether a recheck is needed by comparing stored [piecesDone]
  /// with the native engine's actual pieces after resume.
  static Future<bool> needsRecheckAfterResume(
    String sourceUrl,
    int actualPiecesDone, {
    String? infoHash,
  }) async {
    try {
      final dir = await _dir();
      final keys = await _candidateKeys(dir, sourceUrl, infoHash: infoHash);
      for (final key in keys) {
        final metaFile = File('${dir.path}/$key.meta.json');
        if (!await metaFile.exists()) continue;

        final meta = jsonDecode(await metaFile.readAsString());
        if (meta is! Map) continue;

        final bitfieldRaw = meta['piecesBitfield'];
        final piecesTotal = meta['piecesTotal'];
        final storedPiecesDone = meta['piecesDone'];

        if (bitfieldRaw != null &&
            piecesTotal != null &&
            (piecesTotal as num).toInt() > 0) {
          return (storedPiecesDone as num?)?.toInt() != actualPiecesDone;
        }
        return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}
