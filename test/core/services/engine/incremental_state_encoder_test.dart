import 'package:dmx/core/services/transfer_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IncrementalStateEncoder Tests', () {
    test('encodeDiff and applyDiff accurately apply deltas across states', () {
      final baseState = TransferState(
        totalSize: 1000000,
        threadCount: 4,
        status: DmxStateStatus.active,
        cycleState: 'downloading',
        url: 'https://example.com/file.zip',
        etag: 'etag123',
        chunks: [
          ChunkState(start: 0, end: 249999, downloaded: 100000),
          ChunkState(start: 250000, end: 499999, downloaded: 50000),
          ChunkState(start: 500000, end: 749999, downloaded: 0),
          ChunkState(start: 750000, end: 999999, downloaded: 0),
        ],
      );

      final updatedState = TransferState(
        totalSize: 1000000,
        threadCount: 4,
        status: DmxStateStatus.active,
        cycleState: 'downloading',
        url: 'https://example.com/file.zip',
        etag: 'etag123',
        chunks: [
          ChunkState(start: 0, end: 249999, downloaded: 250000),
          ChunkState(start: 250000, end: 499999, downloaded: 200000),
          ChunkState(start: 500000, end: 749999, downloaded: 150000),
          ChunkState(start: 750000, end: 999999, downloaded: 50000),
        ],
      );

      final diff = IncrementalStateEncoder.encodeDiff(baseState, updatedState);
      expect(diff, isNotEmpty);
      // Binary diff format should be very compact (< 100 bytes)
      expect(diff.length, lessThan(100));

      final restoredState = IncrementalStateEncoder.applyDiff(baseState, diff);
      expect(restoredState.chunks[0].downloaded, 250000);
      expect(restoredState.chunks[1].downloaded, 200000);
      expect(restoredState.chunks[2].downloaded, 150000);
      expect(restoredState.chunks[3].downloaded, 50000);
      expect(restoredState.totalSize, 1000000);
    });
  });
}
