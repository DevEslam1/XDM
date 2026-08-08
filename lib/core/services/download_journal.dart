import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

// ═══════════════════════════════════════════════════════════════════════════
// DMX TRANSFER STATE — v3
//
// One authoritative, versioned state document per transfer stream.
//
// Compatibility contract: the v3 JSON is a SUPERSET of the legacy v2 schema.
// Legacy readers (DownloadProvider._readDmxStateBytes,
// DownloadOrchestrator._readDmxStateChunks / validateResumeState) read
// `totalSize`, `threadCount` and `progress` — all still present and always
// kept consistent with the richer `chunks` array. New code reads `chunks`.
// ═══════════════════════════════════════════════════════════════════════════

/// Lifecycle of a single stream's state document.
enum DmxStateStatus { active, paused, complete, failed }

/// One byte-range chunk. `downloaded` is ALWAYS a contiguous prefix of the
/// range: bytes [start, start + downloaded) are on disk, nothing beyond is
/// claimed. This invariant is what makes crash reconciliation unambiguous.
class ChunkState {
  ChunkState({required this.start, required this.end, this.downloaded = 0});

  /// Absolute start byte (inclusive).
  final int start;

  /// Absolute end byte (inclusive). `-1` = open-ended (total size unknown).
  int end;

  /// Contiguous bytes written from [start].
  int downloaded;

  int get size => end < 0 ? -1 : end - start + 1;
  bool get isComplete => end >= 0 && downloaded >= size;

  double get ratio {
    final s = size;
    // FIX-UNKNOWN-SIZE: Open-ended chunk (size unknown). Reporting 1.0
    // while bytes are flowing makes the details screen show "100%" for a
    // still-downloading indeterminate stream. Report -1.0 as a sentinel
    // so the UI can distinguish "indeterminate" (render an indeterminate
    // bar) from "0% downloaded" (render a determinate bar at 0%). The
    // ChunkDetail.isIndeterminate getter already checks `size < 0`, but
    // some UI paths read `ratio` directly and can't tell the difference
    // between 0.0 meaning "just started" and 0.0 meaning "unknown size".
    if (s < 0) return -1.0;
    if (s == 0) return downloaded > 0 ? 1.0 : 0.0;
    return (downloaded / s).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() =>
      {'start': start, 'end': end, 'downloaded': downloaded};

  static ChunkState fromJson(Map<String, dynamic> j) {
    var d = (j['downloaded'] as num?)?.toInt() ?? 0;
    if (d < 0) d = 0;
    return ChunkState(
      start: (j['start'] as num?)?.toInt() ?? 0,
      end: (j['end'] as num?)?.toInt() ?? -1,
      downloaded: d,
    );
  }
}

/// The single source of truth for one stream's progress.
class TransferState {
  TransferState({
    required this.totalSize,
    required this.threadCount,
    required this.chunks,
    this.url,
    this.etag,
    this.lastModified,
    this.status = DmxStateStatus.active,
    DateTime? updatedAt,
    this.migrationNote,
  }) : updatedAt = updatedAt ?? DateTime.now();

  static const int currentVersion = 3;

  /// 0 = unknown (learned from headers during transfer).
  int totalSize;
  int threadCount;
  List<ChunkState> chunks;
  String? url;
  String? etag;
  String? lastModified;
  DmxStateStatus status;
  DateTime updatedAt;

  /// Set when this state was produced by migrating an older format, so
  /// diagnostics can tell reconstructed progress apart from live progress.
  String? migrationNote;

  int get downloadedBytes {
    var sum = 0;
    for (final c in chunks) {
      sum += c.downloaded;
    }
    if (totalSize > 0 && sum > totalSize) sum = totalSize;
    return sum;
  }

  bool get isComplete => totalSize > 0 && downloadedBytes >= totalSize;

  /// Chunk ratios derived from the SAME bytes as [downloadedBytes] — the UI
  /// segmented bar and the percentage can never disagree.
  List<double> get chunkRatios => chunks.map((c) => c.ratio).toList();

  /// Legacy-compatible `progress` array (bytes per chunk).
  List<int> get progressCompat => chunks.map((c) => c.downloaded).toList();

