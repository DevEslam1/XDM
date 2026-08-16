import 'package:dmx/core/services/engine/cycle_state_resolver.dart';
import 'package:dmx/features/downloads/models/cycle_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CycleStateResolver Tests', () {
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

    test('resolves torrent messages via libtorrent mappings', () {
      expect(
        CycleStateResolver.resolve(
          statusMessage: 'downloading_metadata',
          isTorrent: true,
        ),
        CycleState.fetchingMetadata,
      );
      expect(
        CycleStateResolver.resolve(
          statusMessage: 'seeding',
          isTorrent: true,
        ),
        CycleState.seeding,
      );
      expect(
        CycleStateResolver.resolve(
          statusMessage: 'checking_files',
          isTorrent: true,
        ),
        CycleState.verifying,
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
        CycleStateResolver.resolve(statusMessage: 'Download completed successfully'),
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
        CycleStateResolver.resolve(statusMessage: 'Waiting for counterpart stream…'),
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
        CycleStateResolver.resolve(statusMessage: 'Retrying (mirror failover)…'),
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
  });
}
