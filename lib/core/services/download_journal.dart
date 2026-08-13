import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

enum DmxStateStatus { active, paused, complete, failed }

class ChunkState {
  ChunkState({required this.start, required this.end, this.downloaded = 0});

  final int start;
  int end;
  int downloaded;

  int get size => end < 0 ? -1 : end - start + 1;
  bool get isComplete => end >= 0 && downloaded >= size;

  double get ratio {
    final s = size;
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

  int totalSize;
  int threadCount;
  List<ChunkState> chunks;
  String? url;
  String? etag;
  String? lastModified;
  DmxStateStatus status;
  DateTime updatedAt;
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
  List<double> get chunkRatios => chunks.map((c) => c.ratio).toList();
  List<int> get progressCompat => chunks.map((c) => c.downloaded).toList();

  Map<String, dynamic> toJson() => {
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
      if (storedThreadCount != progress.length) {
        debugPrint('[DmxState] V2 migration: threadCount mismatch '
            '(stored=$storedThreadCount, progress.length=${progress.length}). '
            'Using progress.length as authoritative count.');
      }
      final effectiveThreads = progress.length;
      final partSize =
          totalSize > 0 ? (totalSize / effectiveThreads).floor() : 0;
      final chunks = <ChunkState>[];
      for (int i = 0; i < effectiveThreads; i++) {
        final downloaded = (progress[i] as num?)?.toInt() ?? 0;
        final start = i * partSize;
        final end = (i == effectiveThreads - 1 && totalSize > 0)
            ? totalSize - 1
            : (start + partSize - 1);
        final size = end < 0 ? -1 : end - start + 1;
        chunks.add(ChunkState(
          start: start,
          end: end,
          downloaded: size < 0
              ? downloaded.clamp(0, 1 << 62)
              : downloaded.clamp(0, size),
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

class StateLoadResult {
  const StateLoadResult({
    required this.state,
    this.created = false,
    this.migratedFrom,
    this.diskAdjusted = false,
  });

  final TransferState state;
  final bool created;
  final String? migratedFrom;
  final bool diskAdjusted;
}

class StateStore {
  StateStore._();

  static String pathFor(String tempFilePath) => '$tempFilePath.dmxstate';

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
        state = null;
      }
    }

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
      try {
        final raf = await f.open(mode: FileMode.append);
        await raf.truncate(state.totalSize);
        await raf.close();
      } catch (_) {}
      adjusted = true;
    }

    final limit = state.totalSize > 0 ? len.clamp(0, state.totalSize) : len;
    for (final c in state.chunks) {
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

  static Future<void> save(
    String tempFilePath,
    TransferState state, {
    bool durable = false,
  }) async {
    state.updatedAt = DateTime.now();
    final targetPath = pathFor(tempFilePath);
    final tmpPath = '$targetPath.tmp';
    try {
      final payload = jsonEncode(state.toJson());
      final tmp = File(tmpPath);
      await tmp.parent.create(recursive: true);
      // Periodic progress saves are best-effort: write + atomic rename
      // without an fsync barrier. Full durability (fsync) is reserved for
      // pause/stop/completion so active downloads don't hammer flash storage.
      if (durable) {
        await tmp.writeAsString(payload, flush: true);
        try {
          final raf = await tmp.open(mode: FileMode.append);
          await raf.flush();
          await raf.close();
        } catch (_) {}
      } else {
        await tmp.writeAsString(payload, flush: false);
      }
      await tmp.rename(targetPath);
    } catch (e) {
      debugPrint('[DmxState] save failed for $tempFilePath: $e');
      try {
        final tmp = File(tmpPath);
        if (await tmp.exists()) {
          await tmp.delete();
        }
      } catch (_) {}
    }
  }

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

class DownloadJournal {
  final String path;
  IOSink? _sink;
  bool _isOpen = false;
  int _approxBytes = 0;
  // FIX: Reduced from 2MB to 512KB for mobile-friendly compaction
  final int compactionThresholdBytes;
  final Lock _lock = Lock();

  DownloadJournal(this.path, {this.compactionThresholdBytes = 512 * 1024});

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
        } catch (_) {}
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
    } catch (_) {}
    _sink = null;
  }

  Future<void> _compactLocked(List<int> chunkProgress, int totalSize) async {
    _isOpen = false;
    try {
      await _sink?.flush();
      await _sink?.close();
      _sink = null;

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