  Map<String, dynamic> toJson() => {
        // Both spellings: v2 readers that check `version` see 3, the engine
        // checks `v`.
        'version': currentVersion,
        'v': currentVersion,
        'totalSize': totalSize,
        'threadCount': threadCount,
        'progress': progressCompat,
        'etag': etag,
        'lastModified': lastModified,
        'url': url,
        'status': status.name,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'chunks': chunks.map((c) => c.toJson()).toList(),
        if (migrationNote != null) 'migrationNote': migrationNote,
      };

  TransferState clone() => TransferState(
        totalSize: totalSize,
        threadCount: threadCount,
        chunks: chunks
            .map((c) => ChunkState(
                start: c.start, end: c.end, downloaded: c.downloaded))
            .toList(),
        url: url,
        etag: etag,
        lastModified: lastModified,
        status: status,
        updatedAt: updatedAt,
        migrationNote: migrationNote,
      );

  /// Parses a v3 document. Returns null when the document is not v3 or is
  /// structurally invalid (caller then falls back to legacy parsing).
  static TransferState? tryParseV3(Map<String, dynamic> json) {
    try {
      final v =
          (json['v'] as num?)?.toInt() ?? (json['version'] as num?)?.toInt();
      if (v != currentVersion) return null;
      final rawChunks = json['chunks'];
      if (rawChunks is! List || rawChunks.isEmpty) return null;
      final chunks = rawChunks
          .whereType<Map>()
          .map((c) => ChunkState.fromJson(Map<String, dynamic>.from(c)))
          .toList();
      if (chunks.isEmpty) return null;
      final statusName = json['status'] as String? ?? 'active';
      return TransferState(
        totalSize:
            ((json['totalSize'] as num?)?.toInt() ?? 0).clamp(0, 1 << 62),
        threadCount: ((json['threadCount'] as num?)?.toInt() ?? chunks.length)
            .clamp(1, 64),
        chunks: chunks,
        url: json['url'] as String?,
        etag: json['etag'] as String?,
        lastModified: json['lastModified'] as String?,
        status: DmxStateStatus.values.firstWhere(
          (s) => s.name == statusName,
          orElse: () => DmxStateStatus.active,
        ),
        updatedAt: json['updatedAt'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int)
            : DateTime.now(),
      );
    } catch (e) {
      debugPrint('[DmxState] v3 parse failed: $e');
      return null;
    }
  }

  static TransferState? tryParseV2(Map<String, dynamic> json) {
    try {
      final progress = json['progress'] as List?;
      if (progress == null || progress.isEmpty) return null;
      final totalSize = (json['totalSize'] as num?)?.toInt() ?? 0;
      final storedThreadCount =
          (json['threadCount'] as num?)?.toInt() ?? progress.length;

      // FIX H-4: Warn if stored thread count differs from progress length
      if (storedThreadCount != progress.length) {
        debugPrint('[DmxState] V2 migration: threadCount mismatch '
            '(stored=$storedThreadCount, progress.length=${progress.length}). '
            'Using progress.length as authoritative count.');
      }

      final effectiveThreads = progress.length; // Use actual data length
      final partSize =
          totalSize > 0 ? (totalSize / effectiveThreads).floor() : 0;

      final chunks = <ChunkState>[];
      for (int i = 0; i < effectiveThreads; i++) {
        final downloaded = (progress[i] as num?)?.toInt() ?? 0;
        final start = i * partSize;
        final end = (i == effectiveThreads - 1 && totalSize > 0)
            ? totalSize - 1
            : (start + partSize - 1);
        chunks.add(ChunkState(
          start: start,
          end: end,
          downloaded: downloaded.clamp(0, 1 << 62),
        ));
      }
      return TransferState(
        totalSize: totalSize,
        threadCount: effectiveThreads,
        chunks: chunks,
        url: json['url'] as String?,
        etag: json['etag'] as String?,
        lastModified: json['lastModified'] as String?,
        migrationNote: 'v2',
      );
    } catch (e) {
      return null;
    }
  }
}

/// Result of [StateStore.loadOrCreate].
class StateLoadResult {
  const StateLoadResult({
    required this.state,
    this.created = false,
    this.migratedFrom,
    this.diskAdjusted = false,
  });

