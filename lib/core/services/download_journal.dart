import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:synchronized/synchronized.dart';
import '../constants/thresholds.dart';
import 'crash_reporting_service.dart';
import 'diagnostic_service.dart';
import 'download_engine.dart';
import 'logging_service.dart';
import 'power_monitor.dart';
import 'transfer_state.dart';

export 'transfer_state.dart'
    show ChunkState, DmxStateStatus, StateLoadResult, TransferState;

/// Factory for managing named or isolated [StateStoreInstance] instances without static mutable state.
class StateStoreFactory {
  final Map<String, StateStoreInstance> _stores = {};

  StateStoreInstance getOrCreate({String name = 'default'}) {
    return _stores.putIfAbsent(name, () => StateStoreInstance());
  }

  StateStoreInstance get defaultStore => getOrCreate(name: 'default');
}

/// Instance-based persistent state store for downloads with internal Lock synchronization.
class StateStoreInstance {
  StateStoreInstance();

  final Lock _lock = Lock();
  final Map<String, int> _lastFingerprints = {};
  final Map<String, int> _lastWrittenBytes = {};
  final Map<String, DateTime> _lastSaveTimes = {};
  final Map<String, DmxStateStatus> _lastWrittenStatus = {};
  final LinkedHashMap<String, Lock> _pathLocks = LinkedHashMap<String, Lock>();
  final Set<String> _heldPaths = <String>{};
  static const int _maxPathLocks = 64;
  static const int _maxCachedPayloads = kStateCacheMaxPayloads;

  @visibleForTesting
  int get pathLockCount => _pathLocks.length;

  Lock _acquirePathLock(String targetPath) {
    if (_pathLocks.containsKey(targetPath)) {
      final lock = _pathLocks.remove(targetPath)!;
      _pathLocks[targetPath] = lock;
      return lock;
    }
    if (_pathLocks.length >= _maxPathLocks) {
      for (final key in _pathLocks.keys.toList()) {
        if (!_heldPaths.contains(key)) {
          _pathLocks.remove(key);
          if (_pathLocks.length < _maxPathLocks) break;
        }
      }
    }
    final lock = Lock();
    _pathLocks[targetPath] = lock;
    return lock;
  }

  // Enable SHA-256 state save strict deduplication by default
  bool stateSaveStrictDedup = true;

  String pathFor(String tempFilePath, {String? taskId}) {
    if (taskId != null && taskId.isNotEmpty) {
      return '$tempFilePath.$taskId.dmxstate';
    }
    return '$tempFilePath.dmxstate';
  }

  String _legacyPathFor(String tempFilePath) => '$tempFilePath.dmxstate';

