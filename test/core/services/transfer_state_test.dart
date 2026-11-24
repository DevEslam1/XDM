import 'dart:typed_data';

import 'package:dmx/core/domain/pause_reason.dart';
import 'package:dmx/core/services/transfer_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChunkState', () {
    test('indeterminate chunk reports -1 size/ratio', () {
      final c = ChunkState.indeterminate(downloaded: 10);
      expect(c.isIndeterminate, isTrue);
      expect(c.size, -1);
      expect(c.ratio, -1.0);
      expect(c.isComplete, isFalse);
    });

    test('zero-size chunk ratio reflects downloaded', () {
      final c = ChunkState(start: 5, end: 4); // size 0
      expect(c.size, 0);
      expect(c.ratio, 0.0);
      c.downloaded = 1;
      expect(c.ratio, 1.0);
    });

    test('ratio is clamped between 0 and 1', () {
      final c = ChunkState(start: 0, end: 9, downloaded: 20);
      expect(c.ratio, 1.0);
      expect(c.isComplete, isTrue);
    });

    test('ratio scales with partial download', () {
      final c = ChunkState(start: 0, end: 9, downloaded: 5);
      expect(c.ratio, 0.5);
    });

    test('toJson/fromJson round-trips and clamps negatives', () {
      final c = ChunkState(start: 1, end: 8, downloaded: 3, hash: 'abc');
      final json = c.toJson();
      expect(json['hash'], 'abc');
      final restored = ChunkState.fromJson({'downloaded': -5});
      expect(restored.downloaded, 0);
      expect(restored.end, -1);
    });

    test('fromJson omits hash when absent', () {
      final json = ChunkState(start: 0, end: 1).toJson();
      expect(json.containsKey('hash'), isFalse);
    });
  });

  group('TransferState', () {
    TransferState sample() => TransferState(
          totalSize: 100,
          threadCount: 2,
          chunks: [
            ChunkState(start: 0, end: 49, downloaded: 50),
            ChunkState(start: 50, end: 99, downloaded: 25),
          ],
          url: 'https://e.com/a',
          etag: 'etag1',
          lastModified: 'lm',
        );

    test('downloadedBytes sums chunks and clamps to totalSize', () {
      final state = sample();
      expect(state.downloadedBytes, 75);
      state.chunks[0].downloaded = 200;
      expect(state.downloadedBytes, 100);
    });

    test('isComplete requires totalSize and full progress', () {
      final state = sample();
      expect(state.isComplete, isFalse);
      state.chunks[0].downloaded = 50;
      state.chunks[1].downloaded = 50;
      expect(state.isComplete, isTrue);
    });

    test('chunkRatios and progressCompat mirror chunks', () {
      final state = sample();
      expect(state.chunkRatios.length, 2);
      expect(state.progressCompat, [50, 25]);
    });

    test('toHttpPartStatusList carries indices and byte ranges', () {
      final list = sample().toHttpPartStatusList();
      expect(list.length, 2);
      expect(list.first.partIndex, 0);
      expect(list.first.startByte, 0);
      expect(list.first.endByte, 49);
    });

    test('resumeIdentity is null when no metadata is present', () {
      final state = TransferState(totalSize: 0, threadCount: 1, chunks: []);
      expect(state.resumeIdentity, isNull);
    });

    test('resumeIdentity is built from url/size', () {
      final id = sample().resumeIdentity;
      expect(id, isNotNull);
      expect(id!.contentLength, 100);
      expect(id.supportsRanges, isTrue);
    });

    test('toJson includes optional fields and clone copies them', () {
      final state = sample()
        ..cycleState = 'downloading'
        ..pauseReason = PauseReason.user
        ..migrationNote = 'note';
      final json = state.toJson();
      expect(json['cycleState'], 'downloading');
      expect(json['pauseReason'], 'user');
      expect(json['migrationNote'], 'note');

      final clone = state.clone();
      expect(clone.migrationNote, 'note');
      expect(clone.chunks.length, 2);
      expect(identical(clone.chunks, state.chunks), isFalse);
    });

    test('tryParseV3 rejects mismatched version', () {
      expect(TransferState.tryParseV3({'v': 99, 'chunks': []}), isNull);
    });

    test('tryParseV3 rejects non-list chunks', () {
      expect(
        TransferState.tryParseV3(
            {'v': TransferState.currentVersion, 'chunks': 1}),
        isNull,
      );
    });

    test('tryParseV3 rejects a list of non-maps', () {
      expect(
        TransferState.tryParseV3({
          'v': TransferState.currentVersion,
          'chunks': [1, 2],
        }),
        isNull,
      );
    });

    test('tryParseV3 parses a valid snapshot', () {
      final state = TransferState.tryParseV3({
        'v': TransferState.currentVersion,
        'totalSize': 100,
        'threadCount': 2,
        'chunks': [
          {'start': 0, 'end': 49, 'downloaded': 50},
        ],
        'status': 'paused',
        'updatedAt': 123456,
        'pauseReason': 'user',
      });
      expect(state, isNotNull);
      expect(state!.status, DmxStateStatus.paused);
      expect(state.pauseReason, PauseReason.user);
    });

    test('tryParseV3 defaults status and handles missing chunks', () {
      final state = TransferState.tryParseV3({
        'version': TransferState.currentVersion,
        'chunks': [],
      });
      expect(state, isNotNull);
      expect(state!.status, DmxStateStatus.active);
      expect(state.threadCount, 1);
    });

    test('tryParseV2 migrates progress into chunks', () {
      final state = TransferState.tryParseV2({
        'totalSize': 100,
        'threadCount': 2,
        'progress': [50, 50],
        'url': 'https://e.com/a',
      });
      expect(state, isNotNull);
      expect(state!.threadCount, 2);
      expect(state.downloadedBytes, 100);
      expect(state.migrationNote, 'v2');
    });

    test('tryParseV2 returns null for empty progress', () {
      expect(TransferState.tryParseV2({'progress': []}), isNull);
      expect(TransferState.tryParseV2({}), isNull);
    });

    test('tryParseV2 handles threadCount mismatch', () {
      final state = TransferState.tryParseV2({
        'totalSize': 100,
        'threadCount': 5,
        'progress': [25, 25],
      });
      expect(state!.threadCount, 2);
    });

    test('tryParseV3 returns null when a chunk is malformed', () {
      final state = TransferState.tryParseV3({
        'v': TransferState.currentVersion,
        'chunks': [
          {'start': 'oops'},
        ],
      });
      expect(state, isNull);
    });

    test('tryParseV2 returns null when progress entries are malformed', () {
      expect(
        TransferState.tryParseV2({
          'totalSize': 100,
          'progress': ['not-a-number'],
        }),
        isNull,
      );
    });

    test('resumeIdentity is built from etag alone', () {
      final state = TransferState(
        totalSize: 0,
        threadCount: 1,
        chunks: [],
        etag: 'etag-only',
      );
      expect(state.resumeIdentity, isNotNull);
      expect(state.resumeIdentity!.etag, 'etag-only');
      expect(state.resumeIdentity!.contentLength, isNull);
    });

    test('toJson stamps the current version', () {
      final json = sample().toJson();
      expect(json['version'], TransferState.currentVersion);
      expect(json['v'], TransferState.currentVersion);
    });

    test('tryParseV3 falls back to active for an unknown status', () {
      final state = TransferState.tryParseV3({
        'v': TransferState.currentVersion,
        'chunks': [
          {'start': 0, 'end': 1},
        ],
        'status': 'bogus',
      });
      expect(state, isNotNull);
      expect(state!.status, DmxStateStatus.active);
    });

    test('tryParseV2 clamps downloaded for an indeterminate chunk', () {
      final state = TransferState.tryParseV2({
        'totalSize': 0,
        'threadCount': 1,
        'progress': [5],
      });
      expect(state, isNotNull);
      expect(state!.chunks.single.isIndeterminate, isTrue);
      expect(state.chunks.single.downloaded, 5);
    });
  });

  group('IncrementalStateEncoder', () {
    TransferState base() => TransferState(
          totalSize: 100,
          threadCount: 1,
          chunks: [ChunkState(start: 0, end: 99, downloaded: 10)],
          url: 'https://e.com/a',
          etag: 'e',
          cycleState: 'downloading',
        );

    test('encodeDiff/applyDiff round-trips all changed fields', () {
      final old = base();
      final updated = base()
        ..totalSize = 200
        ..threadCount = 2
        ..status = DmxStateStatus.paused
        ..cycleState = 'paused'
        ..url = 'https://e.com/b'
        ..etag = 'e2'
        ..chunks = [
          ChunkState(start: 0, end: 99, downloaded: 20),
          ChunkState(start: 100, end: 199, downloaded: 0),
        ];
      final diff = IncrementalStateEncoder.encodeDiff(old, updated);
      final applied = IncrementalStateEncoder.applyDiff(old, diff);
      expect(applied.totalSize, 200);
      expect(applied.threadCount, 2);
      expect(applied.status, DmxStateStatus.paused);
      expect(applied.cycleState, 'paused');
      expect(applied.url, 'https://e.com/b');
      expect(applied.etag, 'e2');
      expect(applied.chunks.length, 2);
      expect(applied.chunks[0].downloaded, 20);
    });

    test('applyDiff returns base for short or wrong-version buffers', () {
      final old = base();
      expect(
        IncrementalStateEncoder.applyDiff(old, Uint8List.fromList([1])),
        same(old),
      );
      expect(
        IncrementalStateEncoder.applyDiff(
          old,
          Uint8List.fromList([0x99, 0x00]),
        ),
        same(old),
      );
    });

    test('encodeDiff with no changes writes only version+mask', () {
      final old = base();
      final diff = IncrementalStateEncoder.encodeDiff(old, old.clone());
      expect(diff.length, 2);
    });

    test('applyDiff clears string fields when empty', () {
      final old = base();
      final updated = base()
        ..cycleState = null
        ..url = null
        ..etag = null;
      final diff = IncrementalStateEncoder.encodeDiff(old, updated);
      final applied = IncrementalStateEncoder.applyDiff(old, diff);
      expect(applied.cycleState, isNull);
      expect(applied.url, isNull);
      expect(applied.etag, isNull);
    });

    test('applyDiff returns the base when a field marker is truncated', () {
      final old = base();
      // Version byte + status mask bit with no status byte following.
      final diff = Uint8List.fromList([0x02, 0x04]);
      expect(
        identical(IncrementalStateEncoder.applyDiff(old, diff), old),
        isTrue,
      );
    });

    test('encodeDiff detects chunk end changes without downloaded changes', () {
      final old = base();
      final updated = base()
        ..chunks = [ChunkState(start: 0, end: 199, downloaded: 10)];
      final diff = IncrementalStateEncoder.encodeDiff(old, updated);
      final applied = IncrementalStateEncoder.applyDiff(old, diff);
      expect(applied.chunks.single.end, 199);
    });
  });

  group('StateLoadResult', () {
    test('holds creation and migration flags', () {
      final result = StateLoadResult(
        state: TransferState(totalSize: 1, threadCount: 1, chunks: []),
        created: true,
        migratedFrom: 'v2',
        diskAdjusted: true,
      );
      expect(result.created, isTrue);
      expect(result.migratedFrom, 'v2');
      expect(result.diskAdjusted, isTrue);
    });
  });
}
