import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:synchronized/synchronized.dart';
import '../constants/thresholds.dart';
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
        }
      } catch (e) {
        debugPrint(
            '[DmxState] [WARNING] unreadable state at $effectivePath: $e');
        state = null;
      }
    }

    // Replay journal into state if journal exists and is ahead of state
    final journalBytes =
        await DownloadJournal.recover('$tempFilePath.journal');
    if (journalBytes != null && journalBytes.isNotEmpty) {
      if (state == null) {
        state = _stateFromChunkBytes(
          tempFilePath: tempFilePath,
          url: url,
          threadCount: journalBytes.length,
          chunkBytes: journalBytes,
          totalSize: knownFileSize,
        );
        migratedFrom = 'journal';
      } else if (state.chunks.isNotEmpty &&
          journalBytes.length == state.chunks.length) {
        var replayedAny = false;
        for (var i = 0; i < state.chunks.length; i++) {
          if (journalBytes[i] > state.chunks[i].downloaded) {
            state.chunks[i].downloaded = journalBytes[i];
            replayedAny = true;
          }
        }
        if (replayedAny) {
          state.migrationNote =
              '${state.migrationNote ?? ''} journal_replayed'.trim();
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

    final limit = state.totalSize > 0 ? len.clamp(0, state.totalSize) : len;
    for (final c in state.chunks) {
      final chunkStart = c.start;
      final chunkEnd = c.start + c.downloaded;
      if (chunkEnd > len) {
        final available = len - chunkStart;
        final cap = c.size >= 0 ? c.size : (available < 0 ? 0 : available);
        final newDownloaded = available < 0 ? 0 : available.clamp(0, cap);
        if (c.downloaded != newDownloaded) {
          c.downloaded = newDownloaded;
          adjusted = true;
        }
      }
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
    final pathLock =
        await _lock.synchronized(() => _acquirePathLock(targetPath));

    _lock.synchronized(() {
      _heldPaths.add(targetPath);
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
          DateTime? lastSave;
          int? lastWrittenByte;
          DmxStateStatus? lastStatus;
          int? lastFp;

          _lock.synchronized(() {
            lastSave = _lastSaveTimes[targetPath];
            lastWrittenByte = _lastWrittenBytes[targetPath];
            lastStatus = _lastWrittenStatus[targetPath];
            lastFp = _lastFingerprints[targetPath];
          });

          final bytesSinceLastWrite =
              (state.downloadedBytes - (lastWrittenByte ?? 0)).abs();
          final statusChanged =
              lastStatus != null && lastStatus != state.status;

          // Task 2.1: Maximum 1 disk write per 5 seconds per task for non-durable saves
          if (!durable && !statusChanged && lastSave != null) {
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

          // Screen-off threshold: always write when status changed or durable
          if (isScreenOff &&
              !durable &&
              !statusChanged &&
              bytesSinceLastWrite < kStateSaveFgDelta) {
            return; // skip small deltas when screen off
          }

          // Lightweight structural deduplication: skips redundant writes in O(N) without jsonEncode or SHA-256
          final fingerprint = computeFingerprint(state);
          if (!durable && !statusChanged) {
            if (lastFp == fingerprint) {
              return; // Skip redundant state write without JSON serialization
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
          if (durable) {
            await tmp.writeAsString(payload, flush: true);
            if (!kIsWeb) {
              try {
                final raf =
                    await tmp.open(mode: FileMode.writeOnlyAppend);
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
            // Fallback to direct write if rename fails (e.g. file lock on Windows)
            await File(targetPath).writeAsString(payload, flush: true);
            try {
              if (await tmp.exists()) await tmp.delete();
            } catch (_) {}
          }

          // Mutate dedup cache ONLY after successful write to disk:
          _lock.synchronized(() {
            _lastFingerprints.remove(targetPath);
            _lastFingerprints[targetPath] = fingerprint; // LRU recency update
            _lastSaveTimes[targetPath] = now;
            _lastWrittenStatus[targetPath] = state.status;
            _lastWrittenBytes[targetPath] = state.downloadedBytes;

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
          });
        } catch (e) {
          debugPrint('[DmxState] save failed for $tempFilePath: $e');
        }
      });
    } finally {
      _lock.synchronized(() {
        _heldPaths.remove(targetPath);
      });
    }
  }

  Future<void> remove(String tempFilePath, {String? taskId}) async {
    final targetPath = pathFor(tempFilePath, taskId: taskId);
    final pathLock =
        await _lock.synchronized(() => _acquirePathLock(targetPath));

    _lock.synchronized(() {
      _heldPaths.add(targetPath);
    });

    try {
      await pathLock.synchronized(() async {
        _lock.synchronized(() {
          _lastFingerprints.remove(targetPath);
          _lastWrittenBytes.remove(targetPath);
          _lastSaveTimes.remove(targetPath);
          _lastWrittenStatus.remove(targetPath);
        });
        final tmpPath = '$targetPath.tmp';
        try {
          final f = File(targetPath);
          if (await f.exists()) await f.delete();
        } catch (e, st) {
          LoggingService.logger('DownloadJournal')
              .warning('Failed to delete state file on remove', e, st);
        }
        try {
          final tmp = File(tmpPath);
          if (await tmp.exists()) await tmp.delete();
        } catch (e, st) {
          LoggingService.logger('DownloadJournal')
              .warning('Failed to delete tmp state file on remove', e, st);
        }
        if (taskId != null && taskId.isNotEmpty) {
          final legacyPath = _legacyPathFor(tempFilePath);
          _lock.synchronized(() {
            _lastFingerprints.remove(legacyPath);
            _lastWrittenBytes.remove(legacyPath);
            _lastSaveTimes.remove(legacyPath);
            _lastWrittenStatus.remove(legacyPath);
          });
          try {
            final f = File(legacyPath);
            if (await f.exists()) await f.delete();
          } catch (e, st) {
            LoggingService.logger('DownloadJournal')
                .warning('Failed to delete legacy state file on remove', e, st);
          }
          try {
            final tmp = File('$legacyPath.tmp');
            if (await tmp.exists()) await tmp.delete();
          } catch (e, st) {
            LoggingService.logger('DownloadJournal').warning(
                'Failed to delete legacy tmp state file on remove', e, st);
          }
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

  static Future<void> remove(String tempFilePath, {String? taskId}) =>
      instance.remove(tempFilePath, taskId: taskId);

  static int computeFingerprint(TransferState state) =>
      instance.computeFingerprint(state);

  static void removeCachedPayload(String targetPath) =>
      instance.removeCachedPayload(targetPath);

  static void removeTaskState(String targetPath) =>
      instance.removeTaskState(targetPath);
}

class DownloadJournal {
  final String path;
  IOSink? _sink;
  bool _isOpen = false;
  int _approxBytes = 0;
  int _bytesSinceLastFsync = 0;
  // FIX-P5: Flush counter and tracking
  int _flushCounter = 0;
  int _lastFlushRecordCount = 0;
  // Compaction threshold bytes
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

  Future<void> recordChunkProgress(int index, int bytes) async {
    // Task 2.1: Disable chunk journal writes entirely when screen is off
    if (PowerMonitor.screenOff) return;

    final isBg = !DownloadEngine.appInForeground ||
        DownloadEngine.isInBackground;

    final threshold = isBg
        ? kJournalBackgroundWriteDelta // 4MB when backgrounded (BG-04 / C-BG-02)
        : kJournalForegroundWriteDelta; // 512KB foreground (M-DL-08)

    await _lock.synchronized(() async {
      _lastRecordedChunkBytes[index] = bytes;
      while (_lastRecordedChunkBytes.length > maxRecordedEntries) {
        _lastRecordedChunkBytes.remove(_lastRecordedChunkBytes.keys.first);
      }

      final totalWritten =
          _lastRecordedChunkBytes.values.fold<int>(0, (sum, b) => sum + b);
      final totalBytesSinceLastWrite =
          (totalWritten - _lastGlobalWriteBytes).abs();

      if (totalBytesSinceLastWrite < threshold) return;
      _lastGlobalWriteBytes = totalWritten;

      _ensureOpen();
      final line = _withCrc({
        't': 'chunk',
        'i': index,
        'b': bytes,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      _sink!.writeln(line);
      final lineBytes = line.length + 1;
      _approxBytes += lineBytes;
      _bytesSinceLastFsync += lineBytes;
      _flushCounter++;

      // Task 1.3: Add fsync call to the journal on every 1MB written
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

  Future<void> writeCheckpoint(List<int> chunkProgress, int totalSize) async {
    await _lock.synchronized(() async {
      _ensureOpen();
      final line = _withCrc({
        't': 'checkpoint',
        'v': 2,
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

  static Future<List<int>?> recover(String journalPath) async {
    final file = File(journalPath);
    if (!await file.exists()) return null;
    List<int>? lastCheckpoint;
    int? threadCount;
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
        // ERR-RESILIENCE-2.3: Verify the per-line CRC when present. Lines with
        // a missing/legacy checksum are trusted as before (backward compat);
        // lines with a bad checksum are skipped as corrupt.
        final storedCrc = event['c'] as int?;
        if (storedCrc != null) {
          final payload = Map<String, dynamic>.from(event)..remove('c');
          final recomputed = crc32(utf8.encode(jsonEncode(payload)));
          if (recomputed != storedCrc) {
            skippedCorrupt++;
            continue;
          }
        }
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
    return lastCheckpoint;
  }

  /// Best-effort synchronous close of the journal sink. Clears LRU state and
  /// fires `flush()`/`close()` on the sink without awaiting them; safe to call
  /// from a `finally` block or before deleting the journal file.
  void dispose() {
    _lastRecordedChunkBytes.clear();
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

  /// Flushes and closes the underlying journal sink.
  Future<void> close() async {
    await _lock.synchronized(() async {
      _lastRecordedChunkBytes.clear();
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

  Future<void> _closeLocked() async {
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

  Future<void> _compactLocked(List<int> chunkProgress, int totalSize) async {
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
