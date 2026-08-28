/// Pure data models for download transfer state. No persistence or engine
/// dependencies — kept separate so parsing and validation can be tested in
/// isolation and reused across persistence formats.
library;

import 'dart:typed_data';

import 'package:dmx/core/services/logging_service.dart';
import 'package:flutter/foundation.dart';
import '../domain/download_data_status.dart';
import '../domain/engine_types.dart';
import '../domain/resume_identity.dart';

enum DmxStateStatus { active, paused, complete, failed }

class ChunkState {
  ChunkState({
    required this.start,
    required this.end,
    this.downloaded = 0,
    this.hash,
  });

  factory ChunkState.indeterminate({int downloaded = 0, String? hash}) =>
      ChunkState(start: 0, end: -1, downloaded: downloaded, hash: hash);

  final int start;
  int end;
  int downloaded;
  String? hash;

  int get size => end < 0 ? -1 : end - start + 1;
  bool get isIndeterminate => end < 0;
  bool get isComplete => end >= 0 && downloaded >= size;

  double get ratio {
    final s = size;
    if (s < 0) return -1.0;
    if (s == 0) return downloaded > 0 ? 1.0 : 0.0;
    return (downloaded / s).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'downloaded': downloaded,
        if (hash != null) 'hash': hash,
      };

