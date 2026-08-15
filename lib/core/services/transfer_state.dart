/// Pure data models for download transfer state. No persistence or engine
/// dependencies — kept separate so parsing and validation can be tested in
/// isolation and reused across persistence formats.
library;

import 'package:flutter/foundation.dart';

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