  Future<TransferState?> load(String tempFilePath, {String? taskId}) async {
    final path = pathFor(tempFilePath, taskId: taskId);
    var file = File(path);
    if (!await file.exists() && taskId != null && taskId.isNotEmpty) {
      final legacyFile = File(_legacyPathFor(tempFilePath));
      if (await legacyFile.exists()) {
        file = legacyFile;
      }
    }
    if (!await file.exists()) {
      final tmpFile = File('${file.path}.tmp');
      if (await tmpFile.exists()) {
        try {
          final decoded = jsonDecode(await tmpFile.readAsString());
          if (decoded is Map) {
            final json = Map<String, dynamic>.from(decoded);
            return TransferState.tryParseV3(json) ??
                TransferState.tryParseV2(json);
          }
        } catch (e, st) {
          LoggingService.logger('DownloadJournal')
              .warning('Failed to load tmp state file', e, st);
        }
      }
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        final json = Map<String, dynamic>.from(decoded);
        return TransferState.tryParseV3(json) ?? TransferState.tryParseV2(json);
      }
    } catch (e, st) {
      LoggingService.logger('DownloadJournal')
          .warning('Failed to load state file', e, st);
    }
    return null;
  }

  Future<StateLoadResult> loadOrCreate(
    String tempFilePath, {
    required String url,
    required int threadCount,
    required int knownFileSize,
    String? taskId,
  }) async {
    final path = pathFor(tempFilePath, taskId: taskId);
    var file = File(path);
    TransferState? state;
    String? migratedFrom;

    if (!await file.exists() && taskId != null && taskId.isNotEmpty) {
      final legacyFile = File(_legacyPathFor(tempFilePath));
      if (await legacyFile.exists()) {
        file = legacyFile;
        migratedFrom = 'legacy_path';
      }
    }

    // FIX-C2: Validate tmp file before accepting it; if unparseable, delete and fall back
    var effectivePath = file.path;
    final tmpStale = File('$path.tmp');
    if (!await file.exists() && await tmpStale.exists()) {
      bool tmpValid = false;
      try {
        final decoded = jsonDecode(await tmpStale.readAsString());
        if (decoded is Map) {
          final json = Map<String, dynamic>.from(decoded);
          if (TransferState.tryParseV3(json) != null ||
              TransferState.tryParseV2(json) != null) {
            tmpValid = true;
          }
        }
      } catch (e) {
        debugPrint('[DmxState] unreadable tmp state at ${tmpStale.path}: $e');
      }
      if (tmpValid) {
        effectivePath = '$path.tmp';
      } else {
        try {
          await tmpStale.delete();
        } catch (e, st) {
          LoggingService.logger('DownloadJournal')
              .warning('Failed to delete unreadable tmp state file', e, st);
        }
      }
    }

    // FIX-C1: Multi-stage parse trying V3, then V2, before falling back to journal recovery
    if (await File(effectivePath).exists()) {
      try {
        final decoded = jsonDecode(await File(effectivePath).readAsString());
        if (decoded is Map) {
          final json = Map<String, dynamic>.from(decoded);
          state = TransferState.tryParseV3(json);
          if (state == null) {
            state = TransferState.tryParseV2(json);
            state ??= _migrateV2(json, threadCount);
            if (state != null) migratedFrom = 'v2';
          }
          // FIX M-11: Log a warning when both parsers fail on non-empty valid JSON.
          // Silent failures here cause resume-from-zero for large downloads with no
          // diagnostic trace. Log the JSON keys so schema regressions are identifiable.
          if (state == null && json.isNotEmpty) {
            LoggingService.logger('DownloadJournal').warning(
              'State file at $effectivePath is valid JSON but neither V3 nor V2 '
              'parser could decode it. Keys: ${json.keys.toList()}. '
              'Download will restart from zero.',
            );
            try {
              final backupPath = '$effectivePath.bak';
              await File(effectivePath).copy(backupPath);
              LoggingService.logger('DownloadJournal').info(
                'Corrupted state file backed up to $backupPath',
              );
            } catch (backupErr, st) {
              LoggingService.logger('DownloadJournal').warning(
                'Failed to backup corrupted state file',
                backupErr,
                st,
              );
            }
          }
        }
      } catch (e) {
        debugPrint(
            '[DmxState] [WARNING] unreadable state at $effectivePath: $e');
        try {
          final backupPath = '$effectivePath.bak';
          await File(effectivePath).copy(backupPath);
          LoggingService.logger('DownloadJournal').info(
            'Unreadable state file backed up to $backupPath',
          );
        } catch (backupErr, st) {
          LoggingService.logger('DownloadJournal').warning(
            'Failed to backup unreadable state file',
            backupErr,
            st,
          );
        }
        state = null;
      }
    }

    // Unified WAL Recovery:
    // 1. Snapshot (.dmxstate) is loaded if valid.
    // 2. Journal (.journal) is parsed with detail timestamps & chunk progress.
    // 3. If snapshot is newer than journal head, use snapshot.
    // 4. If journal has newer events or snapshot is missing, replay journal.
    // 5. If both are corrupt/missing, perform clean restart (0 progress).
    final journalDetails =
        await DownloadJournal.recoverWithDetails('$tempFilePath.journal');

    if (journalDetails != null && journalDetails.chunkBytes.isNotEmpty) {
      if (state == null) {
        state = _stateFromChunkBytes(
          tempFilePath: tempFilePath,
          url: url,
          threadCount:
              journalDetails.threadCount ?? journalDetails.chunkBytes.length,
          chunkBytes: journalDetails.chunkBytes,
          totalSize: journalDetails.totalSize ?? knownFileSize,
        );
        for (var i = 0; i < state.chunks.length; i++) {
          if (journalDetails.chunkHashes.containsKey(i)) {
            state.chunks[i].hash = journalDetails.chunkHashes[i];
          }
        }
        migratedFrom = 'journal';
      } else {
        final snapshotTs = state.updatedAt.millisecondsSinceEpoch;
        if (journalDetails.maxTimestamp > snapshotTs) {
          var replayedAny = false;
          for (var i = 0;
              i < min(state.chunks.length, journalDetails.chunkBytes.length);
              i++) {
            if (journalDetails.chunkBytes[i] > state.chunks[i].downloaded) {
              state.chunks[i].downloaded = journalDetails.chunkBytes[i];
              replayedAny = true;
            }
            if (journalDetails.chunkHashes.containsKey(i)) {
              state.chunks[i].hash = journalDetails.chunkHashes[i];
            }
          }
          if (replayedAny) {
            state.migrationNote =
                '${state.migrationNote ?? ''} journal_replayed'.trim();
          }
        }
      }
    }

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
        try {
          await tmp.delete();
        } catch (e, st) {
          LoggingService.logger('DownloadJournal')
              .warning('Failed to delete temp file during loadOrCreate', e, st);
        }
      }
    }

    var created = false;
    if (state == null) {
      created = true;
      state = TransferState(
        totalSize: knownFileSize,
        threadCount:
            threadCount.clamp(kMinTransferThreads, kMaxTransferThreads),
        chunks: const [],
        url: url,
      );
    }

    final adjusted = await _reconcileWithDisk(tempFilePath, state);

    // J2 Invariant: If a journal file exists, clear it after state reconciliation
    // and persist a durable compacted snapshot to disk.
    final journalFile = File('$tempFilePath.journal');
    if (await journalFile.exists()) {
      await save(tempFilePath, state, durable: true, taskId: taskId);
      await DownloadJournal.clearJournalFor(tempFilePath);
    }

    return StateLoadResult(
      state: state,
      created: created,
      migratedFrom: migratedFrom,
      diskAdjusted: adjusted,
    );
  }

  TransferState _stateFromChunkBytes({
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

  TransferState? _migrateV2(Map<String, dynamic> json, int hintThreads) {
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

  Future<bool> _reconcileWithDisk(
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
      try {
        final raf = await f.open(mode: FileMode.append);
        await raf.truncate(state.totalSize);
        await raf.close();
      } catch (e, st) {
        LoggingService.logger('DownloadJournal')
            .warning('Failed to truncate oversized disk file', e, st);
      }
      adjusted = true;
    }

    if (state.threadCount <= 1 && state.chunks.length <= 1) {
      // Single-thread: file length is authoritative
      for (final c in state.chunks) {
        if (c.start + c.downloaded > len) {
          final newDownloaded = max(0, len - c.start);
          if (c.downloaded != newDownloaded) {
            c.downloaded = newDownloaded;
            adjusted = true;
          }
        }
      }
    } else {
      // Multi-thread: state file is authoritative because files are pre-allocated.
      // Only cap if file is physically smaller than chunk start or downloaded offset.
      if (len < state.totalSize && len < state.downloadedBytes) {
        for (final c in state.chunks) {
          if (c.start >= len) {
            if (c.downloaded > 0) {
              c.downloaded = 0;
              adjusted = true;
            }
          } else if (c.start + c.downloaded > len) {
            final available = len - c.start;
            final cap = c.size >= 0 ? c.size : (available < 0 ? 0 : available);
            final newDownloaded = available < 0 ? 0 : available.clamp(0, cap);
            if (c.downloaded != newDownloaded) {
              c.downloaded = newDownloaded;
              adjusted = true;
            }
          }
        }
      }
    }

    if (adjusted) {
      state.migrationNote =
          '${state.migrationNote ?? ''} disk_reconciled'.trim();
    }
    return adjusted;
  }

  /// Computes a lightweight structural fingerprint of [TransferState] in O(N) time
  /// without allocating memory or serializing to JSON.
  int computeFingerprint(TransferState state) {
    int chunksHash = 0;
    for (var i = 0; i < state.chunks.length; i++) {
      final c = state.chunks[i];
      chunksHash ^= (c.downloaded * 31 + c.start + i);
    }
    return Object.hash(
      state.status.index,
      state.downloadedBytes,
      state.totalSize,
      state.threadCount,
      chunksHash,
    );
  }

  void removeCachedPayload(String targetPath) {
    _lock.synchronized(() {
      _lastFingerprints.remove(targetPath);
      _lastWrittenBytes.remove(targetPath);
      _lastSaveTimes.remove(targetPath);
      _lastWrittenStatus.remove(targetPath);
    });
  }

  void removeTaskState(String targetPath) => removeCachedPayload(targetPath);

  Future<void> save(
    String tempFilePath,
    TransferState state, {
    bool durable = false,
    bool screenOff = false,
    String? taskId,
  }) async {
    final targetPath = pathFor(tempFilePath, taskId: taskId);
    late final Lock pathLock;
    DateTime? lastSave;
    int? lastWrittenByte;
    DmxStateStatus? lastStatus;
    int? lastFp;

    await _lock.synchronized(() {
      pathLock = _acquirePathLock(targetPath);
      _heldPaths.add(targetPath);
      lastSave = _lastSaveTimes[targetPath];
      lastWrittenByte = _lastWrittenBytes[targetPath];
      lastStatus = _lastWrittenStatus[targetPath];
      lastFp = _lastFingerprints[targetPath];
    });

    try {
      return await pathLock.synchronized(() async {
        final isScreenOff = screenOff || PowerMonitor.screenOff;
        final isBg = isScreenOff ||
            !DownloadEngine.appInForeground ||
            DownloadEngine.isInBackground;
        final tmpPath = '$targetPath.tmp';
        try {
          final now = DateTime.now();

          final bytesSinceLastWrite =
              (state.downloadedBytes - (lastWrittenByte ?? 0)).abs();
          final statusChanged =
              lastStatus != null && lastStatus != state.status;
          final isTerminalOrPaused = state.status == DmxStateStatus.paused ||
              state.status == DmxStateStatus.complete ||
              state.status == DmxStateStatus.failed;
          final isDurable = durable || statusChanged || isTerminalOrPaused;

          // Task 2.1: Maximum 1 disk write per 5 seconds per task for non-durable saves
          if (!isDurable && lastSave != null) {
            if (now.difference(lastSave!) < const Duration(seconds: 5)) {
              return;
            }
            if (isBg) {
              if (now.difference(lastSave!) < kStateSaveBgInterval &&
                  bytesSinceLastWrite < kStateSaveBgDelta) {
                return;
              }
            } else {
              if (now.difference(lastSave!) < kStateSaveFgInterval &&
                  bytesSinceLastWrite < kStateSaveFgDelta) {
                return;
              }
            }
          }

          // Screen-off threshold: always write when paused or status changed or durable
          if (state.status == DmxStateStatus.paused || isDurable) {
            // Never skip when paused or durable
          } else if (isScreenOff && bytesSinceLastWrite < 5 * 1024 * 1024) {
            return; // skip small deltas when screen off (< 5MB)
          }

          // Lightweight structural deduplication: skips redundant writes in O(N) without jsonEncode or SHA-256
          final fingerprint = computeFingerprint(state);
          if (!isDurable) {
            if (lastFp == fingerprint) {
              return; // Skip redundant state write without JSON serialization
            }
          }

          // M3 (Plan 03 Task 3.5): cross-isolate stale-write guard. Durable
          // writes are the only ones issued from the main isolate (the
          // background_service dataSync checkpoint reconstructs a TransferState
          // from coarse DB-derived per-chunk *fractions* — staler and less
          // precise than the worker isolate's byte-accurate snapshot). Because
          // the dedup caches (_lastWrittenBytes etc.) are per-isolate, they
          // cannot observe a peer isolate's fresher write, so we consult the
          // on-disk snapshot directly and refuse any durable write that would
          // regress byte progress or un-complete a finished download. The pause
          // status the main isolate wants to persist is stored on the DB row
          // independently, so preserving the fresher snapshot loses nothing.
          if (isDurable) {
            final existing = await _readExistingProgress(targetPath);
            if (existing != null) {
              final incomingBytes = state.downloadedBytes;
              final regressesBytes = existing.bytes > incomingBytes;
              final unCompletes =
                  existing.status == DmxStateStatus.complete.name &&
                      state.status != DmxStateStatus.complete;
              if (regressesBytes || unCompletes) {
                DiagnosticService.instance.recordTelemetryAlert(
                  'stale_state_write_skipped',
                  taskId: taskId,
                  details: 'onDisk=${existing.bytes} incoming=$incomingBytes '
                      'onDiskStatus=${existing.status} '
                      'incomingStatus=${state.status.name}',
                );
                return;
              }
            }
          }

          // Ensure journal (if present) is flushed/fsync'd before writing state
          final journalFile = File('$tempFilePath.journal');
          if (await journalFile.exists()) {
            try {
              final jRaf =
                  await journalFile.open(mode: FileMode.writeOnlyAppend);
              try {
                await jRaf.flush();
              } finally {
                await jRaf.close();
              }
            } catch (_) {}
          }

          state.updatedAt = now;
          final payload = jsonEncode(state.toJson());
          final tmp = File(tmpPath);
          await tmp.parent.create(recursive: true);
          if (isDurable) {
            await tmp.writeAsString(payload, flush: true);
            if (!kIsWeb) {
              try {
                final raf = await tmp.open(mode: FileMode.writeOnlyAppend);
                try {
                  await raf.flush();
                } finally {
                  await raf.close();
                }
              } catch (_) {}
            }
          } else {
            await tmp.writeAsString(payload, flush: false);
          }
          try {
            await tmp.rename(targetPath);
          } catch (e) {
            final tmp2 = File('$targetPath.tmp2');
            try {
              final bytes = await tmp.readAsBytes();
              await tmp2.writeAsBytes(bytes, flush: true);
              final targetFile = File(targetPath);
              if (await targetFile.exists()) {
                try {
                  await targetFile.delete();
                } catch (_) {}
              }
              await tmp2.rename(targetPath);
            } catch (e2) {
              final bytes = await tmp.readAsBytes();
              await File(targetPath).writeAsBytes(bytes, flush: true);
            } finally {
              try {
                if (await tmp2.exists()) await tmp2.delete();
              } catch (_) {}
            }
          } finally {
            try {
              if (await tmp.exists()) await tmp.delete();
            } catch (_) {}
          }

          // Mutate dedup cache ONLY after successful write to disk:
          _lastFingerprints[targetPath] = fingerprint; // LRU recency update
          _lastSaveTimes[targetPath] = now;
          _lastWrittenStatus[targetPath] = state.status;
          _lastWrittenBytes[targetPath] = state.downloadedBytes;
          StateStore.markSaveSuccess();

          if (_lastFingerprints.length > _maxCachedPayloads) {
            final keysToRemove = _lastFingerprints.keys
                .take(_lastFingerprints.length - _maxCachedPayloads)
                .toList();
            for (final key in keysToRemove) {
              _lastFingerprints.remove(key);
              _lastWrittenBytes.remove(key);
              _lastSaveTimes.remove(key);
              _lastWrittenStatus.remove(key);
            }
          }
        } catch (e, stackTrace) {
          // M-2/M-4: don't silently swallow persistence failures. A failing
          // disk (full / read-only / EIO) previously left resume state stale
          // with only a debugPrint; now it is counted and surfaced.
          StateStore.recordSaveFailure(tempFilePath, e, stackTrace);
        }
      });
    } finally {
      await _lock.synchronized(() {
        _heldPaths.remove(targetPath);
      });
    }
  }

  /// M3 (Plan 03 Task 3.5): reads the byte progress and status recorded in the
  /// on-disk `.dmxstate` snapshot at [targetPath]. Used by [save] to detect
  /// whether an incoming durable write would regress a fresher snapshot written
  /// by a peer isolate. Byte total mirrors [TransferState.downloadedBytes] (sum
  /// of per-chunk progress, clamped to totalSize). Returns null when the file is
  /// absent or unparseable — fail-open, so a parse failure never blocks a write.
  Future<({int bytes, String status})?> _readExistingProgress(
      String targetPath) async {
    try {
      final file = File(targetPath);
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final json = Map<String, dynamic>.from(decoded);
      final totalSize = (json['totalSize'] as num?)?.toInt() ?? 0;
      var bytes = 0;
      final progress = json['progress'];
      if (progress is List) {
        for (final p in progress) {
          if (p is num) bytes += p.toInt();
        }
      } else {
        final chunks = json['chunks'];
        if (chunks is List) {
          for (final c in chunks) {
            if (c is Map) {
              bytes += (c['downloaded'] as num?)?.toInt() ?? 0;
            }
          }
        }
      }
      if (totalSize > 0 && bytes > totalSize) bytes = totalSize;
      final status = (json['status'] as String?) ?? '';
      return (bytes: bytes, status: status);
    } catch (_) {
      return null; // fail-open: never block a legitimate write on a parse error
    }
  }

  /// Atomically resets transfer state by clearing progress in [state],
  /// deleting the snapshot (.dmxstate) and journal (.journal) files together (J1),
  /// and optionally removing the temp data file.
  Future<void> resetTransferState(
    String tempFilePath, {
    String? taskId,
    TransferState? state,
    bool deleteTempFile = false,
  }) async {
    final targetPath = pathFor(tempFilePath, taskId: taskId);
    final pathLock =
        await _lock.synchronized(() => _acquirePathLock(targetPath));

    _lock.synchronized(() {
      _heldPaths.add(targetPath);
    });

    try {
      await pathLock.synchronized(() async {
        // 1. Clear memory dedup caches
        _lock.synchronized(() {
          _lastFingerprints.remove(targetPath);
          _lastWrittenBytes.remove(targetPath);
          _lastSaveTimes.remove(targetPath);
          _lastWrittenStatus.remove(targetPath);
        });

        // 2. Delete state file and its tmp/bak variants
        for (final p in [
          targetPath,
          '$targetPath.tmp',
          '$targetPath.tmp2',
          '$targetPath.bak',
        ]) {
          try {
            final f = File(p);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }

        // 3. Delete journal atomically with snapshot (J1)
        await DownloadJournal.deleteJournalFor(tempFilePath);

        if (taskId != null && taskId.isNotEmpty) {
          final legacyPath = _legacyPathFor(tempFilePath);
          _lock.synchronized(() {
            _lastFingerprints.remove(legacyPath);
            _lastWrittenBytes.remove(legacyPath);
            _lastSaveTimes.remove(legacyPath);
            _lastWrittenStatus.remove(legacyPath);
          });
          for (final p in [
            legacyPath,
            '$legacyPath.tmp',
            '$legacyPath.tmp2',
            '$legacyPath.bak',
          ]) {
            try {
              final f = File(p);
              if (await f.exists()) await f.delete();
            } catch (_) {}
          }
        }

        // 4. Zero out in-memory state if supplied
        if (state != null) {
          for (final c in state.chunks) {
            c.downloaded = 0;
            c.hash = null;
          }
        }

        // 5. Delete temp payload file if requested
        if (deleteTempFile) {
          try {
            final f = File(tempFilePath);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      });
    } finally {
      _lock.synchronized(() {
        _heldPaths.remove(targetPath);
        _pathLocks.remove(targetPath);
        if (taskId != null && taskId.isNotEmpty) {
          _pathLocks.remove(_legacyPathFor(tempFilePath));
        }
      });
    }
  }

  Future<void> remove(String tempFilePath, {String? taskId}) async {
    return resetTransferState(tempFilePath, taskId: taskId);
  }
}

/// Static facade for [StateStoreInstance] providing backward-compatible access.
abstract class StateStore {
  static final StateStoreInstance _fallbackStore = StateStoreInstance();

  static StateStoreInstance get instance {
    if (GetIt.instance.isRegistered<StateStoreFactory>()) {
      return GetIt.instance<StateStoreFactory>().defaultStore;
    }
    if (GetIt.instance.isRegistered<StateStoreInstance>()) {
      return GetIt.instance<StateStoreInstance>();
    }
    return _fallbackStore;
  }

  // ── Persistence-failure observability (Plan 01 M-4 / Plan 03 M2) ──────────
  // save() swallows internal write errors so a live download is never torn
  // down by a transient disk hiccup, but silent swallowing (previously just a
  // debugPrint) hid genuine failures: on a full/read-only disk the resume
  // state silently stopped advancing with no telemetry and no user signal.
  // These counters make every failure observable and expose a degraded flag.
  static int _consecutiveSaveFailures = 0;
  static int totalSaveFailures = 0;
  static Object? lastSaveError;

  /// True after repeated consecutive persistence failures — resume state can
  /// no longer be trusted to be current. Cleared by the next successful save.
  /// (Per-isolate: reflects failures observed in the isolate that reads it.)
  static bool get persistenceDegraded => _consecutiveSaveFailures >= 3;

  static void recordSaveFailure(String path, Object error, StackTrace st) {
    _consecutiveSaveFailures++;
    totalSaveFailures++;
    lastSaveError = error;
    DiagnosticService.instance.record(
      'persistence',
      'State save failed (#$_consecutiveSaveFailures consecutive)',
      error: error,
      details: 'path=$path',
    );
    unawaited(CrashReportingService.recordError(
      error,
      st,
      hint: 'StateStore.save persistence failure',
    ));
  }

  static void markSaveSuccess() {
    if (_consecutiveSaveFailures != 0) _consecutiveSaveFailures = 0;
  }

  static bool get stateSaveStrictDedup => instance.stateSaveStrictDedup;
  static set stateSaveStrictDedup(bool val) =>
      instance.stateSaveStrictDedup = val;

  static String pathFor(String tempFilePath, {String? taskId}) =>
      instance.pathFor(tempFilePath, taskId: taskId);

  static Future<TransferState?> load(String tempFilePath, {String? taskId}) =>
      instance.load(tempFilePath, taskId: taskId);

  static Future<StateLoadResult> loadOrCreate(
    String tempFilePath, {
    required String url,
    required int threadCount,
    required int knownFileSize,
    String? taskId,
  }) =>
      instance.loadOrCreate(
        tempFilePath,
        url: url,
        threadCount: threadCount,
        knownFileSize: knownFileSize,
        taskId: taskId,
      );

  static Future<void> save(
    String tempFilePath,
    TransferState state, {
    bool durable = false,
    bool screenOff = false,
    String? taskId,
  }) =>
      instance.save(
        tempFilePath,
        state,
        durable: durable,
        screenOff: screenOff,
        taskId: taskId,
      );

  static Future<void> resetTransferState(
    String tempFilePath, {
    String? taskId,
    TransferState? state,
    bool deleteTempFile = false,
  }) =>
      instance.resetTransferState(
        tempFilePath,
        taskId: taskId,
        state: state,
        deleteTempFile: deleteTempFile,
      );

  static Future<void> remove(String tempFilePath, {String? taskId}) =>
      instance.remove(tempFilePath, taskId: taskId);

  static int computeFingerprint(TransferState state) =>
      instance.computeFingerprint(state);

  static void removeCachedPayload(String targetPath) =>
      instance.removeCachedPayload(targetPath);

  static void removeTaskState(String targetPath) =>
      instance.removeTaskState(targetPath);
}

class JournalRecoveryData {
  final List<int> chunkBytes;
  final Map<int, String> chunkHashes;
  final int? totalSize;
  final int? threadCount;
  final int maxTimestamp;

  const JournalRecoveryData({
    required this.chunkBytes,
    required this.chunkHashes,
    this.totalSize,
    this.threadCount,
    this.maxTimestamp = 0,
  });
}

class DownloadJournal {
  static final Set<DownloadJournal> _activeJournals = {};

  /// Flushes and fsyncs the journal corresponding to [tempFilePath].
  // FIX P1-4: Exact match, not prefix. Previously '/a/b' matched '/a/b2.journal'
  static Future<void> flushAndSyncForFile(String tempFilePath) async {
    final journalPath = '$tempFilePath.journal';
    final active = _activeJournals
        .where((j) => j.path == journalPath)
        .firstOrNull;
    if (active != null) {
      await active.flushAndSync();
    } else {
      final journalFile = File('$tempFilePath.journal');
      if (await journalFile.exists()) {
        try {
          final jRaf = await journalFile.open(mode: FileMode.writeOnlyAppend);
          try {
            await jRaf.flush();
          } finally {
            await jRaf.close();
          }
        } catch (_) {}
      }
    }
  }

  /// Flushes and fsyncs all currently active/open download journals to disk immediately.
  static Future<void> flushAllActive() async {
    final active = _activeJournals.toList();
    for (final j in active) {
      try {
        await j.flushAndSync();
      } catch (e, st) {
        LoggingService.logger('DownloadJournal')
            .warning('flushAllActive failed for ${j.path}', e, st);
      }
    }
  }

  final String path;
  IOSink? _sink;
  bool _isOpen = false;
  int _approxBytes = 0;
  int _bytesSinceLastFsync = 0;
  int _flushCounter = 0;
  int _lastFlushRecordCount = 0;
  final int compactionThresholdBytes;
  final Lock _lock = Lock();

  DownloadJournal(this.path,
      {this.compactionThresholdBytes = kJournalCompactionThreshold});

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
      _activeJournals.add(this);
    });
  }

  /// Forces an immediate flush and fsync of all unwritten journal buffers to disk.
  Future<void> flushAndSync() async {
    await _lock.synchronized(() async {
      if (!_isOpen || _sink == null) return;
      await _sink!.flush();
      await _fsyncLocked();
      _bytesSinceLastFsync = 0;
      _lastFlushRecordCount = _flushCounter;
    });
  }

  Future<void> _fsyncLocked() async {
    if (_sink != null) {
      await _sink!.flush();
    }
    if (!kIsWeb) {
      try {
        final raf = await File(path).open(mode: FileMode.writeOnlyAppend);
        try {
          await raf.flush();
        } finally {
          await raf.close();
        }
      } catch (e, st) {
        LoggingService.logger('DownloadJournal')
            .fine('fsync on journal file failed', e, st);
      }
    }
  }

  Future<void> writeInit(int threadCount, int totalSize) async {
    await _lock.synchronized(() async {
      _ensureOpen();
      if (_approxBytes > 0) {
        return;
      }
      final payload = _withCrc({
        't': 'init',
        'v': 2,
        'threads': threadCount,
        'total': totalSize,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      _sink!.writeln(payload);
      await _sink!.flush();
      _approxBytes += payload.length + 1;
    });
  }

  /// Access-ordered LRU of the last recorded byte-count per chunk index,
  /// capped at [maxRecordedEntries] (one entry per chunk across all jobs).
  final LinkedHashMap<int, int> _lastRecordedChunkBytes = LinkedHashMap();
  static const int maxRecordedEntries = kJournalMaxBgRecordedEntries;
  int _lastGlobalWriteBytes = 0;

  Future<void> recordChunkProgress(int index, int bytes,
      {String? hash, bool force = false}) async {
    // Disable chunk journal writes entirely when screen is off
    if (PowerMonitor.screenOff && !force) return;

    final isBg =
        !DownloadEngine.appInForeground || DownloadEngine.isInBackground;

    final threshold =
        isBg ? kJournalBackgroundWriteDelta : kJournalForegroundWriteDelta;

    await _lock.synchronized(() async {
      _lastRecordedChunkBytes[index] = bytes;
      while (_lastRecordedChunkBytes.length > maxRecordedEntries) {
        _lastRecordedChunkBytes.remove(_lastRecordedChunkBytes.keys.first);
      }

      final totalWritten = _lastRecordedChunkBytes.values
          .toList()
          .fold<int>(0, (sum, b) => sum + b);
      final totalBytesSinceLastWrite =
          (totalWritten - _lastGlobalWriteBytes).abs();

      if (!force && hash == null && totalBytesSinceLastWrite < threshold) {
        return;
      }
      _lastGlobalWriteBytes = totalWritten;

      _ensureOpen();
      final line = _withCrc({
        't': 'chunk',
        'i': index,
        'b': bytes,
        if (hash != null) 'h': hash,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      _sink!.writeln(line);
      final lineBytes = line.length + 1;
      _approxBytes += lineBytes;
      _bytesSinceLastFsync += lineBytes;
      _flushCounter++;

      if (_bytesSinceLastFsync >= 1024 * 1024) {
        await _fsyncLocked();
        _bytesSinceLastFsync = 0;
        _lastFlushRecordCount = _flushCounter;
      } else {
        final flushInterval = PowerMonitor.screenOff ? 1000 : (isBg ? 500 : 50);
        if (_flushCounter - _lastFlushRecordCount >= flushInterval) {
          await _sink!.flush();
          _lastFlushRecordCount = _flushCounter;
        }
      }
    });
  }

  Future<void> writeCheckpoint(
    List<int> chunkProgress,
    int totalSize, {
    Map<int, String>? hashes,
    bool truncateDeltas = true,
  }) async {
    await _lock.synchronized(() async {
      _ensureOpen();
      final line = _withCrc({
        't': 'checkpoint',
        'v': 2,
        'chunks': chunkProgress,
        'total': totalSize,
        if (hashes != null && hashes.isNotEmpty)
          'hashes': {for (final e in hashes.entries) e.key.toString(): e.value},
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      _sink!.writeln(line);
      await _fsyncLocked();
      _approxBytes += line.length + 1;
      if (truncateDeltas ||
          (compactionThresholdBytes > 0 &&
              _approxBytes >= compactionThresholdBytes)) {
        await _compactLocked(chunkProgress, totalSize, hashes: hashes);
      }
    });
  }

  /// Appends a CRC32 checksum field (`c`) computed over the payload *without*
  /// the checksum field. Dart maps preserve insertion order, so re-encoding
  /// after removing `c` reproduces the exact bytes the checksum was computed
  /// over. Legacy lines without `c` remain recoverable (see [recover]).
  static String _withCrc(Map<String, dynamic> payload) {
    final withoutCrc = jsonEncode(payload);
    final crc = crc32(utf8.encode(withoutCrc));
    payload['c'] = crc;
    return jsonEncode(payload);
  }

  static Future<JournalRecoveryData?> recoverWithDetails(
      String journalPath) async {
    final file = File(journalPath);
    if (!await file.exists()) return null;
    List<int>? lastCheckpoint;
    final chunkHashes = <int, String>{};
    int? threadCount;
    int? totalSize;
    int maxTs = 0;
    var skippedCorrupt = 0;
    try {
      final lines = file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        Map<String, dynamic> event;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is! Map) continue;
          event = Map<String, dynamic>.from(decoded);
        } catch (_) {
          skippedCorrupt++;
          continue;
        }
        final storedCrc = event['c'] as int?;
        if (storedCrc != null) {
          final payload = Map<String, dynamic>.from(event)..remove('c');
          final recomputed = crc32(utf8.encode(jsonEncode(payload)));
          if (recomputed != storedCrc) {
            skippedCorrupt++;
            continue;
          }
        }
        final ts = (event['ts'] as num?)?.toInt() ?? 0;
        if (ts > maxTs) maxTs = ts;
        switch (event['t']) {
          case 'init':
            threadCount = event['threads'] as int?;
            totalSize = (event['total'] as num?)?.toInt();
            lastCheckpoint = List.filled(threadCount ?? 0, 0);
            break;
          case 'checkpoint':
            final chunks = event['chunks'] as List<dynamic>?;
            if (chunks != null) {
              lastCheckpoint = chunks.map((e) => (e as num).toInt()).toList();
            }
            final t = (event['total'] as num?)?.toInt();
            if (t != null && t > 0) totalSize = t;
            final hashes = event['hashes'] as Map<dynamic, dynamic>?;
            if (hashes != null) {
              hashes.forEach((k, v) {
                final idx = int.tryParse(k.toString());
                if (idx != null && v is String) {
                  chunkHashes[idx] = v;
                }
              });
            }
            break;
          case 'chunk':
            final i = event['i'] as int?;
            final b = event['b'] as int?;
            final h = event['h'] as String?;
            if (i != null && b != null && i >= 0) {
              if (lastCheckpoint == null) {
                lastCheckpoint = List.filled(i + 1, 0);
              } else if (i >= lastCheckpoint.length) {
                while (lastCheckpoint.length <= i) {
                  lastCheckpoint.add(0);
                }
              }
              lastCheckpoint[i] = b;
              if (h != null) {
                chunkHashes[i] = h;
              }
            }
            break;
        }
      }
    } catch (e) {
      debugPrint('[DownloadJournal] Recovery failed for $journalPath: $e');
      return null;
    }
    if (skippedCorrupt > 0) {
      debugPrint(
          '[DownloadJournal] Recovery for $journalPath skipped $skippedCorrupt corrupt line(s).');
    }
    if (lastCheckpoint != null && lastCheckpoint.isEmpty) {
      debugPrint(
        '[DownloadJournal] Recovery for $journalPath yielded empty checkpoint. '
        'Treating as no journal.',
      );
      return null;
    }
    if (lastCheckpoint == null) return null;
    return JournalRecoveryData(
      chunkBytes: lastCheckpoint,
      chunkHashes: chunkHashes,
      totalSize: totalSize,
      threadCount: threadCount ?? lastCheckpoint.length,
      maxTimestamp: maxTs,
    );
  }

  static Future<List<int>?> recover(String journalPath) async {
    final details = await recoverWithDetails(journalPath);
    return details?.chunkBytes;
  }

  /// Replays the journal file and recovers downloaded chunk progress.
  static Future<List<int>?> replay(String tempFilePath) async {
    final journalPath = tempFilePath.endsWith('.journal')
        ? tempFilePath
        : '$tempFilePath.journal';
    return recover(journalPath);
  } // FIX-P0-1

  /// Best-effort synchronous close of the journal sink. Clears LRU state and
  /// fires `flush()`/`close()` on the sink without awaiting them; safe to call
  /// from a `finally` block or before deleting the journal file.
  void dispose() {
    _lastRecordedChunkBytes.clear();
    _activeJournals.remove(this);
    if (!_isOpen) return;
    _isOpen = false;
    final sink = _sink;
    _sink = null;
    try {
      sink?.flush();
      sink?.close();
    } catch (e, st) {
      LoggingService.logger('DownloadJournal')
          .warning('Operation failed', e, st);
    }
  }

  Future<void> close() async {
    await _lock.synchronized(() async {
      if (_isOpen && _sink != null && _lastRecordedChunkBytes.isNotEmpty) {
        for (final entry in _lastRecordedChunkBytes.entries) {
          final line = _withCrc({
            't': 'chunk',
            'i': entry.key,
            'b': entry.value,
            'ts': DateTime.now().millisecondsSinceEpoch,
          });
          _sink!.writeln(line);
        }
      }
      _lastRecordedChunkBytes.clear();
      await _fsyncLocked();
      await _closeLocked();
    });
  }

  Future<void> delete() async {
    await _lock.synchronized(() async {
      _lastRecordedChunkBytes.clear();
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

  /// Safely deletes the journal for [tempFilePath], closing any active journal sink first (J1).
  static Future<void> deleteJournalFor(String tempFilePath) async {
    final journalPath = tempFilePath.endsWith('.journal')
        ? tempFilePath
        : '$tempFilePath.journal';
    final active = _activeJournals.where((j) => j.path == journalPath).toList();
    for (final j in active) {
      try {
        await j.close();
      } catch (e, st) {
        LoggingService.logger('DownloadJournal').warning(
            'Failed to close active journal before deletion: $journalPath',
            e,
            st);
      }
    }
    try {
      final file = File(journalPath);
      if (await file.exists()) {
        await file.delete();
        LoggingService.logger('DownloadJournal')
            .info('[Journal-J1] Deleted journal file: $journalPath');
      }
    } catch (e, st) {
      LoggingService.logger('DownloadJournal').warning(
          '[Journal-J1] Failed to delete journal file $journalPath: $e', e, st);
    }
  }

  /// Clears the journal for [tempFilePath] after state replay (J2).
  static Future<void> clearJournalFor(String tempFilePath) async {
    final journalPath = tempFilePath.endsWith('.journal')
        ? tempFilePath
        : '$tempFilePath.journal';
    final active = _activeJournals.where((j) => j.path == journalPath).toList();
    for (final j in active) {
      try {
        await j.close();
      } catch (e, st) {
        LoggingService.logger('DownloadJournal').warning(
            'Failed to close active journal before clearing: $journalPath',
            e,
            st);
      }
    }
    try {
      final file = File(journalPath);
      if (await file.exists()) {
        await file.delete();
        LoggingService.logger('DownloadJournal').info(
            '[Journal-J2] Cleared journal after state replay: $journalPath');
      }
    } catch (e, st) {
      LoggingService.logger('DownloadJournal').warning(
          '[Journal-J2] Failed to clear journal $journalPath: $e', e, st);
    }
  }

  Future<void> _closeLocked() async {
    _activeJournals.remove(this);
    if (!_isOpen) return;
    _isOpen = false;
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (e, st) {
      LoggingService.logger('DownloadJournal')
          .warning('Operation failed', e, st);
    }
    _sink = null;
  }

  Future<void> _compactLocked(
    List<int> chunkProgress,
    int totalSize, {
    Map<int, String>? hashes,
  }) async {
    _isOpen = false;
    try {
      await _sink?.flush();
      await _sink?.close();
      _sink = null;

      final tmp = File('$path.tmp');
      final initLine = _withCrc({
        't': 'init',
        'v': 2,
        'threads': chunkProgress.length,
        'total': totalSize,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      final checkpointLine = _withCrc({
        't': 'checkpoint',
        'v': 2,
        'chunks': chunkProgress,
        'total': totalSize,
        if (hashes != null && hashes.isNotEmpty)
          'hashes': {for (final e in hashes.entries) e.key.toString(): e.value},
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      await tmp.writeAsString('$initLine\n$checkpointLine\n', flush: true);
      await tmp.rename(path);
      _sink = File(path).openWrite(mode: FileMode.append);
      _isOpen = true;
      _approxBytes = initLine.length + checkpointLine.length + 2;
    } catch (e) {
      debugPrint('[DownloadJournal] Compaction failed for $path: $e');
      try {
        await File('$path.tmp').delete();
      } catch (e, st) {
        LoggingService.logger('DownloadJournal')
            .warning('Operation failed', e, st);
      }
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

  /// Calculates CRC32 checksum for journal record verification and benchmarking.
  static int crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        if ((crc & 1) != 0) {
          crc = ((crc >> 1) ^ 0xEDB88320) & 0xFFFFFFFF;
        } else {
          crc = (crc >> 1) & 0xFFFFFFFF;
        }
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