  static ChunkState fromJson(Map<String, dynamic> j) {
    var d = (j['downloaded'] as num?)?.toInt() ?? 0;
    if (d < 0) d = 0;
    return ChunkState(
      start: (j['start'] as num?)?.toInt() ?? 0,
      end: (j['end'] as num?)?.toInt() ?? -1,
      downloaded: d,
      hash: j['hash'] as String?,
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
    this.cycleState,
    this.pauseReason,
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
  String? cycleState;
  PauseReason? pauseReason;
  DateTime updatedAt;
  String? migrationNote;

  ResumeIdentity? get resumeIdentity {
    if (url == null && etag == null && lastModified == null && totalSize <= 0) {
      return null;
    }
    return ResumeIdentity(
      normalizedUrl: ResumeIdentity.normalizeUrl(url ?? ''),
      etag: etag,
      lastModified: lastModified,
      contentLength: totalSize > 0 ? totalSize : null,
      supportsRanges: true,
    );
  }

  int get downloadedBytes {
    var sum = 0;
    for (final c in chunks) {
      sum += c.downloaded;
    }
    if (totalSize > 0 && sum > totalSize) sum = totalSize;
    return sum;
  }

  bool get isComplete => totalSize > 0 && downloadedBytes >= totalSize;
  List<double> get chunkRatios =>
      List<ChunkState>.from(chunks).map((c) => c.ratio).toList();
  List<int> get progressCompat =>
      List<ChunkState>.from(chunks).map((c) => c.downloaded).toList();

  List<HttpPartStatus> toHttpPartStatusList() {
    return chunks
        .asMap()
        .entries
        .map((e) => HttpPartStatus(
              partIndex: e.key,
              startByte: e.value.start,
              endByte: e.value.end,
              downloadedBytes: e.value.downloaded,
            ))
        .toList();
  }

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
        'chunks': List<ChunkState>.from(chunks).map((c) => c.toJson()).toList(),
        if (cycleState != null) 'cycleState': cycleState,
        if (pauseReason != null) 'pauseReason': pauseReason!.name,
        if (migrationNote != null) 'migrationNote': migrationNote,
      };

  TransferState clone() => TransferState(
        totalSize: totalSize,
        threadCount: threadCount,
        chunks: chunks
            .map((c) => ChunkState(
                start: c.start,
                end: c.end,
                downloaded: c.downloaded,
                hash: c.hash))
            .toList(),
        url: url,
        etag: etag,
        lastModified: lastModified,
        status: status,
        cycleState: cycleState,
        pauseReason: pauseReason,
        updatedAt: updatedAt,
        migrationNote: migrationNote,
      );

  static TransferState? tryParseV3(Map<String, dynamic> json) {
    try {
      final v =
          (json['v'] as num?)?.toInt() ?? (json['version'] as num?)?.toInt();
      if (v != null && v != currentVersion) return null;
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
        cycleState: json['cycleState'] as String?,
        pauseReason: PauseReason.fromName(json['pauseReason'] as String?),
        updatedAt: json['updatedAt'] is int
            ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int)
            : DateTime.now(),
        migrationNote: json['migrationNote'] as String?,
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
        cycleState: json['cycleState'] as String?,
        migrationNote: 'v2',
      );
    } catch (e, st) {
      LoggingService.logger('TransferState')
          .warning('Operation failed with fallback', e, st);
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

/// Binary diff encoder for incremental state persistence (Phase 1.4).
class IncrementalStateEncoder {
  IncrementalStateEncoder._();

  static const int diffVersion = 0x02;

  /// Encodes the delta between [oldState] and [updatedState].
  static Uint8List encodeDiff(
      TransferState oldState, TransferState updatedState) {
    final bytes = BytesBuilder();
    bytes.addByte(diffVersion);

    int mask = 0;
    if (updatedState.totalSize != oldState.totalSize) mask |= (1 << 0);
    if (updatedState.threadCount != oldState.threadCount) mask |= (1 << 1);
    if (updatedState.status != oldState.status) mask |= (1 << 2);
    if (updatedState.cycleState != oldState.cycleState) mask |= (1 << 3);
    if (updatedState.url != oldState.url) mask |= (1 << 4);
    if (updatedState.etag != oldState.etag) mask |= (1 << 5);

    // Check if chunk progress changed
    bool chunksChanged = updatedState.chunks.length != oldState.chunks.length;
    if (!chunksChanged) {
      for (int i = 0; i < updatedState.chunks.length; i++) {
        if (updatedState.chunks[i].downloaded !=
                oldState.chunks[i].downloaded ||
            updatedState.chunks[i].end != oldState.chunks[i].end) {
          chunksChanged = true;
          break;
        }
      }
    }
    if (chunksChanged) mask |= (1 << 6);

    bytes.addByte(mask);

    if ((mask & (1 << 0)) != 0) _writeVarint(bytes, updatedState.totalSize);
    if ((mask & (1 << 1)) != 0) _writeVarint(bytes, updatedState.threadCount);
    if ((mask & (1 << 2)) != 0) bytes.addByte(updatedState.status.index);
    if ((mask & (1 << 3)) != 0) {
      _writeString(bytes, updatedState.cycleState ?? '');
    }
    if ((mask & (1 << 4)) != 0) _writeString(bytes, updatedState.url ?? '');
    if ((mask & (1 << 5)) != 0) _writeString(bytes, updatedState.etag ?? '');

    if ((mask & (1 << 6)) != 0) {
      _writeVarint(bytes, updatedState.chunks.length);
      for (final chunk in updatedState.chunks) {
        _writeVarint(bytes, chunk.start);
        _writeVarint(bytes, chunk.end);
        _writeVarint(bytes, chunk.downloaded);
      }
    }

    return bytes.takeBytes();
  }

  /// Applies a binary [diff] onto [base] to produce an updated [TransferState].
  static TransferState applyDiff(TransferState base, Uint8List diff) {
    if (diff.isEmpty || diff[0] != diffVersion) return base;

    int offset = 1;
    final mask = diff[offset++];

    int totalSize = base.totalSize;
    int threadCount = base.threadCount;
    DmxStateStatus status = base.status;
    String? cycleState = base.cycleState;
    String? url = base.url;
    String? etag = base.etag;
    List<ChunkState> chunks = List.from(base.chunks);

    if ((mask & (1 << 0)) != 0) {
      final res = _readVarint(diff, offset);
      totalSize = res.value;
      offset = res.nextOffset;
    }
    if ((mask & (1 << 1)) != 0) {
      final res = _readVarint(diff, offset);
      threadCount = res.value;
      offset = res.nextOffset;
    }
    if ((mask & (1 << 2)) != 0) {
      final statusIdx = diff[offset++];
      if (statusIdx >= 0 && statusIdx < DmxStateStatus.values.length) {
        status = DmxStateStatus.values[statusIdx];
      }
    }
    if ((mask & (1 << 3)) != 0) {
      final res = _readString(diff, offset);
      cycleState = res.value.isEmpty ? null : res.value;
      offset = res.nextOffset;
    }
    if ((mask & (1 << 4)) != 0) {
      final res = _readString(diff, offset);
      url = res.value.isEmpty ? null : res.value;
      offset = res.nextOffset;
    }
    if ((mask & (1 << 5)) != 0) {
      final res = _readString(diff, offset);
      etag = res.value.isEmpty ? null : res.value;
      offset = res.nextOffset;
    }
    if ((mask & (1 << 6)) != 0) {
      final countRes = _readVarint(diff, offset);
      final count = countRes.value;
      offset = countRes.nextOffset;
      chunks = [];
      for (int i = 0; i < count; i++) {
        final startRes = _readVarint(diff, offset);
        offset = startRes.nextOffset;
        final endRes = _readVarint(diff, offset);
        offset = endRes.nextOffset;
        final dlRes = _readVarint(diff, offset);
        offset = dlRes.nextOffset;
        chunks.add(ChunkState(
          start: startRes.value,
          end: endRes.value,
          downloaded: dlRes.value,
        ));
      }
    }

    return TransferState(
      totalSize: totalSize,
      threadCount: threadCount,
      chunks: chunks,
      status: status,
      cycleState: cycleState,
      url: url,
      etag: etag,
      lastModified: base.lastModified,
      pauseReason: base.pauseReason,
      updatedAt: DateTime.now(),
    );
  }

  static void _writeVarint(BytesBuilder bytes, int value) {
    var v = value;
    while (v >= 0x80 || v < 0) {
      bytes.addByte((v & 0x7F) | 0x80);
      v >>>= 7;
      if (v == 0) break;
    }
    bytes.addByte(v & 0x7F);
  }

  static ({int value, int nextOffset}) _readVarint(
      Uint8List bytes, int offset) {
    int res = 0;
    int shift = 0;
    int off = offset;
    while (off < bytes.length) {
      final b = bytes[off++];
      res |= (b & 0x7F) << shift;
      shift += 7;
      if ((b & 0x80) == 0) break;
    }
    return (value: res, nextOffset: off);
  }

  static void _writeString(BytesBuilder bytes, String str) {
    final utf = Uint8List.fromList(str.codeUnits);
    _writeVarint(bytes, utf.length);
    bytes.add(utf);
  }

  static ({String value, int nextOffset}) _readString(
      Uint8List bytes, int offset) {
    final lenRes = _readVarint(bytes, offset);
    final len = lenRes.value;
    final start = lenRes.nextOffset;
    final end = start + len;
    if (end > bytes.length) return (value: '', nextOffset: bytes.length);
    final str = String.fromCharCodes(bytes.sublist(start, end));
    return (value: str, nextOffset: end);
  }
}