  final TransferState state;

  /// True when no prior state existed and a fresh one was created.
  final bool created;

  /// 'v2' | 'journal' | 'fileLength' when progress was reconstructed.
  final String? migratedFrom;

  /// True when on-disk bytes forced a clamp of the stored claims.
  final bool diskAdjusted;
}

/// Atomic persistence for [TransferState].
///
/// All writes are write-tmp → FSYNC → rename on the same filesystem, so the
/// state file is ALWAYS either the old complete document or the new complete
/// document — a crash mid-write cannot produce a corrupt half-document.
class StateStore {
  StateStore._();

  static String pathFor(String tempFilePath) => '$tempFilePath.dmxstate';

  /// Loads, migrates, reconciles and returns the authoritative state for
  /// [tempFilePath]. Never throws on corrupted input — the worst case is a
  /// fresh zero-progress state (with [StateLoadResult.created] = true).
  static Future<StateLoadResult> loadOrCreate(
    String tempFilePath, {
    required String url,
    required int threadCount,
    required int knownFileSize,
  }) async {
    final path = pathFor(tempFilePath);
    final file = File(path);

    TransferState? state;
    String? migratedFrom;

    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          final json = Map<String, dynamic>.from(decoded);
          state = TransferState.tryParseV3(json);
          if (state == null) {
            state = _migrateV2(json, threadCount);
            if (state != null) migratedFrom = 'v2';
          }
        }
      } catch (e) {
        debugPrint('[DmxState] unreadable state at $path: $e');
        state = null; // fall through to journal / disk recovery
      }
    }

    // Legacy journal recovery — only consulted when there is no usable state.
    if (state == null) {
      final journalBytes =
          await DownloadJournal.recover('$tempFilePath.journal');
      if (journalBytes != null && journalBytes.isNotEmpty) {
        state = _stateFromChunkBytes(
          tempFilePath: tempFilePath,
          url: url,
          threadCount: journalBytes.length,
          chunkBytes: journalBytes,
          totalSize: knownFileSize,
        );
        migratedFrom = 'journal';
      }
    }

    // Single-thread fallback: without any sidecar, the file length IS the
    // truth (no pre-allocation in single-stream mode).
    if (state == null && threadCount <= 1) {
      final tmp = File(tempFilePath);
      if (await tmp.exists()) {
        final len = await tmp.length();
        if (len > 0) {
          state = TransferState(
            totalSize: knownFileSize > 0 ? knownFileSize : len,
            threadCount: 1,
            chunks: [
              ChunkState(
                start: 0,
                end: knownFileSize > 0 ? knownFileSize - 1 : -1,
                downloaded:
                    knownFileSize > 0 ? len.clamp(0, knownFileSize) : len,
              ),
            ],
            url: url,
            migrationNote: 'migrated_from_file_length',
          );
          migratedFrom = 'fileLength';
        }
      }
    }

    if (state == null && threadCount > 1) {
      final tmp = File(tempFilePath);
      if (await tmp.exists()) {
        final len = await tmp.length();
        if (len > 0) {
          final perChunk = knownFileSize > 0
              ? (len ~/ threadCount).clamp(0, knownFileSize ~/ threadCount)
              : len ~/ threadCount;
          state = TransferState(
            totalSize: knownFileSize > 0 ? knownFileSize : len,
            threadCount: threadCount,
            chunks: List.generate(threadCount, (i) {
              final start = i * perChunk;
              final end = (i == threadCount - 1 && knownFileSize > 0)
                  ? knownFileSize - 1
                  : start + perChunk - 1;
              // Multi-thread downloads pre-allocate the file; raw file length is not
              // a reliable indicator of downloaded bytes without a state file.
              // Treat as fresh download.
              return ChunkState(start: start, end: end, downloaded: 0);
            }),
            url: url,
            migrationNote: 'migrated_from_file_length_multithread',
          );
          migratedFrom = 'fileLength';
        }
      }
    }

    var created = false;
    if (state == null) {
      created = true;
      state = TransferState(
        totalSize: knownFileSize,
        threadCount: threadCount.clamp(1, 64),
        chunks: const [], // scheduler fills these before transfer starts
        url: url,
      );
    }

    // Crash-safe reconciliation: disk is the floor of truth.
    final adjusted = await _reconcileWithDisk(tempFilePath, state);
    return StateLoadResult(
      state: state,
      created: created,
      migratedFrom: migratedFrom,
      diskAdjusted: adjusted,
    );
  }

  /// Rebuilds a v3 state from legacy per-chunk byte counts on a fixed
  /// partition layout (identical to the layout v2 used).
  static TransferState _stateFromChunkBytes({
    required String tempFilePath,
    required String url,
    required int threadCount,
    required List<int> chunkBytes,
    required int totalSize,
  }) {
    final n = threadCount > 0 ? threadCount : 1;
    final chunks = <ChunkState>[];
    if (totalSize > 0) {
      final part = totalSize ~/ n;
      for (var i = 0; i < n; i++) {
        final start = i * part;
        final end = (i == n - 1) ? totalSize - 1 : start + part - 1;
        final size = end - start + 1;
        var bytes = i < chunkBytes.length ? chunkBytes[i] : 0;
        if (bytes < 0) bytes = 0;
        if (bytes > size) bytes = size;
        chunks.add(ChunkState(start: start, end: end, downloaded: bytes));
      }
    } else {
      // Total unknown: one open-ended chunk holding all recovered bytes.
      chunks.add(ChunkState(
        start: 0,
        end: -1,
        downloaded: chunkBytes.fold<int>(0, (s, b) => s + (b < 0 ? 0 : b)),
      ));
    }
    return TransferState(
      totalSize: totalSize,
      threadCount: n,
      chunks: chunks,
      url: url,
      migrationNote: 'migrated_from_legacy_bytes',
    );
  }

  /// v2 → v3 migration. v2 stored `{totalSize, threadCount, progress:[ints]}`.
  static TransferState? _migrateV2(Map<String, dynamic> json, int hintThreads) {
    try {
      final totalSize = (json['totalSize'] as num?)?.toInt() ?? 0;
      final progress = json['progress'];
      if (progress is! List || progress.isEmpty) return null;
      final bytes = progress
          .map((e) => e is num ? e.toInt() : 0)
          .map((b) => b < 0 ? 0 : b)
          .toList();
      final threads = (json['threadCount'] as num?)?.toInt() ?? hintThreads;
      final state = _stateFromChunkBytes(
        tempFilePath: '',
        url: (json['url'] as String?) ?? '',
        threadCount: bytes.length == threads ? threads : bytes.length,
        chunkBytes: bytes,
        totalSize: totalSize,
      );
      state.etag = json['etag'] as String?;
      state.lastModified = json['lastModified'] as String?;
      state.migrationNote = 'migrated_from_v2';
      return state;
    } catch (e) {
      debugPrint('[DmxState] v2 migration failed: $e');
      return null;
    }
  }

  /// Clamps stored claims to what can exist on disk.
  ///  - temp file missing          → all claims zeroed (nothing to resume)
  ///  - file shorter than claims   → per-chunk clamp to fit within length
  ///  - file longer than totalSize → truncated back to totalSize
  static Future<bool> _reconcileWithDisk(
      String tempFilePath, TransferState state) async {
    if (state.downloadedBytes == 0) return false;
    final f = File(tempFilePath);
    if (!await f.exists()) {
      for (final c in state.chunks) {
        c.downloaded = 0;
      }
      state.migrationNote =
          '${state.migrationNote ?? ''} disk_reconciled:file_missing'.trim();
      return true;
    }
    var adjusted = false;
    final len = await f.length();
    if (state.totalSize > 0 && len > state.totalSize) {
      // External growth / stale pre-allocation overshoot: truncate.
      try {
        final raf = await f.open(mode: FileMode.append);
        await raf.truncate(state.totalSize);
        await raf.close();
      } catch (_) {}
      adjusted = true;
    }
    final limit = state.totalSize > 0 ? len.clamp(0, state.totalSize) : len;
    for (final c in state.chunks) {
      // Claimed region [start, start+downloaded) must fit within [0, limit).
      final maxForChunk = (limit - c.start).clamp(0, 1 << 62);
      if (c.downloaded > maxForChunk) {
        c.downloaded = maxForChunk;
        adjusted = true;
      }
    }
    if (adjusted) {
      state.migrationNote =
          '${state.migrationNote ?? ''} disk_reconciled'.trim();
    }
    return adjusted;
  }

  /// Atomic save. Safe to call at any cadence; tmp+rename guarantees the
  /// document is never observed half-written.
  static Future<void> save(String tempFilePath, TransferState state) async {
    state.updatedAt = DateTime.now();
    final targetPath = pathFor(tempFilePath);
    final tmpPath = '$targetPath.tmp';
    try {
      final payload = jsonEncode(state.toJson());
      final tmp = File(tmpPath);
      await tmp.writeAsString(payload, flush: true);
      // writeAsString(flush:true) flushes buffers; re-open to force FSYNC
      // before rename on platforms where it matters.
      try {
        final raf = await tmp.open(mode: FileMode.append);
        await raf.flush();
        await raf.close();
      } catch (_) {}
      await tmp.rename(targetPath);
    } catch (e) {
      debugPrint('[DmxState] save failed for $tempFilePath: $e');
      // Best-effort cleanup of the orphaned tmp file so a stale
      // .dmxstate.tmp never pollutes the next save attempt.
      try {
        final tmp = File(tmpPath);
        if (await tmp.exists()) {
          await tmp.delete();
        }
      } catch (_) {}
    }
  }

  /// Removes the state file and its tmp sidecar. Called after a successful
  /// finalize/rename so the next launch does not treat a completed transfer
  /// as resumable.
  static Future<void> remove(String tempFilePath) async {
    final targetPath = pathFor(tempFilePath);
    final tmpPath = '$targetPath.tmp';
    try {
      final f = File(targetPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    try {
      final tmp = File(tmpPath);
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// DOWNLOAD JOURNAL — append-only crash-safety journal.
//
// Serialized append-only JSON-lines journal used to recover multi-thread
// download progress after a crash. Hardened behavior:
//  - all writes are serialized through a lock
//  - `writeInit()` will not reset an existing non-empty journal
//  - journal is compacted automatically to avoid unbounded growth
// ═══════════════════════════════════════════════════════════════════════════

class DownloadJournal {
  final String path;

  IOSink? _sink;
  bool _isOpen = false;

  int _approxBytes = 0;
  final int compactionThresholdBytes;

  final Lock _lock = Lock();

  DownloadJournal(this.path, {this.compactionThresholdBytes = 2 * 1024 * 1024});

  Future<void> open() async {
    await _lock.synchronized(() async {
      if (_isOpen) return;

      final file = File(path);

      if (await file.exists()) {
        try {
          _approxBytes = await file.length();
        } catch (_) {
          _approxBytes = 0;
        }
      } else {
        _approxBytes = 0;
      }

      _sink = file.openWrite(mode: FileMode.append);
      _isOpen = true;
    });
  }

  /// Writes an init event.
  ///
  /// If the journal already contains data, this method intentionally does
  /// nothing. This prevents accidentally wiping recovered progress when the
  /// engine calls `writeInit()` after opening an existing journal.
  Future<void> writeInit(int threadCount, int totalSize) async {
    await _lock.synchronized(() async {
      _ensureOpen();

      if (_approxBytes > 0) {
        return;
      }

      final line = jsonEncode({
        't': 'init',
        'threads': threadCount,
        'total': totalSize,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

      _sink!.writeln(line);
      await _sink!.flush();

      _approxBytes += line.length + 1;
    });
  }

  /// Records chunk progress.
  ///
  /// This is intentionally not flushed on every call to avoid disk thrashing.
  Future<void> recordChunkProgress(int index, int bytes) async {
    await _lock.synchronized(() {
      _ensureOpen();

      final line = jsonEncode({
        't': 'chunk',
        'i': index,
        'b': bytes,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

      _sink!.writeln(line);
      _approxBytes += line.length + 1;
    });
  }

  /// Writes a durable checkpoint and flushes it.
  Future<void> writeCheckpoint(List<int> chunkProgress, int totalSize) async {
    await _lock.synchronized(() async {
      _ensureOpen();

      final line = jsonEncode({
        't': 'checkpoint',
        'chunks': chunkProgress,
        'total': totalSize,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

      _sink!.writeln(line);
      await _sink!.flush();

      _approxBytes += line.length + 1;

      if (compactionThresholdBytes > 0 &&
          _approxBytes >= compactionThresholdBytes) {
        await _compactLocked(chunkProgress, totalSize);
      }
    });
  }

  /// Recovers the latest chunk progress from a journal file.
  static Future<List<int>?> recover(String journalPath) async {
    final file = File(journalPath);
    if (!await file.exists()) return null;

    List<int>? lastCheckpoint;
    int? threadCount;

    try {
      final lines = file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        try {
          final event = jsonDecode(trimmed) as Map<String, dynamic>;

          switch (event['t']) {
            case 'init':
              threadCount = event['threads'] as int?;
              lastCheckpoint = List.filled(threadCount ?? 0, 0);
              break;

            case 'checkpoint':
              final chunks = event['chunks'] as List<dynamic>?;
              if (chunks != null) {
                lastCheckpoint = chunks.map((e) => (e as num).toInt()).toList();
              }
              break;

            case 'chunk':
              if (lastCheckpoint != null) {
                final i = event['i'] as int?;
                final b = event['b'] as int?;

                if (i != null &&
                    b != null &&
                    i >= 0 &&
                    i < lastCheckpoint.length) {
                  lastCheckpoint[i] = b;
                }
              }
              break;
          }
        } catch (_) {
          // Ignore malformed lines.
        }
      }
    } catch (e) {
      debugPrint('[DownloadJournal] Recovery failed for $journalPath: $e');
      return null;
    }

    if (lastCheckpoint != null && lastCheckpoint.isEmpty) {
      debugPrint(
        '[DownloadJournal] Recovery for $journalPath yielded empty checkpoint. '
        'Treating as no journal.',
      );
      return null;
    }

    return lastCheckpoint;
  }

  Future<void> close() async {
    await _lock.synchronized(() async {
      await _closeLocked();
    });
  }

  Future<void> delete() async {
    await _lock.synchronized(() async {
      await _closeLocked();
    });

    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('[DownloadJournal] Failed to delete journal $path: $e');
    }
  }

  Future<void> _closeLocked() async {
    if (!_isOpen) return;

    _isOpen = false;

    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {
      // Ignore close errors.
    }

    _sink = null;
  }

  Future<void> _compactLocked(List<int> chunkProgress, int totalSize) async {
    try {
      await _sink?.flush();
      await _sink?.close();

      final tmp = File('$path.tmp');

      final initLine = jsonEncode({
        't': 'init',
        'threads': chunkProgress.length,
        'total': totalSize,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

      final checkpointLine = jsonEncode({
        't': 'checkpoint',
        'chunks': chunkProgress,
        'total': totalSize,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });

      await tmp.writeAsString('$initLine\n$checkpointLine\n');
      await tmp.rename(path);

      _sink = File(path).openWrite(mode: FileMode.append);
      _isOpen = true;
      _approxBytes = initLine.length + checkpointLine.length + 2;
    } catch (e) {
      debugPrint('[DownloadJournal] Compaction failed for $path: $e');

      try {
        await File('$path.tmp').delete();
      } catch (_) {}

      // Best effort: try to reopen in append mode so writes can continue.
      try {
        _sink = File(path).openWrite(mode: FileMode.append);
        _isOpen = true;
      } catch (_) {
        _isOpen = false;
        _sink = null;
      }
    }
  }

  void _ensureOpen() {
    if (!_isOpen || _sink == null) {
      throw StateError('Journal not opened. Call open() first.');
    }
  }

  static int crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ 0xEDB88320;
        } else {
          crc >>= 1;
        }
      }
    }
    return crc ^ 0xFFFFFFFF;
  }
}
