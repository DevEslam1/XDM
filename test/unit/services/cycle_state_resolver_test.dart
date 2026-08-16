import 'package:dmx/core/services/engine/cycle_state_resolver.dart';
import 'package:dmx/features/downloads/models/cycle_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CycleStateResolver Tests (FIX-05 & PERF-01)', () {
    test('resolves cancelled state to paused regardless of message', () {
      expect(
        CycleStateResolver.resolve(
          statusMessage: 'Downloading 50%',
          isCancelled: true,
        ),
        CycleState.paused,
      );
      expect(
        CycleStateResolver.resolve(
          statusMessage: 'Completed',
          isCancelled: true,
        ),
        CycleState.paused,
      );
    });

    test('exhaustive libtorrent state labels mapping', () {
      final libtorrentLabels = {
        'checking_files': CycleState.verifying,
        'checking_resume_data': CycleState.verifying,
        'queued_for_checking': CycleState.verifying,
        'checking': CycleState.verifying,
        'verifying': CycleState.verifying,
        'downloading_metadata': CycleState.fetchingMetadata,
        'fetching_metadata': CycleState.fetchingMetadata,
        'metadata': CycleState.fetchingMetadata,
        'allocating': CycleState.allocating,
        'downloading': CycleState.downloading,
        'seeding': CycleState.seeding,
        'finished': CycleState.completed,
        'completed': CycleState.completed,
        'paused': CycleState.paused,
        'stopped': CycleState.paused,
        'stalled': CycleState.stalled,
        'error': CycleState.failed,
        'failed': CycleState.failed,
        'resuming': CycleState.resuming,
        'retrying': CycleState.retrying,
        'updating_links': CycleState.updatingLinks,
        'merging': CycleState.merging,
        'muxing': CycleState.merging,
        'starting': CycleState.starting,
        'queued': CycleState.starting,
      };

      for (final entry in libtorrentLabels.entries) {
        expect(
          CycleStateResolver.resolve(
            statusMessage: entry.key,
            isTorrent: true,
          ),
          equals(entry.value),
          reason: 'Failed for libtorrent label: ${entry.key}',
        );
      }
    });

    test('word boundary matching prevents false positives for HTTP messages', () {
      // "unfailing" or "counterpart" should not match \bfail\b or \berror\b
      expect(
        CycleStateResolver.resolve(statusMessage: 'Transferring with unfailing speed'),
        CycleState.downloading,
      );
      // Word boundary match for error
      expect(
        CycleStateResolver.resolve(statusMessage: 'Fatal error occurred'),
        CycleState.failed,
      );
      // Word boundary match for fail
      expect(
        CycleStateResolver.resolve(statusMessage: 'Connection fail on endpoint'),
        CycleState.failed,
      );
      // Unknown state returns downloading
      expect(
        CycleStateResolver.resolve(statusMessage: 'Some completely custom message 1234'),
        CycleState.downloading,
      );
    });

    test('resolves standard http download messages accurately', () {
      expect(
        CycleStateResolver.resolve(statusMessage: 'Fetching metadata…'),
        CycleState.fetchingMetadata,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Allocating disk space'),
        CycleState.allocating,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Checking checksums'),
        CycleState.verifying,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Merging audio and video'),
        CycleState.merging,
      );
      expect(
        CycleStateResolver.resolve(
            statusMessage: 'Download completed successfully'),
        CycleState.completed,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Paused by user'),
        CycleState.paused,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Stalled (no peers)'),
        CycleState.stalled,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Seeding to swarm'),
        CycleState.seeding,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Error: HTTP 404 Not Found'),
        CycleState.failed,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Updating expired links'),
        CycleState.updatingLinks,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Retrying chunk 3'),
        CycleState.retrying,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Resuming download'),
        CycleState.resuming,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Starting download…'),
        CycleState.starting,
      );
      expect(
        CycleStateResolver.resolve(
            statusMessage: 'Waiting for counterpart stream…'),
        CycleState.starting,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Transferring data 1.2 MB/s'),
        CycleState.downloading,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Refreshing links…'),
        CycleState.updatingLinks,
      );
      expect(
        CycleStateResolver.resolve(
            statusMessage: 'Retrying (mirror failover)…'),
        CycleState.retrying,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Finishing merge…'),
        isNot(CycleState.completed),
      );
      expect(
        CycleStateResolver.resolve(statusMessage: 'Finished download'),
        CycleState.completed,
      );
      expect(
        CycleStateResolver.resolve(statusMessage: null),
        CycleState.downloading,
      );
    });

    test(
        'Benchmark: fast string resolution achieves high throughput with cache',
        () {
      final messages = [
        'Fetching metadata…',
        'Allocating disk space',
        'Checking checksums',
        'Merging audio and video',
        'Download completed successfully',
        'Paused by user',
        'Stalled (no peers)',
        'Updating expired links',
        'Retrying chunk 3',
        'Transferring data 1.2 MB/s',
      ];

      final sw = Stopwatch()..start();
      const iterations = 50000;
      for (var i = 0; i < iterations; i++) {
        final msg = messages[i % messages.length];
        final state = CycleStateResolver.resolve(statusMessage: msg);
        expect(state, isNotNull);
      }
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(500));
    });
  });
}
