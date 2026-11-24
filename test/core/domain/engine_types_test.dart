import 'package:dmx/core/domain/engine_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadMetadata', () {
    test('isValid and copyWith', () {
      const empty = DownloadMetadata(
        fileName: '',
        category: 'Auto',
        fileSize: 0,
        supportsResume: false,
      );
      expect(empty.isValid, isFalse);

      const named = DownloadMetadata(
        fileName: 'a.zip',
        category: 'Archive',
        fileSize: 10,
        supportsResume: true,
        etag: 'e',
        lastModified: 'l',
        torrentId: 1,
      );
      expect(named.isValid, isTrue);

      final updated = named.copyWith(
        fileName: 'b.zip',
        category: 'Video',
        fileSize: 20,
        supportsResume: false,
        torrentFiles: const [],
        torrentId: 2,
        etag: 'e2',
        lastModified: 'l2',
      );
      expect(updated.fileName, 'b.zip');
      expect(updated.fileSize, 20);
      expect(updated.torrentId, 2);

      final unchanged = named.copyWith();
      expect(unchanged.fileName, 'a.zip');
    });
  });

  group('ChunkDetail', () {
    test('derived getters', () {
      const indeterminate = ChunkDetail(
        index: 0,
        start: 0,
        end: 0,
        downloaded: 0,
        size: -1,
        ratio: 0,
      );
      expect(indeterminate.isIndeterminate, isTrue);
      expect(indeterminate.isComplete, isFalse);
      expect(indeterminate.percentLabel, '—');

      const empty = ChunkDetail(
        index: 0,
        start: 0,
        end: 0,
        downloaded: 0,
        size: 0,
        ratio: 0,
      );
      expect(empty.percentLabel, '100%');

      const half = ChunkDetail(
        index: 0,
        start: 0,
        end: 99,
        downloaded: 50,
        size: 100,
        ratio: 0.5,
      );
      expect(half.isComplete, isFalse);
      expect(half.percentLabel, '50%');

      const done = ChunkDetail(
        index: 0,
        start: 0,
        end: 99,
        downloaded: 100,
        size: 100,
        ratio: 1,
      );
      expect(done.isComplete, isTrue);
    });

    test('fromMap defaults and sanitization', () {
      final d = ChunkDetail.fromMap(const {});
      expect(d.index, 0);
      expect(d.end, -1);
      expect(d.size, -1);
      expect(d.ratio, 0.0);

      final nan = ChunkDetail.fromMap(const {
        'ratio': double.nan,
        'index': 1,
        'start': 2,
        'end': 3,
        'downloaded': 4,
        'size': 5,
      });
      expect(nan.ratio, 0.0);

      final inf = ChunkDetail.fromMap(const {'ratio': double.infinity});
      expect(inf.ratio, 0.0);

      final neg = ChunkDetail.fromMap(const {'ratio': -1.0});
      expect(neg.ratio, 0.0);

      final big = ChunkDetail.fromMap(const {'ratio': 5.0});
      expect(big.ratio, 1.0);

      final normal = ChunkDetail.fromMap(const {'ratio': 0.3});
      expect(normal.ratio, 0.3);
    });

    test('copyWith, equality, hashCode', () {
      const a = ChunkDetail(
        index: 0,
        start: 0,
        end: 1,
        downloaded: 1,
        size: 2,
        ratio: 0.5,
      );
      final b = a.copyWith(index: 9);
      expect(b.index, 9);
      expect(b.start, 0);
      expect(a.copyWith(), equals(a));
      expect(a == Object(), isFalse);
      expect(a == b, isFalse);
      expect(a.hashCode, isNot(equals(b.hashCode)));
    });
  });

  group('DownloadProgress', () {
    test('progress getters', () {
      const p = DownloadProgress(
        downloadedBytes: 50,
        fileSize: 100,
        speed: 1,
        eta: null,
      );
      expect(p.progress, closeTo(0.5, 0.001));
      expect(p.progressRatio, closeTo(0.5, 0.001));

      const zero = DownloadProgress(
        downloadedBytes: 0,
        fileSize: 0,
        speed: 0,
        eta: null,
      );
      expect(zero.progress, 0.0);

      const over = DownloadProgress(
        downloadedBytes: 200,
        fileSize: 100,
        speed: 0,
        eta: null,
      );
      expect(over.progress, 1.0);
    });

    test('ytCombinedProgress branches', () {
      const noYt = DownloadProgress(
        downloadedBytes: 0,
        fileSize: 100,
        speed: 0,
        eta: null,
      );
      expect(noYt.ytCombinedProgress, isNull);

      const combined = DownloadProgress(
        downloadedBytes: 50,
        fileSize: 100,
        speed: 0,
        eta: null,
        ytStreamKind: YtStreamKind.combined,
      );
      expect(combined.ytCombinedProgress, closeTo(0.5, 0.001));

      const noCounterpartIncomplete = DownloadProgress(
        downloadedBytes: 50,
        fileSize: 100,
        speed: 0,
        eta: null,
        ytStreamKind: YtStreamKind.video,
      );
      expect(noCounterpartIncomplete.ytCombinedProgress, closeTo(0.5, 0.001));

      const noCounterpartComplete = DownloadProgress(
        downloadedBytes: 100,
        fileSize: 100,
        speed: 0,
        eta: null,
        ytStreamKind: YtStreamKind.video,
      );
      expect(noCounterpartComplete.ytCombinedProgress, isNull);

      const noSizeNoCounterpart = DownloadProgress(
        downloadedBytes: 0,
        fileSize: 0,
        speed: 0,
        eta: null,
        ytStreamKind: YtStreamKind.audio,
      );
      expect(noSizeNoCounterpart.ytCombinedProgress, isNull);

      const withCounterpart = DownloadProgress(
        downloadedBytes: 50,
        fileSize: 100,
        speed: 0,
        eta: null,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 100,
        ytCounterpartDownloadedBytes: 50,
        ytDownloadedBytes: 50,
      );
      expect(withCounterpart.ytCombinedProgress, closeTo(0.5, 0.001));

      const negative = DownloadProgress(
        downloadedBytes: -10,
        fileSize: 100,
        speed: 0,
        eta: null,
        ytStreamKind: YtStreamKind.video,
        ytCounterpartSize: 100,
        ytCounterpartDownloadedBytes: -5,
        ytDownloadedBytes: -10,
      );
      expect(negative.ytCombinedProgress, 0.0);
    });

    test('fromWorkerMap parses details, enums, and fallbacks', () {
      final selectedCycle = DownloadProgress.fromWorkerMap(const {
        'downloadedBytes': 10,
        'fileSize': 100,
        'speed': 2.5,
        'eta': 5,
        'chunks': [0.1, 0.2],
        'fileName': 'f',
        'supportsResume': true,
        'statusMessage': 's',
        'torrentId': 7,
        'chunkDetails': [
          {'index': 0, 'ratio': 0.5},
          'notAMap',
        ],
        'cycleState': CycleState.downloading,
        'pauseReason': PauseReason.user,
        'totalChunks': 1,
        'completedChunks': 0,
        'totalPieces': 2,
        'completedPieces': 1,
        'totalFiles': 3,
        'completedFiles': 1,
        'totalFileBytes': 100,
        'downloadedFileBytes': 10,
        'ytStreamKind': YtStreamKind.combined,
        'ytCounterpartSize': 10,
        'ytCounterpartDownloadedBytes': 5,
        'ytDownloadedBytes': 5,
        'hasEstimatedFileProgress': true,
        'chunkFingerprint': 42,
      });
      expect(selectedCycle.downloadedBytes, 10);
      expect(selectedCycle.speed, 2.5);
      expect(selectedCycle.chunks, [0.1, 0.2]);
      expect(selectedCycle.chunkDetails, hasLength(1));
      expect(selectedCycle.cycleState, CycleState.downloading);
      expect(selectedCycle.pauseReason, PauseReason.user);
      expect(selectedCycle.ytStreamKind, YtStreamKind.combined);
      expect(selectedCycle.chunkFingerprint, 42);

      final fromNames = DownloadProgress.fromWorkerMap(const {
        'cycleState': 'fetching_metadata',
        'pauseReason': 'networkLost',
        'ytStreamKind': 'notAnEnum',
      });
      expect(fromNames.cycleState, CycleState.fetchingMetadata);
      expect(fromNames.pauseReason, PauseReason.networkLost);
      expect(fromNames.ytStreamKind, isNull);
      expect(fromNames.chunkDetails, isNull);
      expect(fromNames.downloadedBytes, 0);
      expect(fromNames.eta, isNull);
    });

    test('copyWith, equality and hashCode', () {
      const p = DownloadProgress(
        downloadedBytes: 10,
        fileSize: 100,
        speed: 1.2,
        eta: null,
        torrentFiles: [
          {'a': 1}
        ],
        chunkDetails: [
          ChunkDetail(
            index: 0,
            start: 0,
            end: 1,
            downloaded: 1,
            size: 1,
            ratio: 1,
          )
        ],
      );
      final q = p.copyWith(downloadedBytes: 20, cycleState: CycleState.paused);
      expect(q.downloadedBytes, 20);
      expect(q.cycleState, CycleState.paused);
      expect(p.copyWith(), equals(p));
      expect(p == Object(), isFalse);
      expect(q == p, isFalse);

      const same = DownloadProgress(
        downloadedBytes: 10,
        fileSize: 100,
        speed: 1.2,
        eta: null,
        torrentFiles: [
          {'a': 1}
        ],
        chunkDetails: [
          ChunkDetail(
            index: 0,
            start: 0,
            end: 1,
            downloaded: 1,
            size: 1,
            ratio: 1,
          )
        ],
      );
      expect(p, equals(same));
      expect(p.hashCode, equals(same.hashCode));
    });
  });

  group('DownloadError', () {
    test('toJson / fromJson roundtrip and fallbacks', () {
      final ts = DateTime.utc(2025, 1, 2, 3, 4, 5);
      final error = DownloadError(
        code: 'E1',
        message: 'msg',
        detail: 'detail',
        category: 'network',
        timestamp: ts,
        taskId: 't1',
      );
      final json = error.toJson();
      expect(json['code'], 'E1');
      expect(json['timestamp'], ts.toIso8601String());

      final restored = DownloadError.fromJson(json);
      expect(restored.code, 'E1');
      expect(restored.detail, 'detail');
      expect(restored.taskId, 't1');

      final empty = DownloadError.fromJson(const {});
      expect(empty.code, 'UNKNOWN');
      expect(empty.message, '');
      expect(empty.category, 'unknown');
      expect(empty.detail, isNull);
      expect(empty.taskId, isNull);

      final badTs = DownloadError.fromJson(const {'timestamp': 'not-a-date'});
      expect(badTs.timestamp, isA<DateTime>());

      expect(error.toString(), contains('DownloadError'));
      expect(error.toString(), contains('E1'));
    });
  });
}
